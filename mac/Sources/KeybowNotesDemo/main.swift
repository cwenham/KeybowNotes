import AppKit
import KeybowKit

// A demo of the Mac side: the Keybow drives the trees, and a HUD overlay shows
// where you are and what would happen. No actions run yet.
//
//   swift run keybownotes-demo [--config file.json] [--screen cursor|main]
//                              [--simulate "4 8 12"] [--pace 1.2]
//
// --simulate presses the given keys (0-15) in turn, with or without a Keybow,
// so the overlay can be seen and checked without touching the hardware.

setvbuf(stdout, nil, _IOLBF, 0)

struct Options {
    var configPath: String?
    var placement = OverlayPlacement.screenWithCursor
    var simulated: [Int] = []
    var pace: TimeInterval = 1.2
    var debugDirectory: URL?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst()).makeIterator()
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

func loadConfig(_ path: String?) -> (KeybowConfig, URL) {
    let url: URL
    if let path {
        url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    } else {
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KeybowNotes/config.json")
        url = FileManager.default.fileExists(atPath: installed.path)
            ? installed : URL(fileURLWithPath: "config.demo.json")
    }
    do {
        return (try KeybowConfig.load(from: url), url)
    } catch {
        fail("config error in \(url.path): \(error)")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: Options
    private let config: KeybowConfig
    private let configURL: URL
    private var driver: SelectionDriver?
    private var overlay: OverlayController?
    private var statusItem: NSStatusItem?
    private let connectionItem = NSMenuItem(title: "Keybow: looking…", action: nil, keyEquivalent: "")

    init(options: Options, config: KeybowConfig, configURL: URL) {
        self.options = options
        self.config = config
        self.configURL = configURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let overlay = OverlayController(config: config, placement: options.placement)
        overlay.debugDirectory = options.debugDirectory
        let driver = SelectionDriver(config: config, connection: KeybowConnection())
        self.overlay = overlay
        self.driver = driver
        setUpMenu()

        Task { @MainActor in
            for await snapshot in driver.snapshots { overlay.handle(snapshot) }
        }
        Task { @MainActor in
            for await event in driver.events {
                overlay.handle(event)
                log(event)
            }
        }
        Task { @MainActor [weak self] in
            for await event in driver.connectionEvents {
                overlay.handle(event)
                self?.updateConnection(event)
            }
        }
        driver.start()
        print("KeybowNotes demo running with \(configURL.lastPathComponent). Quit from the menu bar or with Ctrl-C.")

        if !options.simulated.isEmpty { simulate(options.simulated, pace: options.pace) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        driver?.stop()
        // Give the lights-off command a moment to reach the device.
        Thread.sleep(forTimeInterval: 0.2)
    }

    private func simulate(_ keys: [Int], pace: TimeInterval) {
        guard let driver else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            for key in keys {
                print("simulated press: key \(key)")
                driver.inject(.down(key: key))
                try? await Task.sleep(for: .milliseconds(120))
                driver.inject(.up(key: key))
                try? await Task.sleep(for: .seconds(pace))
            }
        }
    }

    // MARK: - Menu bar

    private func setUpMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "KeybowNotes")

        let menu = NSMenu()
        menu.addItem(withTitle: "KeybowNotes demo", action: nil, keyEquivalent: "").isEnabled = false
        connectionItem.isEnabled = false
        menu.addItem(connectionItem)
        let configItem = menu.addItem(withTitle: "Config: \(configURL.lastPathComponent)", action: nil, keyEquivalent: "")
        configItem.isEnabled = false
        menu.addItem(.separator())

        let placementItem = NSMenuItem(title: "Show on the main screen", action: #selector(togglePlacement(_:)), keyEquivalent: "")
        placementItem.target = self
        placementItem.state = options.placement == .mainScreen ? .on : .off
        menu.addItem(placementItem)
        let testItem = NSMenuItem(title: "Test the overlay", action: #selector(testOverlay), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func togglePlacement(_ sender: NSMenuItem) {
        guard let overlay else { return }
        overlay.placement = overlay.placement == .mainScreen ? .screenWithCursor : .mainScreen
        sender.state = overlay.placement == .mainScreen ? .on : .off
    }

    @objc private func testOverlay() {
        overlay?.flashNotice("The overlay appears here", symbol: "rectangle.inset.filled.and.person.filled")
    }

    private func updateConnection(_ event: KeybowEvent) {
        switch event {
        case .connected(let path):
            connectionItem.title = "Keybow: port open, waiting for a reply (\((path as NSString).lastPathComponent))"
        case .disconnected(let reason):
            connectionItem.title = "Keybow: not connected"
            print("disconnected: \(reason)")
        case .message(.hello(let version)):
            connectionItem.title = "Keybow: connected (protocol \(version))"
            print("device: HELLO, protocol \(version)")
        case .message(.pong):
            connectionItem.title = connectionItem.title.hasPrefix("Keybow: connected")
                ? connectionItem.title : "Keybow: connected"
        case .message(.deviceError(let text)):
            // Usually something else writing to the port.
            print("device: ERR \(text)")
        case .message(.unrecognised(let text)):
            print("device said something unexpected: \(text)")
        case .message:
            break
        }
    }

    private func log(_ event: NavigatorEvent) {
        switch event {
        case .selectionChanged(let selection):
            if let selection { print("selected: \(selection.pathDescription)  [\(selection.tree.rawValue)]") }
        case .invalidPress(let key):
            print("ignored key \(key)")
        case .pending(let selection):
            print("pending: \(selection.pathDescription)")
        case .fire(let selection):
            let summary = ActionSummary(selection: selection, config: config)
            var line = "FIRE (demo): \(summary.verb) · \(summary.subject)"
            if !summary.details.isEmpty { line += " · " + summary.details.joined(separator: " · ") }
            if !summary.missing.isEmpty { line += "  [missing: \(summary.missing.joined(separator: ", "))]" }
            print(line)
        case .cleared(let reason):
            print("cleared (\(reason.rawValue))")
        }
    }
}

let options = parseOptions()
let (config, configURL) = loadConfig(options.configPath)

// Top-level code runs on the main thread; tell the compiler so.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(options: options, config: config, configURL: configURL)
    app.delegate = delegate
    app.run()
}
