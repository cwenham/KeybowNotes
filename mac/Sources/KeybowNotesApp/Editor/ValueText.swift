import AppKit
import KeybowKit
import SwiftUI

/// What text with {{values}} in it is explained and checked against: the
/// values for the key — the catalogue, with what the tree sets — and where
/// the text goes, which says what may be in it.
struct ValueContext: Equatable {
    var catalog: ValueCatalog
    /// The key's own values, for showing what each comes to here.
    var params: [String: String]
    var place: TemplatePlace

    func with(place: TemplatePlace) -> ValueContext {
        var context = self
        context.place = place
        return context
    }

    /// What a tag is, and what it comes to here: for the pointer resting on it.
    func explanation(of tag: TemplateTag, in text: String) -> String {
        let block = tag.kind == .blockOpening || tag.kind == .blockClosing
        guard let entry = catalog.entry(named: tag.name, block: block) else {
            if tag.inList, !block { return "The row's “\(tag.name)” column — or, if its rows have no such column, missing." }
            return block ? "Nothing here replies to {{#\(tag.name)}}." : "Nothing here gives {{\(tag.name)}}."
        }
        var lines = ["\(entry.title): \(entry.help)"]
        // What a list goes through, and what's only known row by row, come
        // to nothing to show here.
        if !block, !tag.isListSource, !tag.name.hasPrefix("@") {
            let here = ValueCatalog.preview(of: (text as NSString).substring(with: tag.range), params: params).text
            let shown = here.count > 200 ? here.prefix(200) + "…" : Substring(here)
            lines.append(shown.isEmpty ? "Here: empty" : "Here: \(shown)")
        }
        return lines.joined(separator: "\n")
    }
}

/// How text with {{values}} looks: each tag coloured — values purple, blocks
/// indigo, what follows a name quieter — mistakes underlined, red where it
/// won't run and orange where it probably isn't meant, and each tag
/// explained when the pointer rests on it.
@MainActor
enum ValueHighlighter {
    /// Colours the view's text, and says what's wrong with it.
    @discardableResult
    static func highlight(_ view: NSTextView, context: ValueContext, font: NSFont, headings: Bool) -> [TemplateIssue] {
        guard let storage = view.textStorage else { return [] }
        let text = storage.string
        let whole = NSRange(location: 0, length: storage.length)
        let issues = context.catalog.check(text, in: context.place)
        let selected = view.selectedRanges
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: whole)
        if headings {
            let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            for match in heading.matches(in: text, range: whole) { storage.addAttribute(.font, value: bold, range: match.range) }
        }
        for tag in TemplateSyntax.tags(in: text) {
            let block = tag.kind == .blockOpening || tag.kind == .blockClosing
            let colour: NSColor = block ? .systemIndigo : .systemPurple
            storage.addAttributes([.foregroundColor: colour, .backgroundColor: colour.withAlphaComponent(0.1),
                                   .toolTip: context.explanation(of: tag, in: text)], range: tag.range)
            // A fallback, a format, attributes: quieter than the name.
            let after = NSMaxRange(tag.nameRange)
            let rest = NSMaxRange(tag.range) - 2 - after
            if rest > 0 {
                storage.addAttribute(.foregroundColor, value: colour.withAlphaComponent(0.6),
                                     range: NSRange(location: after, length: rest))
            }
        }
        for issue in issues where NSMaxRange(issue.range) <= storage.length {
            let colour: NSColor = issue.severity == .error ? .systemRed : .systemOrange
            let style: NSUnderlineStyle = issue.severity == .error ? .thick : [.thick, .patternDot]
            let explained = (storage.attribute(.toolTip, at: issue.range.location, effectiveRange: nil) as? String)
                .map { $0 + "\n\n" } ?? ""
            storage.addAttributes([.underlineStyle: style.rawValue, .underlineColor: colour,
                                   .toolTip: explained + issue.message], range: issue.range)
        }
        storage.endEditing()
        view.selectedRanges = selected
        view.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        return issues
    }

    private static let heading = try! NSRegularExpression(pattern: #"(?m)^#{1,3} .*$"#)
}

/// A text view that offers the values there are as `{{` is typed — a block's
/// after `{{#` — and closes the tag once one's chosen.
final class ValueTextView: NSTextView {
    var context: ValueContext?
    /// Told when it gains or loses the keyboard.
    var focusChanged: ((Bool) -> Void)?

    /// The name being typed in a tag, if the caret's in one.
    private func partialTag() -> (range: NSRange, block: Bool)? {
        let caret = selectedRange()
        guard caret.length == 0 else { return nil }
        return TemplateSyntax.partialName(in: string, at: caret.location)
    }

    override var rangeForUserCompletion: NSRange {
        partialTag()?.range ?? NSRange(location: NSNotFound, length: 0)
    }

    /// What was typed when the list was offered, and what it offered.
    private var typed = ""
    private var offered: [String] = []

    override func completions(forPartialWordRange charRange: NSRange,
                              indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard let tag = partialTag(), let context else { return nil }
        index.pointee = 0
        typed = (string as NSString).substring(with: charRange)
        offered = context.catalog.completions(for: typed, block: tag.block)
        return offered
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        let block = partialTag()?.block ?? false
        // Chosen with Return or Tab, and not a family still to finish, `home.`:
        // the tag's closed, a block's with its `{{/ai}}`. Ended any other way
        // — Esc, or typing on, where punctuation would take what the list put
        // in — it's what was typed that stays.
        let chosen = movement == NSTextMovement.return.rawValue || movement == NSTextMovement.tab.rawValue
        guard flag, chosen, offered.contains(word), !word.hasSuffix(".") else {
            super.insertCompletion(flag && !chosen ? typed : word, forPartialWordRange: charRange, movement: movement,
                                   isFinal: flag)
            if flag, chosen, word.hasSuffix(".") { offerValues() }
            return
        }
        let after = (string as NSString).substring(from: NSMaxRange(charRange))
        let closed = after.hasPrefix("}}")
        let closing = closed ? "" : block ? "}}{{/\(word)}}" : "}}"
        super.insertCompletion(word + closing, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        let end = charRange.location + word.utf16.count + 2
        if block || closed { setSelectedRange(NSRange(location: min(end, (string as NSString).length), length: 0)) }
    }

    override func insertText(_ text: Any, replacementRange: NSRange) {
        super.insertText(text, replacementRange: replacementRange)
        let entered = (text as? String) ?? (text as? NSAttributedString)?.string ?? ""
        guard entered.count == 1, let character = entered.first else { return }
        let before = (string as NSString).substring(to: selectedRange().location)
        if entered == "{" && before.hasSuffix("{{") || entered == "#" && before.hasSuffix("{{#")
            // Typing closes the list: offer it again, narrowed, as a name goes on.
            || character.isLetter || character.isNumber || "._-@".contains(character) {
            offerValues()
        }
    }

    /// Shows what can go here, when there's more than what's typed.
    private func offerValues() {
        guard let tag = partialTag(), let context else { return }
        let partial = (string as NSString).substring(with: tag.range)
        guard context.catalog.completions(for: partial, block: tag.block).contains(where: { $0 != partial }) else { return }
        DispatchQueue.main.async { [weak self] in self?.complete(nil) }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focusChanged?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusChanged?(false) }
        return resigned
    }
}

/// Puts text into a value editor from outside it — the list of values — at
/// the caret, ready to finish.
@MainActor
final class ValueEditorHandle {
    fileprivate weak var view: ValueTextView?

    /// Inserts at the caret, replacing any selection, then selects the first
    /// part to fill in — `<entity>` — or puts the caret where typing goes on:
    /// between a call's empty quotes, or inside a block.
    func insert(_ text: String) {
        guard let view else { return }
        view.window?.makeFirstResponder(view)
        let start = view.selectedRange().location
        view.insertText(text, replacementRange: view.selectedRange())
        let inserted = text as NSString
        var place = NSRange(location: inserted.length, length: 0)
        let hole = inserted.range(of: #"<[^<>]+>"#, options: .regularExpression)
        if hole.location != NSNotFound {
            place = hole
        } else if inserted.range(of: "''").location != NSNotFound {
            place = NSRange(location: inserted.range(of: "''").location + 1, length: 0)
        } else if text.hasPrefix("{{#") {
            place = NSRange(location: inserted.range(of: "}}").location + 2, length: 0)
        }
        view.setSelectedRange(NSRange(location: start + place.location, length: place.length))
    }
}

/// Text with {{values}}: a field's, a list's editor, or a template file's.
struct ValueTextEditor: NSViewRepresentable {
    enum Kind: Equatable {
        /// An inspector's field: grows with its text, up to `lines` lines;
        /// Return finishes, and ⌥Return starts a new line where `multiline`.
        case field(multiline: Bool, lines: Int)
        /// A page: Return starts a new line, headings are bold, and it fills
        /// the space it's given.
        case page
    }

    @Binding var text: String
    let context: ValueContext
    var kind = Kind.field(multiline: false, lines: 3)
    var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    var issues: Binding<[TemplateIssue]>?
    var focused: Binding<Bool>?
    var handle: ValueEditorHandle?
    /// Return, in a field.
    var onReturn: () -> Void = {}
    /// Leaving it, for the keyboard to go elsewhere.
    var onLeave: () -> Void = {}

    static let inset = NSSize(width: 3, height: 3)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let view = ValueTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.textContainerInset = Self.inset
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.drawsBackground = false
        view.font = font
        view.string = text
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        view.context = self.context
        view.focusChanged = { [weak coordinator = context.coordinator] in coordinator?.focusChanged($0) }
        handle?.view = view

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = kind == .page
        scroll.autohidesScrollers = true
        context.coordinator.highlight(view, later: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ValueTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        view.isEditable = context.environment.isEnabled
        view.isSelectable = true
        handle?.view = view
        var changed = false
        if view.string != text {
            view.string = text
            changed = true
        }
        if view.context != self.context {
            view.context = self.context
            changed = true
        }
        if changed { coordinator.highlight(view, later: true) }
    }

    /// As tall as its text, wrapped to the width offered, up to its lines.
    /// Measured on a copy of the text: changing the view's own layout here
    /// would have SwiftUI measure it again, and again.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard case .field(_, let most) = kind, let view = scroll.documentView as? NSTextView else { return nil }
        var width = proposal.width ?? .infinity
        if !width.isFinite { width = scroll.frame.width > 0 ? scroll.frame.width : 240 }
        width = max(width, 40)
        let padding = (view.textContainer?.lineFragmentPadding ?? 5) * 2 + Self.inset.width * 2
        var string = view.string
        if string.isEmpty || string.hasSuffix("\n") { string += " " }
        let measured = NSAttributedString(string: string, attributes: [.font: font])
            .boundingRect(with: NSSize(width: width - padding, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let line = NSLayoutManager().defaultLineHeight(for: font)
        return CGSize(width: width, height: ceil(min(max(measured, line), line * CGFloat(most)) + Self.inset.height * 2))
    }

    /// Where the first line's text sits: for lining up with a label.
    var firstBaseline: CGFloat { Self.inset.height + font.ascender }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ValueTextEditor

        init(_ parent: ValueTextEditor) {
            self.parent = parent
        }

        /// Colours the text, and passes on what's wrong — `later` while
        /// SwiftUI is updating, which mustn't change its state.
        func highlight(_ view: NSTextView, later: Bool = false) {
            let issues = ValueHighlighter.highlight(view, context: parent.context, font: parent.font,
                                                    headings: parent.kind == .page)
            guard let binding = parent.issues, binding.wrappedValue != issues else { return }
            if later {
                DispatchQueue.main.async { binding.wrappedValue = issues }
            } else {
                binding.wrappedValue = issues
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            highlight(view)
        }

        func focusChanged(_ focused: Bool) {
            parent.focused?.wrappedValue = focused
            if !focused { parent.onLeave() }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard case .field(let multiline, _) = parent.kind else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onReturn()
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                if multiline { textView.insertText("\n", replacementRange: textView.selectedRange()) }
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            default:
                return false
            }
        }
    }
}

/// A field that takes {{values}}, in the inspector: coloured as it's typed,
/// each value explained when the pointer rests on it, mistakes marked and
/// said beneath; `{{` offers what there is, and ƒx opens the list of them
/// all. Commits on Return or on leaving it, like DraftField: one edit, one
/// undo step.
struct TemplateField: View {
    let title: String
    let value: String
    var placeholder = ""
    var note = ""
    var hint = ""
    var multiline = false
    var help: String?
    /// Why it's out of use — a template file is used instead.
    var unused: String?
    let context: ValueContext
    let commit: (String) -> Void

    @State private var draft = ""
    /// The value the draft started from: only something typed is saved, as
    /// in DraftField.
    @State private var original = ""
    @State private var issues: [TemplateIssue] = []
    @State private var focused = false
    @State private var browsing = false
    @Environment(\.isEnabled) private var isEnabled

    private let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    var body: some View {
        InspectorRow(title, help: help) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    editor
                    Button { browsing = true } label: {
                        Text("ƒx").font(.system(size: 13, weight: .semibold, design: .serif)).italic()
                    }
                    .buttonStyle(.borderless)
                    .help("Every value there is, what each holds here, and what this comes to.")
                }
                ForEach(Array(issues.prefix(3).enumerated()), id: \.offset) { _, issue in
                    Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.octagon.fill"
                          : "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(issue.severity == .error ? .red : .orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FieldFooter(unused: unused, note: note)
            }
        }
        .sheet(isPresented: $browsing) {
            ValueBrowser(title: title, text: draft, context: context, multiline: multiline) { text in
                draft = text
                save()
            }
        }
        .onAppear { draft = value; original = value }
        .onChange(of: value) { _, newValue in
            // Follow it unless something's been typed here.
            if !focused || draft == original { draft = newValue }
            original = newValue
        }
    }

    private var editor: some View {
        let editor = ValueTextEditor(text: $draft, context: context, kind: .field(multiline: multiline, lines: multiline ? 6 : 3),
                                     font: font, issues: $issues, focused: $focused, onReturn: save, onLeave: save)
        return editor
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(placeholder.isEmpty ? hint : placeholder)
                        .font(.system(size: NSFont.systemFontSize))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.leading, ValueTextEditor.inset.width + 5)
                        .padding(.top, ValueTextEditor.inset.height)
                        .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.35),
                              lineWidth: focused ? 2 : 1))
            .opacity(isEnabled ? 1 : 0.6)
            .alignmentGuide(.firstTextBaseline) { _ in editor.firstBaseline }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed != original.trimmingCharacters(in: .whitespaces) else { return }
        original = trimmed
        commit(trimmed)
    }
}
