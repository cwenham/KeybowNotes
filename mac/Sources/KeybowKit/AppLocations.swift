import Foundation

/// Where KeybowNotes keeps things — the same for the app and the command line.
public enum AppLocations {
    /// The app's bundle identifier: its settings' domain, its log's subsystem,
    /// and what AppleScript addresses.
    public static let bundleID = "io.github.cwenham.keybownotes"

    /// ~/Library/Application Support/KeybowNotes
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/KeybowNotes")
    }

    /// The tree, unless Settings chose another file.
    public static var defaultTree: URL { supportDirectory.appendingPathComponent("tree.md") }

    /// Held by the app while it runs: only one copy may drive the keypads.
    public static var lockFile: URL { supportDirectory.appendingPathComponent(".lock") }

    /// Where setting a keypad up keeps what it replaces.
    public static var keypadBackups: URL { supportDirectory.appendingPathComponent("Keypad Backups", isDirectory: true) }

    /// The setting a tree chosen in Settings is kept under: its path, or
    /// empty for the default.
    public static let treePathKey = "configPath"

    /// The tree the app uses: the one chosen in its Settings, else the default.
    public static func tree(chosenIn defaults: UserDefaults?) -> URL {
        guard let path = defaults?.string(forKey: treePathKey), !path.isEmpty else { return defaultTree }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// The packaged app's settings, read from outside it — by the command line.
    public static var appSettings: UserDefaults? { UserDefaults(suiteName: bundleID) }

    /// For a compiled JSON config given for testing, the `tree.md` beside it:
    /// what the tree editor and drafting work on. An outline is itself.
    public static func outline(for config: URL) -> URL {
        ConfigFile.isOutline(config) ? config : config.deletingLastPathComponent().appendingPathComponent("tree.md")
    }
}
