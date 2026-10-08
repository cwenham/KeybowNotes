import Foundation

/// The tree file as text: read and parsed, and written back with the version
/// before kept beside it — `tree.md.previous` — whoever changed it: the tree
/// editor, a script, an agent, or a draft added from Design with Claude.
public struct OutlineFile: Sendable {
    public let url: URL

    public init(_ url: URL) {
        self.url = url
    }

    /// What it says. Throws when it can't be read — when there's none.
    public func contents() throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// What it says; empty when there's no file yet.
    public func text() -> String {
        (try? contents()) ?? ""
    }

    /// Parsed, with the lines that couldn't be read: what writing it back
    /// would lose.
    public func read() -> (document: OutlineDocument, problems: [OutlineDiagnostic]) {
        OutlineParser.parse(text())
    }

    /// The version before the last write.
    public var previous: URL { url.appendingPathExtension("previous") }

    /// Writes `text` in place of what's there, which is kept as `previous`.
    public func write(_ text: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: url.path) {
            try? manager.removeItem(at: previous)
            try? manager.copyItem(at: url, to: previous)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public func write(_ document: OutlineDocument) throws {
        try write(OutlineWriter.text(document))
    }
}
