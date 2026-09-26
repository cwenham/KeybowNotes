import AppKit
import EventKit
import KeybowKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let options: Options
    private let settings = AppSettings()
    private var store: ConfigStore
    private var driver: SelectionDriver?
    private var overlay: OverlayController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: SettingsWindowController?

    private let connectionItem = NSMenuItem(title: "Keybow: looking…", action: nil, keyEquivalent: "")
    private let configItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let problemItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let dryRunItem = NSMenuItem(title: "Dry Run (Show, Don't Do)", action: nil, keyEquivalent: "")
    private let accessItem = NSMenuItem(title: "Allow Calendar and Reminders Access…", action: nil, keyEquivalent: "")

    /// A packaged app has a bundle identifier; `swift run` doesn't.
    private var isPackaged: Bool { Bundle.main.bundleIdentifier != nil }

    init(options: Options) {
        self.options = options
        // A --config on the command line wins for this run, without being saved.
        let url = options.configPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? AppSettings().configURL
        store = ConfigStore(url: url)
    }

    /// The config as it runs: the file's tree, with any timings set in Settings.
    private var config: KeybowConfig { settings.apply(to: store.config) }
    private var dryRun: Bool { options.dryRun || settings.dryRun }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let overlay = OverlayController(config: config, placement: options.placement ?? settings.placement)
        overlay.debugDirectory = options.debugDirectory
        let driver = SelectionDriver(config: config, connection: KeybowConnection())
        driver.setBrightness(settings.brightness)
        self.overlay = overlay
        self.driver = driver
        setUpMenu()
        updateConfigStatus()
        refreshOpenAtLogin()

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

        watch(store)
        settings.onChange = { [weak self] change in self?.settingsChanged(change) }

        Log.info("KeybowNotes \(versionDescription) running with \(store.url.path)\(dryRun ? " (dry run)" : "")")
        if let problem = store.problem {
            Log.error("config problem: \(problem)")
            overlay.flashNotice("Config problem — see Settings", symbol: "exclamationmark.triangle")
        }
        if !options.simulated.isEmpty { simulate(options.simulated, pace: options.pace) }
        if options.showSettings { showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        driver?.stop()
        // Give the lights-off command a moment to reach the device.
        Thread.sleep(forTimeInterval: 0.2)
    }

    // MARK: - Settings

    private func settingsChanged(_ change: AppSettings.Change) {
        switch change {
        case .placement:
            overlay?.placement = settings.placement
        case .timing:
            applyConfig()
        case .brightness:
            driver?.setBrightness(settings.brightness)
        case .dryRun:
            dryRunItem.state = dryRun ? .on : .off
            Log.info(dryRun ? "dry run: on" : "dry run: off — actions will run")
        case .configFile:
            switchConfig(to: settings.configURL)
        case .defaults:
            break    // read when an action runs
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings, actions: SettingsActions(
                testOverlay: { [weak self] in
                    self?.overlay?.flashNotice("The overlay appears here", symbol: "rectangle.inset.filled")
                },
                requestCalendarAccess: { [weak self] in await self?.requestCalendarAccess() },
                reloadConfig: { [weak self] in self?.store.reload() },
                loadCalendarChoices: {
                    guard EventKitService.isAvailable else { return ([], []) }
                    return (await EventKitService.shared.writableCalendars(),
                            await EventKitService.shared.reminderLists())
                },
                setOpenAtLogin: { [weak self] enabled in self?.setOpenAtLogin(enabled) }
            ))
        }
        refreshOpenAtLogin()
        settingsWindow?.show()
    }

    // MARK: - Config

    private func watch(_ store: ConfigStore) {
        store.onChange = { [weak self] in self?.configChanged() }
        store.startWatching()
    }

    private func switchConfig(to url: URL) {
        guard url != store.url else { return }
        store.stopWatching()
        store = ConfigStore(url: url)
        watch(store)
        Log.info("config file: \(url.path)")
        configChanged()
    }

    private func configChanged() {
        updateConfigStatus()
        if let problem = store.problem {
            Log.error("config problem: \(problem)")
            overlay?.flashNotice("Config not loaded — see Settings", symbol: "exclamationmark.triangle")
            return
        }
        applyConfig()
        Log.info("config reloaded")
        overlay?.flashNotice("Config reloaded", symbol: "arrow.clockwise")
    }

    private func applyConfig() {
        driver?.replaceConfig(config)
        overlay?.config = config
    }

    private func updateConfigStatus() {
        configItem.title = "Config: \(store.url.lastPathComponent)"
        if let problem = store.problem {
            problemItem.title = "⚠︎ " + (problem.count > 90 ? String(problem.prefix(90)) + "…" : problem)
            problemItem.toolTip = problem
            problemItem.isHidden = false
        } else {
            problemItem.isHidden = true
        }
        settings.configProblem = store.problem
        settings.configSummary = store.problem == nil ? summary(of: store.config) : ""
        let file = store.config
        settings.fileTimings = (file.commitDelay, file.idleTimeout, file.longPressCancel)
    }

    /// "Main tree: 4 branches, 87 choices · Bottom tree: 2 branches, 19 choices"
    private func summary(of config: KeybowConfig) -> String {
        func leaves(_ nodes: [TreeNode?]) -> Int {
            nodes.compactMap { $0 }.reduce(0) { $0 + ($1.isLeaf ? 1 : leaves($1.children)) }
        }
        let parts = TreeKind.allCases.compactMap { tree -> String? in
            let roots = config.roots(tree).compactMap { $0 }
            guard !roots.isEmpty else { return nil }
            let name = tree == .main ? "Main" : tree == .bottom ? "Bottom" : tree == .row2 ? "Row 2" : "Row 3"
            return "\(name) tree: \(roots.count) branches, \(leaves(config.roots(tree))) choices"
        }
        return parts.isEmpty ? "No trees yet." : parts.joined(separator: " · ")
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
                templatesDirectory: store.templatesDirectory,
                environment: environment(),
                defaultCalendarID: settings.defaultCalendarID,
                defaultReminderListID: settings.defaultReminderListID))
        } catch {
            Log.info("  can't run: \(error)")
            overlay.showRefused("\(error)", summary: summary)
            return
        }

        bringPermissionPromptsForward(for: planned.plan)
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

    /// The first event or reminder asks for access. This app never comes to the
    /// front, so without this the prompt can open behind other windows, out of
    /// sight — and the action waits on it.
    private func bringPermissionPromptsForward(for plan: ActionPlan) {
        guard EventKitService.isAvailable else { return }
        let type: EKEntityType
        switch plan {
        case .createEvent: type = .event
        case .createReminder: type = .reminder
        default: return
        }
        if EventKitService.status(for: type) == .notDetermined { NSApp.activate() }
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

    // MARK: - Calendar access and login item

    private func requestCalendarAccess() async {
        // Come forward so the prompts do too.
        NSApp.activate()
        var problems: [EventKitService.AccessError] = []
        for type in [EKEntityType.event, .reminder] {
            do {
                try await EventKitService.shared.ensureAccess(to: type)
            } catch let error as EventKitService.AccessError {
                problems.append(error)
            } catch {
                problems.append(.init(message: error.localizedDescription, detail: ""))
            }
        }
        updateAccessItem()
        if problems.isEmpty {
            Log.info("calendar and reminders access allowed")
            overlay?.flashNotice("Calendar and Reminders access allowed", symbol: "checkmark.circle")
        } else {
            let text = problems.map(\.message).joined(separator: "; ")
            Log.error("access: \(text)")
            overlay?.flashNotice(text, symbol: "exclamationmark.triangle")
            // Straight to the place it can be changed.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            Log.error("open at login: \(error.localizedDescription)")
        }
        refreshOpenAtLogin()
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    private func refreshOpenAtLogin() {
        guard isPackaged else {
            settings.openAtLogin = false
            settings.openAtLoginNote = "Only available when running as KeybowNotes.app."
            return
        }
        let status = SMAppService.mainApp.status
        settings.openAtLogin = status == .enabled
        settings.openAtLoginNote = status == .requiresApproval
            ? "Approve KeybowNotes in System Settings → General → Login Items." : nil
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

        addItem(to: menu, "Settings…", #selector(openSettings), key: ",")
        addItem(to: menu, "Reload Config", #selector(reloadConfig), key: "r")
        addItem(to: menu, "Open Config Folder", #selector(openConfigFolder))
        menu.addItem(.separator())

        dryRunItem.action = #selector(toggleDryRun)
        dryRunItem.target = self
        dryRunItem.state = dryRun ? .on : .off
        menu.addItem(dryRunItem)
        accessItem.action = #selector(askForCalendarAccess)
        accessItem.target = self
        menu.addItem(accessItem)
        updateAccessItem()

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit KeybowNotes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
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

    func menuWillOpen(_ menu: NSMenu) {
        updateAccessItem()
    }

    /// Shown only while there's something to do about it.
    private func updateAccessItem() {
        let allowed = EventKitService.status(for: .event) == .fullAccess
            && EventKitService.status(for: .reminder) == .fullAccess
        accessItem.isHidden = !EventKitService.isAvailable || allowed
    }

    @objc private func openSettings() { showSettings() }

    @objc private func reloadConfig() { store.reload() }

    @objc private func openConfigFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.url])
    }

    @objc private func toggleDryRun() {
        settings.dryRun.toggle()
    }

    @objc private func askForCalendarAccess() {
        Task { await requestCalendarAccess() }
    }

    // MARK: - Logging

    private func updateConnection(_ event: KeybowEvent) {
        switch event {
        case .connected(let path):
            connectionItem.title = "Keybow: port open, waiting for a reply (\((path as NSString).lastPathComponent))"
            settings.keybowStatus = "Port open, waiting for a reply"
        case .disconnected(let reason):
            connectionItem.title = "Keybow: not connected"
            settings.keybowStatus = "Not connected"
            Log.info("disconnected: \(reason)")
        case .message(.hello(let version)):
            connectionItem.title = "Keybow: connected (protocol \(version))"
            settings.keybowStatus = "Connected"
            Log.info("device: HELLO, protocol \(version)")
        case .message(.pong):
            if !connectionItem.title.hasPrefix("Keybow: connected") {
                connectionItem.title = "Keybow: connected"
                settings.keybowStatus = "Connected"
            }
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
