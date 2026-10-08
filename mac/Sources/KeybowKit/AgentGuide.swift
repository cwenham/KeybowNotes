import Foundation

/// What an AI agent is told about KeybowNotes before it designs or changes a
/// tree: the guide for agents, the configuration language, and the action
/// types that are actually here — modules' included. Shared by the MCP
/// server and the app's own drafting, so both say the same.
public enum AgentGuide {
    static let files = ["AGENT-GUIDE.md", "CONFIG-LANGUAGE.md"]

    /// Where the guides are: KEYBOW_DOCS; the app's Resources/Guide — the
    /// app's own, or the one a helper inside it sits beside; else the
    /// repository's docs, above a development build.
    public static func folder() -> URL? {
        let manager = FileManager.default
        func holds(_ url: URL) -> Bool { files.allSatisfy { manager.fileExists(atPath: url.appendingPathComponent($0).path) } }
        if let path = ProcessInfo.processInfo.environment["KEYBOW_DOCS"], !path.isEmpty {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if holds(url) { return url }
        }
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("Guide"), holds(resources) { return resources }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // Contents/Helpers/keybow → Contents/Resources/Guide.
        let beside = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Guide")
        if holds(beside) { return beside }
        var folder = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            let docs = folder.appendingPathComponent("docs")
            if holds(docs) { return docs }
            folder = folder.deletingLastPathComponent()
        }
        let installed = URL(fileURLWithPath: "/Applications/KeybowNotes.app/Contents/Resources/Guide")
        return holds(installed) ? installed : nil
    }

    /// The guide for agents, then the language reference, whole.
    public static func text() throws -> String {
        guard let folder = folder() else {
            throw TreeControl.Problem("KeybowNotes' guides aren't here: set KEYBOW_DOCS to the repository's docs folder.")
        }
        return try files.map { try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n\n---\n\n")
    }

    /// The action types here, as an agent should write them: keywords, and
    /// for modules, every field with its help.
    public static func catalog() -> String {
        var lines = ["# Action types in this copy of KeybowNotes", "",
                     "Write the keyword in an entry's brackets — `[Notes]` — or `type: name`. The language reference "
                     + "documents each built-in type's fields.", "", "## Built in", ""]
        for action in BuiltInActions.types.sorted(by: { $0.type < $1.type }) {
            let words = action.keywords.map { "`\($0)`" }
            lines.append("- `\(action.type)`, \(action.title.lowercased())"
                         + (words.isEmpty ? "" : " — " + words.joined(separator: ", ")))
        }
        lines += ["", "## From modules", ""]
        for module in ModuleRegistry.shared.all {
            for action in module.manifest.actionTypes {
                let words = action.keywords.map { "`\($0)`" }.joined(separator: ", ")
                lines.append("### `\(action.type)` — \(action.title)")
                lines.append("Keywords: \(words).\(action.takesText ? " Takes text: `text`, a `template`, else the label." : "")")
                for field in action.fields {
                    var kind: String
                    switch field.kind {
                    case .text: kind = "text"
                    case .number: kind = "number"
                    case .flag: kind = "true or false"
                    case .choice(let words): kind = "one of " + words.joined(separator: ", ")
                    case .action: kind = "an action of its own, written `\(field.key): Keyword` and `\(field.key).field: …`"
                    case .colour: kind = "a colour, #rrggbb or a name"
                    }
                    let help = field.help.replacingOccurrences(of: "\n", with: " ")
                    lines.append("- `\(field.key)` (\(kind)): \(help)")
                }
                lines.append("")
            }
        }
        let values = ModuleRegistry.shared.all.flatMap(\.manifest.fetches)
        if !values.isEmpty {
            lines.append("Values modules fetch here: " + values.map { "`{{\($0)…}}`" }.joined(separator: ", ") + ".")
        }
        return lines.joined(separator: "\n")
    }
}
