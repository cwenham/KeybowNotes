import Foundation
import KeybowKit

/// `{{file name="notes.txt"}}`: the text of a file — and, written
/// `{{#each file="team.csv"}}`, its rows. `name` is found in the templates
/// folder beside the tree, unless it's a full or `~/` path, and can hold
/// placeholders: `name="{{leaf}}.csv"`.
public final class FileModule: KeybowModule, @unchecked Sendable {
    public static let id = "file"
    /// The most of a file that's read: a table, not a database.
    static let maximumSize = 20_000_000

    public let manifest = ModuleManifest(id: id, name: "Files", fetches: [id], values: [
        ValueEntry("file", title: "A file's text", help: """
            The whole text of a file, read when a key uses it. {{#each file='team.csv'}} goes through its rows \
            instead: a CSV or tab-separated file, JSON, a Markdown table, or a line each.
            """, example: "{{file name='notes.txt'}}", sample: "Ann, Bob and Carol", kind: .call, fetched: true,
            attributes: [
                ValueAttribute("name", help: "The file: in the templates folder, or a full or ~/ path.",
                               example: "name='notes.txt'", required: true),
            ]),
    ])

    private var host: ModuleHost?

    public init() {}

    public func start(host: ModuleHost) {
        self.host = host
    }

    public func fetch(_ names: [String], params: [String: String], now: Date) async throws -> [String: String] {
        var values: [String: String] = [:]
        for name in names { values[name] = try read(name, params: params, now: now) }
        return values
    }

    func read(_ name: String, params: [String: String], now: Date) throws -> String {
        let url = try file(named: name, params: params, now: now)
        let shown = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maximumSize else {
            throw ModuleError("“\(shown)” is too big to read", "It's over \(Self.maximumSize / 1_000_000) MB.")
        }
        do {
            return Self.text(of: try Data(contentsOf: url))
        } catch {
            throw ModuleError("There's no “\(shown)” to read", "Looked for \((url.path as NSString).abbreviatingWithTildeInPath).")
        }
    }

    private func file(named name: String, params: [String: String], now: Date) throws -> URL {
        guard let call = Template.operatorCall(name), call.name == Self.id else {
            throw ModuleError("{{\(name)}} needs the name of a file",
                              "Write it as {{file name='notes.txt'}}, with the file in the templates folder beside tree.md.")
        }
        if let unknown = call.attributes.keys.sorted().first(where: { $0 != "name" }) {
            throw ModuleError("{{file}} doesn't take “\(unknown)”", "It takes name.")
        }
        guard let raw = call.attributes["name"] else {
            throw ModuleError("{{file}} needs a name", "Write it as {{file name='notes.txt'}}.")
        }
        let expanded = Template.expand(raw, params: params, now: now)
        if let missing = expanded.missing.first {
            throw ModuleError("{{file}}'s name needs a value for {{\(missing)}}")
        }
        let file = expanded.text.trimmingCharacters(in: .whitespaces)
        guard !file.isEmpty else { throw ModuleError("{{file}}'s name is empty") }
        return try QuoteModule.resolve(file, in: host?.templatesFolder)
    }

    /// UTF-8; UTF-16, with its mark; else Windows Latin, which spreadsheets
    /// on Windows save CSV in.
    static func text(of data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    public func valuesNeeded(toFetch names: [String]) -> Set<String> {
        var needed = Set<String>()
        for name in names {
            for value in Template.operatorCall(name)?.attributes.values ?? [:].values {
                needed.formUnion(Template.names(in: value))
            }
        }
        return needed
    }

    public func standIn(forValue name: String) -> String {
        guard let file = Template.operatorCall(name)?.attributes["name"], !file.contains("{{") else { return "‹a file›" }
        return "‹\((file as NSString).lastPathComponent)›"
    }

    public func fetchSubject(for names: [String]) -> String {
        let files = names.compactMap { Template.operatorCall($0)?.attributes["name"] }.filter { !$0.contains("{{") }
        return files.isEmpty ? "a file" : files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
    }

    // MARK: - Not an action

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        ModuleSummary(verb: "Read", subject: request.leaf)
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        .failure("{{file}} gives a value to other actions; it isn't an action itself.")
    }
}
