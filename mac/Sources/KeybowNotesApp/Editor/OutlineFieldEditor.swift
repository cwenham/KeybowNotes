import AppKit
import KeybowKit

/// The field editor for the outline's rows. In the brackets it offers what
/// can go where the caret is — a keyword, a field's key, a list, a template,
/// an app; what a key takes; a {{value}} — as `[`, `, `, `: `, `@` and `{{`
/// are typed, or with ⌥Esc; and finishes what's chosen: a {{value}} with
/// its `}}`, and a key's value offered in turn.
final class OutlineFieldEditor: NSTextView {
    /// What can go at the caret in the row's text, and what's offered there.
    var completer: ((String, Int) -> (OutlineCompletion, [String])?)?
    /// While the list is showing, Return, Tab, Esc and the arrows are its.
    private(set) var isCompleting = false
    /// What was typed when the list was offered, what it offered, and where.
    private var typed = ""
    private var offered: [String] = []
    private var slot = OutlineCompletion.Slot.item

    init() {
        super.init(frame: .zero)
        isFieldEditor = true
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func completion() -> (OutlineCompletion, [String])? {
        let caret = selectedRange()
        guard caret.length == 0 else { return nil }
        return completer?(string, caret.location)
    }

    override var rangeForUserCompletion: NSRange {
        completion()?.0.range ?? NSRange(location: NSNotFound, length: 0)
    }

    override func completions(forPartialWordRange charRange: NSRange,
                              indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard let (completion, candidates) = completion(), !candidates.isEmpty else {
            isCompleting = false
            return nil
        }
        index.pointee = 0
        typed = (string as NSString).substring(with: charRange)
        offered = candidates
        slot = completion.slot
        isCompleting = true
        return candidates
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        if flag { isCompleting = false }
        // Chosen with Return or Tab. Ended any other way — Esc, or typing
        // on, where punctuation would take what the list put in — it's what
        // was typed that stays.
        let chosen = movement == NSTextMovement.return.rawValue || movement == NSTextMovement.tab.rawValue
        guard flag, chosen, offered.contains(word) else {
            super.insertCompletion(flag ? typed : word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
            return
        }
        var finished = word
        var block = false
        if case .placeholder(let isBlock) = slot, !word.hasSuffix(".") {
            block = isBlock
            let after = (string as NSString).substring(from: NSMaxRange(charRange))
            if !after.hasPrefix("}}") { finished += block ? "}}{{/\(word)}}" : "}}" }
        }
        super.insertCompletion(finished, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        if block { setSelectedRange(NSRange(location: charRange.location + word.utf16.count + 2, length: 0)) }
        // A key's value, or a family's members, may have choices of their own.
        if word.hasSuffix(": ") || word.hasSuffix(".") { offer() }
    }

    override func insertText(_ text: Any, replacementRange: NSRange) {
        super.insertText(text, replacementRange: replacementRange)
        let entered = (text as? String) ?? (text as? NSAttributedString)?.string ?? ""
        guard entered.count == 1, let character = entered.first else { return }
        let before = (string as NSString).substring(to: selectedRange().location)
        switch character {
        case "[", "@": offer()
        case " " where before.hasSuffix(", ") || before.hasSuffix(": "): offer()
        case "{" where before.hasSuffix("{{"): offer()
        case "#" where before.hasSuffix("{{#"): offer()
        // Typing closes the list: offer it again, narrowed, as a name goes on.
        case _ where character.isLetter || character.isNumber || "._-".contains(character): offer()
        default: break
        }
    }

    /// Shows what can go at the caret, when there's anything.
    private func offer() {
        guard let (_, candidates) = completion(), !candidates.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.complete(nil) }
    }
}

/// An outline row's text cell: it hands out the outline's own field editor.
final class OutlineTextCell: NSTextFieldCell {
    var fieldEditorProvider: (() -> NSTextView?)?

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        fieldEditorProvider?() ?? super.fieldEditor(for: controlView)
    }
}
