import Foundation

/// The config as the app and the command line load it: a `tree.md`, compiled
/// as it's read — or, for tests and tools, compiled JSON taken as it is.
public enum ConfigFile {
    public struct Loaded: Sendable {
        public let config: KeybowConfig
        /// Mistakes in the outline. What each touches is left out, or refused
        /// when pressed; the rest of the tree works.
        public let errors: [OutlineDiagnostic]
        /// What loading left out that no line was marked for: a list making a
        /// branch too deep for its tree, say.
        public var leftOut: [String] = []

        public init(config: KeybowConfig, errors: [OutlineDiagnostic], leftOut: [String] = []) {
            self.config = config
            self.errors = errors
            self.leftOut = leftOut
        }

        public var mistakeCount: Int { errors.count + leftOut.count }

        /// "tree.md, line 12: …", or "3 mistakes in tree.md — the first, line 12: …".
        public func describe(in url: URL) -> String? {
            let name = url.lastPathComponent
            let first: String
            if let error = errors.first {
                first = "line \(error.line): \(error.message)"
            } else if let left = leftOut.first {
                first = "left out: \(left)"
            } else {
                return nil
            }
            return mistakeCount == 1 ? "\(name), \(first)" : "\(mistakeCount) mistakes in \(name) — the first, \(first)"
        }
    }

    /// Anything but `.json` is an outline.
    public static func isOutline(_ url: URL) -> Bool {
        url.pathExtension.lowercased() != "json"
    }

    public static func load(_ url: URL,
                            locateApp: @escaping (String) -> OutlineConverter.AppMatch? = AppLocator.locate) throws -> Loaded {
        guard isOutline(url) else { return Loaded(config: try KeybowConfig.load(from: url), errors: []) }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ConfigError.unreadable(url, error)
        }
        let (document, problems) = OutlineParser.parse(text)
        let compiled = OutlineCompiler.compile(document, locateApp: locateApp)
        guard let config = compiled.config else {
            throw ConfigError.doesNotCompile(compiled.configError ?? "no reason given")
        }
        let errors = (problems + compiled.diagnostics).filter { $0.severity == .error }.sorted { $0.line < $1.line }
        return Loaded(config: config, errors: errors, leftOut: compiled.leftOut)
    }
}
