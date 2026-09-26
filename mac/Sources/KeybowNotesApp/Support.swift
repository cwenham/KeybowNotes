import AppKit
import KeybowKit
import os

/// Messages go to the unified log, so Console.app shows what a Finder-launched
/// app is doing, and to stdout when run from a terminal.
enum Log {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.cwenham.keybownotes",
                                       category: "app")

    static func info(_ message: String) {
        print(message)
        // Notice rather than info: info-level messages aren't kept on disk, so
        // `log show` and Console.app would miss them after the fact.
        logger.notice("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        print(message)
        logger.error("\(message, privacy: .public)")
    }
}

/// Only one copy may drive the Keybow: two would compete for every key press.
enum SingleInstance {
    private static var descriptor: Int32 = -1

    /// Takes the lock, or returns false when another copy holds it.
    static func acquire() -> Bool {
        try? FileManager.default.createDirectory(at: ConfigStore.supportDirectory, withIntermediateDirectories: true)
        let path = ConfigStore.supportDirectory.appendingPathComponent(".lock").path
        descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        // If the lock file can't even be opened, don't stop the app over it.
        guard descriptor >= 0 else { return true }
        // Held until the process exits, which releases it even after a crash.
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}

/// Finds, loads and watches the config file.
@MainActor
final class ConfigStore {
    nonisolated static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KeybowNotes")
    }

    nonisolated static var defaultURL: URL { supportDirectory.appendingPathComponent("config.json") }

    /// Keeps the keys dark until a usable config exists.
    static let empty = try! KeybowConfig.parse(Data(#"{ "trees": {} }"#.utf8))

    let url: URL
    private(set) var config = ConfigStore.empty
    /// Why the file couldn't be used, if it couldn't. The previous config, if
    /// any, stays in force.
    private(set) var problem: String?
    /// Called after a reload, successful or not.
    var onChange: (() -> Void)?

    private var lastModified: Date?
    private var timer: Timer?

    var templatesDirectory: URL { url.deletingLastPathComponent().appendingPathComponent("templates") }

    init(url: URL) {
        self.url = url
        load()
    }

    /// On first run there is no config, so put the bundled example and its
    /// templates where the app looks. Returns what was done, if anything.
    static func installDefaultsIfNeeded() -> String? {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: defaultURL.path),
              let bundled = Bundle.main.url(forResource: "config.demo", withExtension: "json") else { return nil }
        do {
            try manager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try manager.copyItem(at: bundled, to: defaultURL)
            let templates = supportDirectory.appendingPathComponent("templates")
            if let bundledTemplates = Bundle.main.url(forResource: "templates", withExtension: nil),
               !manager.fileExists(atPath: templates.path) {
                try manager.copyItem(at: bundledTemplates, to: templates)
            }
            return "Installed the example config at \(defaultURL.path)"
        } catch {
            return "Couldn't install the example config: \(error.localizedDescription)"
        }
    }

    func reload() {
        load()
        onChange?()
    }

    /// Checks the file every couple of seconds. Polling, rather than file
    /// events, survives editors that save by replacing the file.
    func startWatching() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.modificationDate() != self.lastModified else { return }
                self.reload()
            }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    private func load() {
        lastModified = modificationDate()
        do {
            config = try KeybowConfig.load(from: url)
            problem = nil
        } catch let error as ConfigError {
            problem = error.description
        } catch {
            problem = error.localizedDescription
        }
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
