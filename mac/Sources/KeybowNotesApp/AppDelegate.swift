import AppKit
import KeybowKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: Options
    private let store: ConfigStore
    private var driver: SelectionDriver?
    private var overlay: OverlayController?
    private var statusItem: NSStatusItem?
    private var dryRun: Bool

    private let connectionItem = NSMenuItem(title: "Keybow: looking…", action: nil, keyEquivalent: "")
    private let configItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let problemItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: nil, keyEquivalent: "")

    /// A packaged app has a bundle identifier; `swift run` doesn't.
    private var isPackaged: Bool { Bundle.main.bundleIdentifier != nil }

    init(options: Options, store: ConfigStore) {
        self.options = options
        self.store = store
        self.dryRun = options.dryRun
    }

    private var config: KeybowConfig { store.config }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let overlay = OverlayController(config: config, placement: options.placement)
        overlay.debugDirectory = options.debugDirectory
        let driver = SelectionDriver(config: config, connection: KeybowConnection())
        self.overlay = overlay
        self.driver = driver
        setUpMenu()
        updateConfigItems()

        Task { @MainActor in
            for await snapshot in driver.snapshots { overlay.handle(snapshot) }
        }
        Task { @MainActor in
            for await event in driver.events {
                overlay.handle(event)
                self.log(event)
                if case .fire(let selection) = event { self.fire(selection) }
            }
        }
        Task { @MainActor [weak self] in
            for await event in driver.connectionEvents {
                overlay.handle(event)
                self?.updateConnection(event)
            }
        }
        driver.start()

        store.onChange = { [weak self] in self?.configChanged() }
        store.startWatching()

        Log.info("KeybowNotes \(versionDescription) running with \(store.url.path)\(dryRun ? " (dry run)" : "")")
        if let problem = store.problem {
            Log.error("config problem: \(problem)")
            overlay.flashNotice("Config problem — see the menu", symbol: "exclamationmark.triangle")
        }
        if !options.simulated.isEmpty { simulate(options.simulated, pace: options.pace) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        driver?.stop()
        // Give the lights-off command a moment to reach the device.
        Thread.sleep(forTimeInterval: 0.2)
    }

    // MARK: - Config

    private func configChanged() {
        updateConfigItems()
        if let problem = store.problem {
            Log.error("config problem: \(problem)")
            overlay?.flashNotice("Config not reloaded — see the menu", symbol: "exclamationmark.triangle")
            return
        }
        driver?.replaceConfig(config)
        overlay?.config = config
        Log.info("config reloaded")
        overlay?.flashNotice("Config reloaded", symbol: "arrow.clockwise")
    }

    private func updateConfigItems() {
        configItem.title = "Config: \(store.url.lastPathComponent)"
        if let problem = store.problem {
            problemItem.title = "⚠︎ " + (problem.count > 90 ? String(problem.prefix(90)) + "…" : problem)
            problemItem.toolTip = problem
            problemItem.isHidden = false
        } else {
            problemItem.isHidden = true
        }
    }

    // MARK: - Running actions

    private func fire(_ selection: ResolvedSelection) {
        guard let overlay else { return }
        let summary = ActionSummary(selection: selection, config: config)
        let path = selection.pathDescription

        if dryRun {
            overlay.showPreview(summary, path: path)
            return
        }

        let planned: PlannedAction
        do {
            planned = try ActionPlanner.plan(selection, config: config, context: ActionContext(
                templatesDirectory: store.templatesDirectory, environment: environment()))
        } catch {
            Log.info("  can't run: \(error)")
            overlay.showRefused("\(error)", summary: summary)
            return
        }

        overlay.showRunning(summary, path: path)
        Task { @MainActor in
            let started = Date()
            let outcome = await ActionRunner.run(planned.plan)
            let seconds = String(format: "%.1fs", Date().timeIntervalSince(started))
            let line = "  \(outcome.succeeded ? "done" : "FAILED") in \(seconds): \(outcome.message)"
                + (outcome.detail.map { " — \($0)" } ?? "")
            outcome.succeeded ? Log.info(line) : Log.error(line)
            for warning in planned.warnings { Log.info("  warning: \(warning)") }
            overlay.showFinished(outcome, summary: summary, warnings: planned.warnings)
        }
    }

    /// {{clipboard}} and {{frontApp}}. This app never takes focus, so the
    /// frontmost app is whatever you were using when you pressed the key.
    private func environment() -> [String: String] {
        var values: [String: String] = [:]
        if let text = NSPasteboard.general.string(forType: .string) {
            values["clipboard"] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName {
            values["frontApp"] = app
        }
        return values
    }

    private func simulate(_ keys: [Int], pace: TimeInterval) {
        guard let driver else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            for key in keys {
                Log.info("simulated press: key \(key)")
                driver.inject(.down(key: key))
                try? await Task.sleep(for: .milliseconds(120))
                driver.inject(.up(key: key))
                try? await Task.sleep(for: .seconds(pace))
            }
        }
    }

    // MARK: - Menu bar

    private var versionDescription: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "(development build)" }
        return "\(version) (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private func setUpMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "KeybowNotes")

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "KeybowNotes \(versionDescription)", action: nil, keyEquivalent: "").isEnabled = false
        for info in [connectionItem, configItem, problemItem] {
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())

        addItem(to: menu, "Reload Config", #selector(reloadConfig), key: "r")
        addItem(to: menu, "Open Config Folder", #selector(openConfigFolder))
        menu.addItem(.separator())

        addItem(to: menu, "Dry Run (Show, Don't Do)", #selector(toggleDryRun(_:))).state = dryRun ? .on : .off
        addItem(to: menu, "Show on the Main Screen", #selector(togglePlacement(_:))).state =
            options.placement == .mainScreen ? .on : .off
        loginItem.action = #selector(toggleLogin(_:))
        loginItem.target = self
        loginItem.isEnabled = isPackaged
        loginItem.toolTip = isPackaged ? nil : "Only available when run as KeybowNotes.app"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        addItem(to: menu, "Test the Overlay", #selector(testOverlay))

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit KeybowNotes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func reloadConfig() {
        store.reload()
    }

    @objc private func openConfigFolder() {
        let folder = store.url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([store.url.hasDirectoryPath ? folder : store.url])
    }

    @objc private func togglePlacement(_ sender: NSMenuItem) {
        guard let overlay else { return }
        overlay.placement = overlay.placement == .mainScreen ? .screenWithCursor : .mainScreen
        sender.state = overlay.placement == .mainScreen ? .on : .off
    }

    @objc private func toggleDryRun(_ sender: NSMenuItem) {
        dryRun.toggle()
        sender.state = dryRun ? .on : .off
        Log.info(dryRun ? "dry run: on" : "dry run: off — actions will run")
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            Log.error("open at login: \(error.localizedDescription)")
            overlay?.flashNotice("Couldn't change Open at Login: \(error.localizedDescription)",
                                 symbol: "exclamationmark.triangle")
        }
        sender.state = service.status == .enabled ? .on : .off
        if service.status == .requiresApproval {
            overlay?.flashNotice("Approve KeybowNotes in System Settings → General → Login Items",
                                 symbol: "person.badge.key")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func testOverlay() {
        overlay?.flashNotice("The overlay appears here", symbol: "rectangle.inset.filled.and.person.filled")
    }

    // MARK: - Logging

    private func updateConnection(_ event: KeybowEvent) {
        switch event {
        case .connected(let path):
            connectionItem.title = "Keybow: port open, waiting for a reply (\((path as NSString).lastPathComponent))"
        case .disconnected(let reason):
            connectionItem.title = "Keybow: not connected"
            Log.info("disconnected: \(reason)")
        case .message(.hello(let version)):
            connectionItem.title = "Keybow: connected (protocol \(version))"
            Log.info("device: HELLO, protocol \(version)")
        case .message(.pong):
            if !connectionItem.title.hasPrefix("Keybow: connected") { connectionItem.title = "Keybow: connected" }
        case .message(.deviceError(let text)):
            // Usually something else writing to the port.
            Log.error("device: ERR \(text)")
        case .message(.unrecognised(let text)):
            Log.error("device said something unexpected: \(text)")
        case .message:
            break
        }
    }

    private func log(_ event: NavigatorEvent) {
        switch event {
        case .selectionChanged(let selection):
            if let selection { Log.info("selected: \(selection.pathDescription)  [\(selection.tree.rawValue)]") }
        case .invalidPress(let key):
            Log.info("ignored key \(key)")
        case .pending(let selection):
            Log.info("pending: \(selection.pathDescription)")
        case .fire(let selection):
            let summary = ActionSummary(selection: selection, config: config)
            var line = "FIRE: \(summary.verb) · \(summary.subject)"
            if !summary.details.isEmpty { line += " · " + summary.details.joined(separator: " · ") }
            if !summary.missing.isEmpty { line += "  [missing: \(summary.missing.joined(separator: ", "))]" }
            Log.info(line)
        case .cleared(let reason):
            Log.info("cleared (\(reason.rawValue))")
        }
    }
}
