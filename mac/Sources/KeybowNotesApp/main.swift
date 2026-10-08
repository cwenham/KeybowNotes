import AppKit
import KeybowKit

// KeybowNotes: the Keybow drives the trees, a HUD overlay shows where you are,
// and completing a path runs its action.
//
// Normally launched as KeybowNotes.app (see mac/scripts/build-app.sh). From a
// terminal, for development:
//
//   swift run keybownotes [--config tree.md] [--screen cursor|main] [--dry-run]
//                         [--show-settings] [--show-data-sources] [--edit-tree] [--set-up-keypad]
//                         [--troubleshoot] [--draft]
//                         [--simulate "4 8 12"] [--pace 1.2]
//                         [--debug-snapshots dir]
//
// --dry-run shows what each action would do without doing it.
// --simulate presses the given keys (0-15) in turn, with or without a Keybow,
// so the overlay can be seen and checked without touching the hardware.

setvbuf(stdout, nil, _IOLBF, 0)

struct Options {
    /// Each of these, when given, wins for this run without being saved.
    var configPath: String?
    var placement: OverlayPlacement?
    var simulated: [Int] = []
    var pace: TimeInterval = 1.2
    var debugDirectory: URL?
    var dryRun = false
    var showSettings = false
    var showDataSources = false
    var editTree = false
    var setUpKeypad = false
    var troubleshoot = false
    var draft = false
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func parseOptions() -> Options {
    var options = Options()
    // Finder passes -psn_… on some systems; ignore anything that isn't ours.
    var arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }.makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--config":
            options.configPath = arguments.next()
        case "--screen":
            options.placement = arguments.next() == "main" ? .mainScreen : .screenWithCursor
        case "--simulate":
            let keys = (arguments.next() ?? "")
                .split(whereSeparator: { $0 == " " || $0 == "," })
                .compactMap { Int($0) }
            guard keys.allSatisfy({ (0..<KeybowProtocol.keyCount).contains($0) }) else {
                fail("--simulate takes keys 0-15")
            }
            options.simulated = keys
        case "--pace":
            options.pace = arguments.next().flatMap(TimeInterval.init) ?? options.pace
        case "--dry-run":
            options.dryRun = true
        case "--show-settings":
            options.showSettings = true
        case "--show-data-sources":
            options.showDataSources = true
        case "--edit-tree":
            options.editTree = true
        case "--set-up-keypad":
            options.setUpKeypad = true
        case "--troubleshoot":
            options.troubleshoot = true
        case "--draft":
            options.draft = true
        case "--debug-snapshots":
            guard let path = arguments.next() else { fail("--debug-snapshots needs a directory") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            options.debugDirectory = url
        default:
            fail("unknown option \(argument)")
        }
    }
    return options
}

let options = parseOptions()

// Top-level code runs on the main thread; tell the compiler so.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    guard SingleInstance.acquire() else {
        Log.error("KeybowNotes is already running; only one copy can use the Keybow.")
        if Bundle.main.bundleIdentifier != nil {
            let alert = NSAlert()
            alert.messageText = "KeybowNotes is already running"
            alert.informativeText = "Only one copy can use the Keybow at a time. Look for the keyboard icon in the menu bar."
            alert.runModal()
        }
        exit(1)
    }

    if options.configPath == nil, let installed = ConfigStore.installDefaultsIfNeeded() {
        Log.info(installed)
    }

    Modules.registerAll()
    let delegate = AppDelegate(options: options)
    app.delegate = delegate
    app.run()
}
