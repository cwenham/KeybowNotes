import Foundation

/// `state.json`: what KeybowNotes keeps between runs that is neither the tree
/// nor a setting — each module's part under its id, read and written for it
/// by the app, never by the module itself.
///
///   {
///     "modules" : {
///       "quote" : { "positions" : { … } },
///       "stopwatch" : { "state" : { … } }
///     },
///     "version" : 1
///   }
///
/// Held in memory and written whole, atomically, on every change: it's small,
/// and nothing is lost to a crash. A module's value is its saved data as
/// JSON, when it is JSON, so the file reads plainly; anything else is kept as
/// `{ "$data": "<base64>" }`.
public final class StateFile: @unchecked Sendable {
    public static let version = 1

    public let url: URL
    private let lock = NSLock()
    private var modules: [String: [String: Any]] = [:]
    /// Why the file couldn't be read, if it couldn't. It was set aside under
    /// another name, not lost, and a fresh one started.
    public private(set) var problem: String?

    public init(url: URL) {
        self.url = url
        read()
    }

    /// What `module` saved as `key`, if anything.
    public func load(_ key: String, for module: String) -> Data? {
        guard let value = lock.withLock({ modules[module]?[key] }) else { return nil }
        if let wrapped = value as? [String: Any], wrapped.count == 1, let base64 = wrapped["$data"] as? String {
            return Data(base64Encoded: base64)
        }
        return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }

    /// Keeps `data` as `module`'s `key`, or forgets it when nil, and writes the
    /// file. Nil on success, else why not — the change is kept in memory.
    @discardableResult
    public func save(_ data: Data?, as key: String, for module: String) -> String? {
        let value: Any? = data.map { data in
            (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
                ?? ["$data": data.base64EncodedString()]
        }
        return lock.withLock {
            modules[module, default: [:]][key] = value
            if modules[module]?.isEmpty == true { modules[module] = nil }
            return write()
        }
    }

    /// The keys `module` has saved.
    public func keys(for module: String) -> [String] {
        lock.withLock { modules[module].map { Array($0.keys).sorted() } ?? [] }
    }

    // MARK: - The file

    private func read() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StateError("it isn't a JSON object")
            }
            let version = root["version"] as? Int ?? Self.version
            guard version <= Self.version else { throw StateError("it's version \(version), newer than this app") }
            var loaded: [String: [String: Any]] = [:]
            for (module, value) in root["modules"] as? [String: Any] ?? [:] {
                if let entries = value as? [String: Any] { loaded[module] = entries }
            }
            modules = loaded
        } catch {
            setAside(because: (error as? StateError)?.reason ?? error.localizedDescription)
        }
    }

    /// Moves an unreadable file out of the way, so a fresh one doesn't
    /// overwrite what's in it.
    private func setAside(because reason: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            problem = "\(url.lastPathComponent) couldn't be read (\(reason)); it was kept as \(aside.lastPathComponent)."
        } catch {
            problem = "\(url.lastPathComponent) couldn't be read (\(reason)), nor moved aside: \(error.localizedDescription)"
        }
    }

    /// Called with the lock held.
    private func write() -> String? {
        let root: [String: Any] = ["version": Self.version, "modules": modules]
        do {
            let data = try JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            // Only for this user: a module's state is nobody else's business.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return nil
        } catch {
            return "Couldn't write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private struct StateError: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }
}
