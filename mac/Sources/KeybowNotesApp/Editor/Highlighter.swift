import AppKit
import KeybowKit

/// Colours a node's line: the label plain, the brackets quiet, and each item by
/// the role the compiler gives it. Used for rows at rest and, as you type, for
/// the field being edited.
@MainActor
struct Highlighter {
    let model: EditorModel
    var font = NSFont.systemFont(ofSize: 13)

    func attributed(_ text: String, inheritedType: String?, roles known: [AnnotationRole]? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ])
        apply(to: result, inheritedType: inheritedType, roles: known)
        return result
    }

    /// Colours `storage` in place — the field editor's text while typing.
    func apply(to storage: NSMutableAttributedString, inheritedType: String?, roles known: [AnnotationRole]? = nil) {
        let whole = NSRange(location: 0, length: storage.length)
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: whole)

        let tokens = OutlineSyntax.tokens(in: storage.string)
        guard let brackets = tokens.brackets else { return }
        storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: brackets)

        // Roles from the last compile, if they still line up; else work them
        // out now, which is what happens while typing.
        let roles = known?.count == tokens.items.count
            ? known!
            : tokens.items.map { model.role(of: $0.annotation, inheritedType: inheritedType) }

        for (item, role) in zip(tokens.items, roles) {
            style(item, role: role, in: storage)
        }
    }

    private func style(_ item: OutlineTokens.Item, role: AnnotationRole, in storage: NSMutableAttributedString) {
        let range = item.range
        func colour(_ colour: NSColor, _ range: NSRange = range) {
            storage.addAttribute(.foregroundColor, value: colour, range: range)
        }
        func underline(_ colour: NSColor, _ style: NSUnderlineStyle) {
            storage.addAttributes([.underlineStyle: style.rawValue, .underlineColor: colour], range: range)
        }
        // For a pair: the key, and the value after ": ".
        let keyRange: NSRange = {
            guard let key = item.annotation.key else { return range }
            return NSRange(location: range.location, length: min(range.length, (key as NSString).length))
        }()
        let valueRange = NSRange(location: keyRange.upperBound, length: range.upperBound - keyRange.upperBound)

        switch role {
        case .actionType:
            colour(.systemBlue)
            storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: font.pointSize), range: range)
        case .app(_, let installed):
            colour(installed ? .systemPurple : .systemRed)
            if !installed { storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        case .template:
            if case .word(let name) = item.annotation, model.templateExists(name) {
                colour(.systemTeal)
            } else {
                colour(.systemRed)
                underline(.systemRed, [.single, .patternDot])
            }
        case .alert:
            colour(.systemOrange)
        case .listReference(let exists):
            colour(exists ? .systemGreen : .systemRed)
        case .field:
            colour(.secondaryLabelColor, keyRange)
            colour(.labelColor, valueRange)
        case .parameter:
            colour(.secondaryLabelColor, keyRange)
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: keyRange)
            colour(.labelColor, valueRange)
        case .colour(let valid):
            colour(.secondaryLabelColor, keyRange)
            if valid, case .pair(_, let value) = item.annotation, let key = KeyColour(hex: value) {
                colour(NSColor(srgbRed: CGFloat(key.red) / 255, green: CGFloat(key.green) / 255,
                               blue: CGFloat(key.blue) / 255, alpha: 1), valueRange)
            } else {
                colour(.systemRed, valueRange)
            }
        case .link:
            colour(.linkColor)
            underline(.linkColor, .single)
        case .target:
            colour(.labelColor)
            underline(.secondaryLabelColor, [.single, .patternDot])
        case .unknown:
            colour(.systemRed)
            underline(.systemRed, [.thick, .patternDot])
        }
    }
}
