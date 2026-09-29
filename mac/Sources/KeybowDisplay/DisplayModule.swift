import Foundation
import KeybowKit

/// Shows a template or text on screen, in a panel sized to fit it:
///
///   Quote [Display, text: "{{quote file=quotes.md}}"]
///   Today [Display, today.md, fade: 20 sec]
///   Idea [Display, text: "{{#ai}}…{{/ai}}", button: okCancel, ok: Copy]
///
/// Markdown unless it's an HTML document — one that opens with
/// `<!DOCTYPE html>`, `<html>`, an XML declaration or a `<meta>` — which is
/// shown as a web page. Without a button it fades after `fade`, or after long
/// enough to read it; Esc closes it at once. With `button: ok`, `cancel` or
/// `okCancel` it stays until one is chosen, and the action in `ok` or
/// `cancel` runs — with `{{displayed}}`, the text shown.
public final class DisplayModule: KeybowModule, @unchecked Sendable {
    public static let type = "display"
    /// The longest a display may be asked to stay: an hour.
    static let longestFade: TimeInterval = 3600

    public let manifest = ModuleManifest(
        id: "display", name: "Display",
        actionTypes: [
            ModuleActionType(
                type: type, title: "Display", keywords: ["Display", "Show"], symbol: "text.bubble",
                fields: [
                    ModuleField(key: "template", title: "Template", help: """
                        A file in the templates folder to show, filled in when the key is pressed. \
                        Markdown, or an HTML document.
                        Example: today.md
                        """),
                    ModuleField(key: "text", title: "Text", hint: "empty shows the label — {{quote …}}, {{selection}}…",
                                help: """
                        What to show, when there's no template: Markdown, or an HTML document starting <!DOCTYPE html>.
                        Example: {{quote file=quotes.md}}
                        """),
                    ModuleField(key: "button", title: "Buttons", kind: .choice(["ok", "cancel", "okCancel"]),
                                hint: "none: it fades by itself", help: """
                        Buttons that close it: OK, Cancel, or both. With buttons it stays until one is chosen, \
                        and each can run an action of its own. Esc is Cancel.
                        Example: okCancel
                        """),
                    ModuleField(key: "fade", title: "Fade after", hint: "15 sec — else long enough to read it",
                                help: """
                        How long it stays before fading, when it has no buttons. Esc closes it at once.
                        Example: 15 sec
                        """),
                    ModuleField(key: "ok", title: "When OK is chosen", kind: .action, help: """
                        An action to run when OK is chosen, as though its key were pressed. {{displayed}} is the \
                        text shown; Copy and Insert use it when they're given no text.
                        Example: ok: Copy
                        """),
                    ModuleField(key: "cancel", title: "When Cancel is chosen", kind: .action, help: """
                        An action to run when Cancel is chosen, or Esc pressed. Usually nothing.
                        Example: cancel: Notes
                        """),
                ],
                takesText: true),
        ])

    private var host: ModuleHost?

    public init() {}

    public func start(host: ModuleHost) {
        self.host = host
    }

    // MARK: - Reading the fields

    /// `ok`, `cancel`, `okCancel` — or `both`, `ok cancel`, any case. Nil for
    /// a word that's none of them.
    static func buttons(_ text: String?) -> [ModuleDisplay.Button]? {
        let word = (text ?? "").lowercased().filter { $0.isLetter }
        switch word {
        case "": return []
        case "ok": return [.ok]
        case "cancel": return [.cancel]
        case "okcancel", "cancelok", "both": return [.cancel, .ok]
        default: return nil
        }
    }

    /// `15 sec`, `15s`, `15`, `1.5 min`, `2m` → seconds. Nil if it isn't one.
    static func seconds(_ text: String) -> TimeInterval? {
        let pattern = #"^\s*(\d+(?:\.\d+)?)\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes)?\s*$"#
        guard let match = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let numberRange = Range(match.range(at: 1), in: text), let number = Double(text[numberRange]) else { return nil }
        let unit = Range(match.range(at: 2), in: text).map { text[$0].lowercased() } ?? "s"
        let seconds = unit.hasPrefix("m") ? number * 60 : number
        return seconds > 0 && seconds <= longestFade ? seconds : nil
    }

    /// Long enough to read: three words a second, between six seconds and a minute.
    static func readingTime(_ text: String) -> TimeInterval {
        let words = text.split { $0.isWhitespace }.count
        return min(60, max(6, (Double(words) / 3).rounded(.up)))
    }

    /// The text as it reads: an HTML document without its tags.
    static func plainText(_ text: String) -> String {
        guard NotesHTML.isDocument(text) else { return text }
        var plain = text
        for pattern in [#"(?is)<(script|style|head)\b.*?</\1>"#, #"(?i)<br\s*/?>|</(p|div|li|h[1-6]|tr)>"#] {
            plain = plain.replacingOccurrences(of: pattern, with: "\n", options: .regularExpression)
        }
        plain = plain.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            plain = plain.replacingOccurrences(of: entity, with: character)
        }
        return plain.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - KeybowModule

    public func problem(with request: ModuleRequest) -> String? {
        if Self.buttons(request.field("button")) == nil {
            return "Buttons are ok, cancel or okCancel, not “\(request.field("button") ?? "")”."
        }
        if let fade = request.field("fade"), Self.seconds(fade) == nil {
            return "“\(fade)” isn't a time to fade after: write it like 15 sec or 2 min."
        }
        return nil
    }

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        let text = request.field("text") ?? request.field("template") ?? request.leaf
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        var details: [String] = []
        if let buttons = Self.buttons(request.field("button")), !buttons.isEmpty {
            details.append(buttons.map { $0 == .ok ? "OK" : "Cancel" }.joined(separator: " and "))
        } else if let fade = request.field("fade").flatMap(Self.seconds) {
            details.append("for \(DateExpression.describe(seconds: fade))")
        }
        return ModuleSummary(verb: "Show", subject: firstLine.count > 50 ? String(firstLine.prefix(50)) + "…" : firstLine,
                             details: details)
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        guard let buttons = Self.buttons(request.field("button")) else {
            return .failure("Buttons are ok, cancel or okCancel")
        }
        let text = request.field("text") ?? request.leaf
        guard !text.isEmpty else { return .failure("Nothing to show") }
        guard let host else { return .failure("Nothing here can show it") }

        let fade = request.field("fade").flatMap(Self.seconds) ?? Self.readingTime(Self.plainText(text))
        let content: ModuleDisplay.Content = NotesHTML.isDocument(text) ? .html(text) : .markdown(text)
        let result = await host.display(ModuleDisplay(content: content, buttons: buttons, fadeAfter: fade))

        let values = ["displayed": Self.plainText(text)]
        switch result {
        case .ok where buttons.contains(.ok): return .then("ok", values: values)
        case .cancel where buttons.contains(.cancel): return .then("cancel", values: values)
        default: return .quiet
        }
    }
}
