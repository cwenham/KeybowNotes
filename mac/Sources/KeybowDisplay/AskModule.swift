import Foundation
import KeybowKit

/// Asks for something to be typed, then hands it to an action of the node's
/// own, as `{{answer}}`:
///
///   Search [Ask, text: "Search Wikipedia for", ok: Display, ok.text: "{{api.wikipedia term={{answer}}}}"]
///   Jot [Ask, text: "A note for the inbox", multiline: true, ok: append, ok.find.byName: Inbox]
///   Rename [Ask, text: "New name", initial: "{{selection}}", ok: Insert]
///
/// The question is its template or text — Markdown, or an HTML document — or
/// the label. It takes the keyboard without taking the app in use from the
/// front, so an Insert after it types into that app. OK waits for something
/// to be typed; Return is OK — ⌘Return, with several lines — and Esc Cancel.
public final class AskModule: KeybowModule, @unchecked Sendable {
    public static let type = "ask"

    public let manifest = ModuleManifest(
        id: "ask", name: "Ask",
        actionTypes: [
            ModuleActionType(
                type: type, title: "Ask", keywords: ["Ask", "Prompt"], symbol: "text.cursor",
                fields: [
                    ModuleField(key: "template", title: "Template", help: """
                        A file in the templates folder holding the question, filled in when the key is pressed.
                        Example: search.md
                        """),
                    ModuleField(key: "text", title: "Question", hint: "empty asks with the label",
                                help: """
                        The question, over the field: Markdown, or an HTML document.
                        Example: Search Wikipedia for
                        """),
                    ModuleField(key: "initial", title: "Starts with", hint: "{{selection}}, {{clipboard}}…",
                                help: """
                        What's in the field to begin with, selected so typing replaces it.
                        Example: {{selection|}}
                        """),
                    ModuleField(key: "hint", title: "Hint", hint: "grey words while it's empty",
                                help: """
                        Words shown in the empty field, to say what goes in it.
                        Example: a word or phrase
                        """),
                    ModuleField(key: "multiline", title: "Several lines", kind: .flag, help: """
                        A taller field that takes new lines: Return starts one, ⌘Return is OK.
                        Example: multiline: true
                        """),
                    ModuleField(key: "ok", title: "When OK is chosen", kind: .action, help: """
                        The action given the answer, as though its key were pressed. {{answer}} is what was typed; \
                        Copy and Insert use it when they're given no text.
                        Example: ok: Insert
                        """),
                    ModuleField(key: "cancel", title: "When Cancel is chosen", kind: .action, help: """
                        An action to run when Cancel is chosen, or Esc pressed. Usually nothing.
                        Example: cancel: Display
                        """),
                ],
                takesText: true),
        ])

    private var host: ModuleHost?

    public init() {}

    public func start(host: ModuleHost) {
        self.host = host
    }

    static func isOn(_ text: String?) -> Bool {
        ["true", "yes", "on", "1"].contains((text ?? "").lowercased())
    }

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        let question = request.field("text") ?? request.field("template") ?? request.leaf
        let firstLine = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? question
        return ModuleSummary(verb: "Ask", subject: firstLine.count > 50 ? String(firstLine.prefix(50)) + "…" : firstLine,
                             details: [])
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        let question = request.field("text") ?? request.leaf
        guard let host else { return .failure("Nothing here can ask") }
        let content: ModuleDisplay.Content = NotesHTML.isDocument(question) ? .html(question) : .markdown(question)
        let field = ModuleDisplay.Field(initial: request.fields["initial"] ?? "", hint: request.field("hint") ?? "",
                                        multiline: Self.isOn(request.field("multiline")))
        let result = await host.display(ModuleDisplay(content: content, buttons: [.cancel, .ok], field: field))

        switch result {
        case .entered(let answer):
            return .then("ok", values: ["answer": answer], text: "{{answer}}")
        case .cancel:
            return .then("cancel", values: ["answer": ""])
        default:
            return .quiet
        }
    }
}
