import AppKit
import EventKit
import KeybowKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let options: Options
    private let settings = AppSettings()
    private var store: ConfigStore
    /// One per keypad found, by its unique ID: its driver, and how it's doing.
    private var keypads: [String: KeypadLink] = [:]
    private var keypadOrder: [String] = []
    /// The keypad whose choosing the overlay shows: the last one pressed.
    private var activeKeypad: String?
    /// The page each keypad last showed: turning one is using it.
    private var shownPages: [String: KeypadPage] = [:]
    private var discovery: Timer?

    private struct KeypadLink {
        /// Nil for the stand-in that --simulate presses, with no keypad.
        let device: KeypadDevice?
        let driver: SelectionDriver
        var status = "looking"
        var name: String { device?.model.title ?? "Keypad" }
    }

    /// The config a keypad runs: its own trees, everything else shared.
    private func config(for link: KeypadLink) -> KeybowConfig {
        link.device.map(config.forDevice) ?? config
    }
    private var overlay: OverlayController?
    private let displays = DisplayController()
    private var statusItem: NSStatusItem?
    private var settingsWindow: SettingsWindowController?
    private var editorWindow: EditorWindowController?
    private var setupWindow: KeypadSetupWindowController?
    /// Keeps the menu bar's clock up to date while a module's clock runs.
    private var moduleClock: Timer?
    /// Modules' commands go after this, rebuilt each time the menu opens.
    private let moduleMenuAnchor = NSMenuItem.separator()
    /// Values being fetched and replies worked out for an action; one at a
    /// time, cancellable.
    private var pendingWork: Task<Void, Never>?
    private let cancelWorkItem = NSMenuItem(title: "Cancel Waiting", action: nil, keyEquivalent: "")
    private var moduleMenuItems: [NSMenuItem] = []

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
        installMainMenu()
        let overlay = OverlayController(config: config, placement: options.placement ?? settings.placement)
        overlay.debugDirectory = options.debugDirectory
        self.overlay = overlay
        setUpMenu()
        updateConfigStatus()
        refreshOpenAtLogin()

        // Every keypad, as it's plugged in: found by its unique ID, each with
        // a driver — its own trees, lights and choosing — of its own.
        discoverKeypads()
        discovery = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.discoverKeypads() }
        }
        updateKeypadStatus()

        watch(store)
        settings.onChange = { [weak self] change in self?.settingsChanged(change) }
        Modules.host.onChange = { [weak self] in self?.refreshModules() }
        Modules.host.templatesFolder = store.templatesDirectory
        displays.screen = { [weak overlay] in overlay?.screen ?? NSScreen.main ?? NSScreen.screens[0] }
        displays.onShow = { [weak overlay] in overlay?.stepAside() }
        Modules.host.onDisplay = { [displays] display in await displays.show(display) }
        refreshModules()

        Log.info("KeybowNotes \(versionDescription) running with \(store.url.path)\(dryRun ? " (dry run)" : "")")
        if let problem = Modules.host.state.problem {
            Log.error("state: \(problem)")
        }
        if let problem = store.problem {
            Log.error("config problem: \(problem)")
            overlay.flashNotice("Config problem — see Settings", symbol: "exclamationmark.triangle")
        } else if store.mistakes.mistakeCount > 0 {
            logMistakes()
            overlay.flashNotice(mistakesNotice, symbol: "exclamationmark.triangle")
        }
        if !options.simulated.isEmpty { simulate(options.simulated, pace: options.pace) }
        if options.showSettings { showSettings() }
        if options.showDataSources { _ = ModuleRegistry.shared.module(id: "api")?.performMenuItem("open", now: Date()) }
        if options.editTree { showEditor() }
        if options.setUpKeypad { showKeypadSetup() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        discovery?.invalidate()
        for link in keypads.values { link.driver.stop() }
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
            for link in keypads.values { link.driver.setBrightness(settings.brightness) }
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
        Modules.host.templatesFolder = store.templatesDirectory
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
        if store.mistakes.mistakeCount == 0 {
            overlay?.flashNotice("Config reloaded", symbol: "arrow.clockwise")
        } else {
            logMistakes()
            overlay?.flashNotice(mistakesNotice, symbol: "exclamationmark.triangle")
        }
    }

    private var mistakesNotice: String {
        let count = store.mistakes.mistakeCount
        return "Tree loaded, with \(count) mistake\(count == 1 ? "" : "s") — see the editor"
    }

    /// Lines only: a message can quote a label, and labels can be names.
    private func logMistakes() {
        let lines = store.mistakes.errors.map { String($0.line) }.joined(separator: ", ")
        Log.info("config has \(store.mistakes.mistakeCount) mistake(s)\(lines.isEmpty ? "" : ", at lines \(lines)"); the rest is in use")
    }

    private func applyConfig() {
        for link in keypads.values { link.driver.replaceConfig(config(for: link)) }
        overlay?.config = config
        refreshModules()
    }

    // MARK: - Modules

    /// Shows what the modules are doing: on the overlay, in the menu bar, and
    /// by pulsing the keys that lead to a busy module's actions.
    private func refreshModules() {
        let registry = ModuleRegistry.shared
        let statuses = registry.statuses(now: Date())
        overlay?.setModuleStatuses(statuses)

        let busyTypes = Set(statuses.filter(\.lightsKeys)
            .compactMap { registry.module(id: $0.moduleID) }
            .flatMap { $0.manifest.actionTypes.map(\.type) })
        for link in keypads.values {
            let config = config(for: link)
            link.driver.setPulsingKeys(busyTypes.isEmpty ? [] : config.entryKeys(toActionTypes: busyTypes),
                                       onPages: busyTypes.isEmpty ? [:] : config.pageKeys(toActionTypes: busyTypes))
        }
        updateMenuBarClock(statuses.first)
    }

    private func updateMenuBarClock(_ status: ModuleStatus?) {
        moduleClock?.invalidate()
        moduleClock = nil
        guard let item = statusItem, let button = item.button else { return }
        guard let status else {
            item.length = NSStatusItem.squareLength
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = nil
            return
        }
        item.length = NSStatusItem.variableLength
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.toolTip = [status.title, status.detail].compactMap { $0 }.joined(separator: " — ")
        button.title = " " + ModuleClock.text(for: status)
        guard status.countingFrom != nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let text = " " + ModuleClock.text(for: status)
                if button.title != text { button.title = text }
            }
        }
        // Common modes, so it keeps counting while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        moduleClock = timer
    }

    private func updateConfigStatus() {
        configItem.title = "Config: \(store.url.lastPathComponent)"
        if let problem = store.problem ?? store.mistakes.describe(in: store.url) {
            problemItem.title = "⚠︎ " + (problem.count > 90 ? String(problem.prefix(90)) + "…" : problem)
            problemItem.toolTip = problem
            problemItem.isHidden = false
        } else {
            problemItem.isHidden = true
        }
        settings.configProblem = store.problem ?? store.mistakes.describe(in: store.url)
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

    /// `chosenAt` is when the key was pressed: the action's "now", so a
    /// stopwatch starts on the press, not when the overlay has caught up.
    /// `values` join what the action can use: a display's `{{displayed}}`,
    /// for the action its OK runs.
    private func fire(_ selection: ResolvedSelection, chosenAt: Date = Date(), values: [String: String] = [:]) {
        guard let overlay else { return }
        let path = selection.pathDescription

        if dryRun {
            overlay.showPreview(ActionSummary(selection: selection, config: config), path: path)
            return
        }

        var context = ActionContext(
            templatesDirectory: store.templatesDirectory,
            now: chosenAt,
            environment: environment().merging(values) { _, given in given },
            defaultCalendarID: settings.defaultCalendarID,
            defaultReminderListID: settings.defaultReminderListID)

        // Blocks — {{#ai}} — are refused before anything is asked where a
        // reply could steer the action, and one lot at a time.
        let blockTexts: [String]
        do {
            blockTexts = try ActionPlanner.blockTexts(for: selection, context: context)
        } catch {
            Log.info("  can't run: \(error)")
            overlay.showRefused("\(error)", summary: ActionSummary(selection: selection, config: config))
            return
        }
        // Values modules fetch — {{api.weather}} — and what they need first.
        let registry = ModuleRegistry.shared
        let used = ActionPlanner.placeholders(for: selection, context: context)
        // A value the tree gives itself — `location: Office` — isn't fetched.
        let given = ActionPlanner.values(for: selection, context: context)
        let fetchedNames = registry.fetchedNames(in: used).filter { given[$0] == nil }
        let needed = used.union(registry.valuesNeeded(toFetch: fetchedNames))
        let waits = !blockTexts.isEmpty || !fetchedNames.isEmpty
        if waits, pendingWork != nil {
            overlay.showRefused("Still waiting on the last fetch or replies. Cancel it, or let it finish, then press again.",
                                summary: ActionSummary(selection: selection, config: config))
            return
        }

        let needsSelection = needed.contains("selection")
        guard needsSelection || waits else {
            run(selection, context: context)
            return
        }
        // The app to type into, if it comes to that: waiting leaves time to
        // switch to another.
        let frontApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let work = Task { @MainActor in
            defer { if waits { self.pendingWork = nil } }
            // Read only when asked for: it can mean sending the app ⌘C.
            if needsSelection {
                switch await SelectedText.read(copyIfNeeded: settings.copySelection) {
                case .text(let text):
                    context.environment["selection"] = text
                case .nothingSelected:
                    break
                case .notAllowed:
                    Log.info("  can't run: no Accessibility access for {{selection}}")
                    overlay.showRefused("KeybowNotes needs Accessibility access to read the selected text. "
                                        + "Allow it in System Settings, then press again.",
                                        summary: ActionSummary(selection: selection, config: config))
                    SelectedText.requestAccess()
                    return
                }
            }
            if waits {
                guard let prepared = await prepare(fetchedNames, blockTexts, selection: selection, context: context) else {
                    return
                }
                context = prepared
            }
            run(selection, context: context, typingInto: waits ? frontApp : nil)
        }
        if waits { pendingWork = work }
    }

    /// Fetches the values the action uses, then works out its blocks —
    /// innermost first, those that can go together at once — with a timer
    /// and a Cancel button on the HUD. Nil if cancelled or refused, having
    /// said so.
    private func prepare(_ fetchedNames: [String], _ texts: [String], selection: ResolvedSelection,
                         context: ActionContext) async -> ActionContext? {
        guard let overlay else { return nil }
        var context = context
        let summary = ActionSummary(selection: selection, config: config, environment: context.environment)
        let registry = ModuleRegistry.shared
        let askers = Set(texts.flatMap(TemplateBlocks.names(in:)).compactMap { name in
            registry.module(handlingBlock: name)?.manifest.blocks.first { $0.name == name }?.title
        })
        let askTitle = askers.count == 1 ? "Asking \(askers.first!)…" : "Waiting for replies…"
        let fetchTitle = "Fetching " + registry.fetchSubject(for: fetchedNames,
                                                            given: ActionPlanner.values(for: selection, context: context)) + "…"
        // Shown only if the wait lasts: a quote from a file, or a kept
        // response, is there before it would be seen.
        let title = WaitTitle(fetchedNames.isEmpty ? askTitle : fetchTitle)
        let showing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            overlay.showWorking(summary, path: selection.pathDescription, title: title.text) { self?.cancelReplies() }
        }
        defer {
            showing.cancel()
            overlay.endWorking()
        }
        // Development builds only: press Cancel after a while, for testing.
        if Bundle.main.bundleIdentifier == nil,
           let after = Double(ProcessInfo.processInfo.environment["KEYBOW_DEBUG_CANCEL_AFTER"] ?? "") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(after))
                self?.cancelReplies()
            }
        }

        let started = Date()
        do {
            if !fetchedNames.isEmpty {
                let values = try await registry.fetch(fetchedNames, params: ActionPlanner.values(for: selection, context: context),
                                                      now: context.now)
                context.environment.merge(values) { _, fetched in fetched }
                Log.info(String(format: "  fetched %d value%@ in %.1fs", values.count, values.count == 1 ? "" : "s",
                                Date().timeIntervalSince(started)))
            }
            if !texts.isEmpty {
                title.text = askTitle
                overlay.updateWorking(title: askTitle)
                let replies = try await TemplateBlocks.resolve(
                    texts, params: ActionPlanner.values(for: selection, context: context),
                    now: context.now, calendar: context.calendar) { call in
                    try await ModuleRegistry.shared.reply(to: call)
                }
                Log.info(String(format: "  %d repl%@ in %.1fs", replies.count, replies.count == 1 ? "y" : "ies",
                                Date().timeIntervalSince(started)))
                context.blockReplies = replies
            }
            return context
        } catch is CancellationError {
            Log.info("  cancelled while waiting")
            overlay.handle(.cleared(reason: .cancelled))
        } catch let error as ModuleError {
            // Only the headline is logged: the detail can quote a server, and
            // a server can quote back what it was sent — the selection, say.
            Log.error("  FAILED while waiting: \(error.message)")
            overlay.showFinished(.failure(error.message, error.detail), summary: summary, warnings: [])
        } catch {
            Log.error("  FAILED while waiting: \(error)")
            overlay.showRefused("\(error)", summary: summary)
        }
        return nil
    }

    @objc private func cancelReplies() {
        pendingWork?.cancel()
    }

    private func run(_ selection: ResolvedSelection, context: ActionContext, typingInto frontApp: pid_t? = nil) {
        guard let overlay else { return }
        let summary = ActionSummary(selection: selection, config: config, environment: context.environment)
        let path = selection.pathDescription

        // The system log is kept on disk and readable by any admin, so the
        // selected text, the clipboard and anything copied stay out of it.
        var isPrivate = !ActionPlanner.placeholders(for: selection, context: context)
            .isDisjoint(with: ["selection", "clipboard", "displayed", "answer"])

        let planned: PlannedAction
        do {
            planned = try ActionPlanner.plan(selection, config: config, context: context)
        } catch {
            Log.info("  can't run: \(isPrivate ? "(details not logged)" : "\(error)")")
            overlay.showRefused("\(error)", summary: summary)
            return
        }
        switch planned.plan {
        case .copyToClipboard, .insertText, .insertTextDirectly: isPrivate = true
        default: break
        }
        // Inserting text into another app needs Accessibility access.
        let inserts: Bool
        switch planned.plan {
        case .insertText, .insertTextDirectly: inserts = true
        default: inserts = false
        }
        if inserts, !SelectedText.isAllowed {
            Log.info("  can't run: no Accessibility access for inserting text")
            overlay.showRefused("KeybowNotes needs Accessibility access to type into other apps. "
                                + "Allow it in System Settings, then press again.", summary: summary)
            SelectedText.requestAccess()
            return
        }
        // Switched apps while waiting on replies: don't type into the wrong one.
        if inserts, let frontApp, NSWorkspace.shared.frontmostApplication?.processIdentifier != frontApp {
            switch planned.plan {
            case .insertText(let text), .insertTextDirectly(let text, _):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            default:
                break
            }
            Log.info("  not inserted: the app in front changed while waiting")
            overlay.showRefused("You switched apps while waiting, so the text wasn't typed in. It's on the clipboard instead.",
                                summary: summary)
            return
        }

        bringPermissionPromptsForward(for: planned.plan)
        overlay.showRunning(summary, path: path)
        Task { @MainActor [isPrivate] in
            let started = Date()
            let outcome = await ActionRunner.run(planned.plan)
            let seconds = String(format: "%.1fs", Date().timeIntervalSince(started))
            let line = "  \(outcome.succeeded ? "done" : "FAILED") in \(seconds)"
                + (isPrivate ? " (details not logged)" : ": \(outcome.message)" + (outcome.detail.map { " — \($0)" } ?? ""))
            outcome.succeeded ? Log.info(line) : Log.error(line)
            for warning in planned.warnings where !isPrivate { Log.info("  warning: \(warning)") }
            if let next = outcome.followUp {
                self.follow(next, of: selection, values: outcome.values, text: outcome.followUpText)
            } else if !outcome.isQuiet {
                overlay.showFinished(outcome, summary: summary, warnings: planned.warnings)
            }
        }
    }

    /// Runs the node's own `ok` or `cancel` action, as though its key had just
    /// been pressed — or nothing, when it has none.
    private func follow(_ key: String, of selection: ResolvedSelection, values: [String: String], text: String?) {
        guard let next = selection.action?.nestedAction(key) else { return }
        Log.info("  then \(key): \(next.type)")
        var fields = next.fields
        // Copy, Insert and the like, given no text: what was shown, or typed.
        if fields["text"] == nil, fields["template"] == nil, let text { fields["text"] = .string(text) }
        fire(selection.with(action: ActionSpec(type: next.type, fields: fields)), values: values)
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

    /// {{clipboard}} and {{frontApp}}; {{selection}} is added by `fire` when
    /// needed. This app never takes focus, so the frontmost app is whatever you
    /// were using when you pressed the key.
    private func environment() -> [String: String] {
        var values = ModuleRegistry.shared.values(now: Date())
        if let text = NSPasteboard.general.string(forType: .string) {
            values["clipboard"] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let app = NSWorkspace.shared.frontmostApplication?.localizedName {
            values["frontApp"] = app
        }
        return values
    }

    private func simulate(_ keys: [Int], pace: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            // The first keypad found — or, with none, a stand-in that never connects.
            let driver = keypadOrder.first.flatMap { keypads[$0]?.driver } ?? addKeypad(nil, serial: "simulated").driver
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

    /// Never shown — a menu-bar app has no menu bar — but key equivalents are
    /// looked up here, so without it ⌘Z, ⌘S, ⌘C and ⌘V would do nothing in the
    /// editor and settings windows.
    private func installMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        submenu("KeybowNotes", [item("Quit KeybowNotes", #selector(NSApplication.terminate(_:)), "q")])
        submenu("File", [
            item("Save", #selector(EditorWindowController.saveDocument(_:)), "s"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Add Child", #selector(EditorWindowController.addChildNode(_:)), "\r", [.command]),
            item("Move Node Up", #selector(EditorWindowController.moveNodeUp(_:)),
                 String(UnicodeScalar(NSUpArrowFunctionKey)!), [.control, .command]),
            item("Move Node Down", #selector(EditorWindowController.moveNodeDown(_:)),
                 String(UnicodeScalar(NSDownArrowFunctionKey)!), [.control, .command]),
        ])
        NSApp.mainMenu = main
    }

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
        cancelWorkItem.action = #selector(cancelReplies)
        cancelWorkItem.target = self
        cancelWorkItem.isHidden = true
        menu.addItem(cancelWorkItem)
        menu.addItem(.separator())

        addItem(to: menu, "Edit Tree…", #selector(openEditor), key: "e")
        addItem(to: menu, "Set Up a Keypad…", #selector(openKeypadSetup))
        addItem(to: menu, "Settings…", #selector(openSettings), key: ",")
        addItem(to: menu, "Reload Config", #selector(reloadConfig), key: "r")
        addItem(to: menu, "Open Config Folder", #selector(openConfigFolder))
        menu.addItem(moduleMenuAnchor)

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
        cancelWorkItem.isHidden = pendingWork == nil
        updateModuleMenuItems(in: menu)
    }

    /// Each module's commands, under its name, disabled when there's nothing
    /// for them to do: the stopwatch's Stop, Lap and Reset.
    private func updateModuleMenuItems(in menu: NSMenu) {
        for item in moduleMenuItems { menu.removeItem(item) }
        moduleMenuItems = []
        var index = menu.index(of: moduleMenuAnchor) + 1
        let now = Date()
        for module in ModuleRegistry.shared.all {
            let commands = module.menuItems(now: now)
            guard !commands.isEmpty else { continue }
            var items = [NSMenuItem.sectionHeader(title: module.manifest.name)]
            for command in commands {
                let item = menuItem(for: command, of: module)
                item.indentationLevel = 1
                items.append(item)
            }
            items.append(.separator())
            for item in items {
                menu.insertItem(item, at: index)
                index += 1
            }
            moduleMenuItems += items
        }
    }

    /// A command, a submenu of them, or — with no id — a line that only
    /// shows something, like a lap time, with digits that line up.
    private func menuItem(for command: ModuleMenuItem, of module: KeybowModule) -> NSMenuItem {
        let item = NSMenuItem(title: command.title, action: nil, keyEquivalent: "")
        item.isEnabled = command.isEnabled
        if !command.submenu.isEmpty {
            let submenu = NSMenu(title: command.title)
            submenu.autoenablesItems = false
            for child in command.submenu { submenu.addItem(menuItem(for: child, of: module)) }
            item.submenu = submenu
        } else if command.id.isEmpty {
            item.attributedTitle = NSAttributedString(string: command.title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ])
        } else {
            item.action = #selector(runModuleMenuItem(_:))
            item.target = self
            item.representedObject = [module.manifest.id, command.id]
        }
        return item
    }

    @objc private func runModuleMenuItem(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String], ids.count == 2,
              let module = ModuleRegistry.shared.module(id: ids[0]),
              let outcome = module.performMenuItem(ids[1], now: Date()) else { return }
        Log.info("menu: \(module.manifest.name) \(ids[1]) — \(outcome.message)")
        let symbol = module.manifest.actionTypes.first?.symbol ?? "puzzlepiece"
        overlay?.flashNotice(outcome.message, symbol: symbol)
    }

    /// Shown only while there's something to do about it.
    private func updateAccessItem() {
        let allowed = EventKitService.status(for: .event) == .fullAccess
            && EventKitService.status(for: .reminder) == .fullAccess
        accessItem.isHidden = !EventKitService.isAvailable || allowed
    }

    @objc private func openSettings() { showSettings() }

    @objc private func openEditor() { showEditor() }

    @objc private func openKeypadSetup() { showKeypadSetup() }

    /// Puts CircuitPython and the firmware on a keypad; done when this app has
    /// heard it say hello.
    private func showKeypadSetup() {
        if setupWindow == nil {
            setupWindow = KeypadSetupWindowController(
                backups: ConfigStore.supportDirectory.appendingPathComponent("Keypad Backups", isDirectory: true),
                stopProgram: { [weak self] serial in await self?.stopKeypadProgram(serial) ?? false },
                isConnected: { [weak self] serial in await self?.isKeypadConnected(serial) ?? false },
                openEditor: { [weak self] in self?.showEditor() })
        }
        setupWindow?.show()
    }

    /// Ends the keypad's program so its console can restart it: this app has
    /// its data port.
    private func stopKeypadProgram(_ serial: String) -> Bool {
        guard let link = keypads.first(where: { $0.key.caseInsensitiveCompare(serial) == .orderedSame })?.value,
              link.status == "connected" else { return false }
        link.driver.send(.stop)
        return true
    }

    private func isKeypadConnected(_ serial: String) -> Bool {
        keypads.contains { $0.key.caseInsensitiveCompare(serial) == .orderedSame && $0.value.status == "connected" }
    }

    /// The tree editor, on the tree in use — or on `tree.md` beside a
    /// compiled JSON config given for testing.
    private func showEditor() {
        let outline = ConfigFile.isOutline(store.url)
            ? store.url : store.url.deletingLastPathComponent().appendingPathComponent("tree.md")
        if editorWindow == nil || editorWindow?.model.outlineURL != outline {
            editorWindow = EditorWindowController(outlineURL: outline)
        }
        // Saving is loading: the app picks the tree up at once, not at the next look.
        editorWindow?.model.onSaved = { [weak self] in
            guard let self, self.store.url == outline else { return }
            self.store.reload()
        }
        editorWindow?.show()
    }

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

    // MARK: - Keypads

    /// Starts a driver for each keypad not yet known. One that goes away keeps
    /// its driver, which reconnects when it's back.
    private func discoverKeypads() {
        for device in USBSerialPorts.keypads() where keypads[device.serial] == nil {
            Log.info("keypad found: \(device.model.title) \(device.serial)")
            addKeypad(device, serial: device.serial)
        }
    }

    @discardableResult
    private func addKeypad(_ device: KeypadDevice?, serial: String) -> KeypadLink {
        let driver = SelectionDriver(config: device.map(config.forDevice) ?? config,
                                     connection: KeybowConnection(serial: serial))
        driver.setBrightness(settings.brightness)
        let link = KeypadLink(device: device, driver: driver)
        keypads[serial] = link
        keypadOrder.append(serial)

        Task { @MainActor [weak self] in
            for await snapshot in driver.snapshots { self?.show(snapshot, from: serial) }
        }
        Task { @MainActor [weak self] in
            for await event in driver.events {
                guard let self, let overlay = self.overlay else { continue }
                overlay.handle(event)
                self.log(event)
                if case .fire(let selection, let chosenAt) = event { self.fire(selection, chosenAt: chosenAt) }
            }
        }
        Task { @MainActor [weak self] in
            for await event in driver.connectionEvents {
                self?.overlay?.handle(event)
                self?.updateConnection(event, of: serial)
            }
        }
        driver.start()
        refreshModules()
        updateKeypadStatus()
        return link
    }

    /// The overlay follows the keypad being used: another's going idle
    /// doesn't clear it.
    private func show(_ snapshot: SelectionSnapshot, from serial: String) {
        let page = snapshot.page.map { KeypadPage(tree: $0.tree, column: $0.column) }
        let turned = page != shownPages[serial]
        shownPages[serial] = page
        if !snapshot.isIdle || turned {
            activeKeypad = serial
        } else if let active = activeKeypad, active != serial {
            return
        }
        overlay?.handle(snapshot)
    }

    private func updateConnection(_ event: KeybowEvent, of serial: String) {
        guard var link = keypads[serial] else { return }
        let name = link.name
        switch event {
        case .connected:
            link.status = "port open, waiting for a reply"
        case .disconnected(let reason):
            link.status = "not connected"
            Log.info("\(name) disconnected: \(reason)")
        case .message(.hello(let version)):
            link.status = "connected"
            Log.info("\(name): HELLO, protocol \(version)")
        case .message(.pong):
            link.status = "connected"
        case .message(.deviceError(let text)):
            // Usually something else writing to the port.
            Log.error("\(name): ERR \(text)")
        case .message(.unrecognised(let text)):
            Log.error("\(name) said something unexpected: \(text)")
        case .message:
            break
        }
        let changed = keypads[serial]?.status != link.status
        keypads[serial] = link
        if changed { updateKeypadStatus() }
    }

    /// "Keybow 2040: connected" — or, with two, a line for both.
    private func updateKeypadStatus() {
        let real = keypadOrder.compactMap { keypads[$0] }.filter { $0.device != nil }
        let summary: String
        switch real.count {
        case 0: summary = "no keypad found"
        case 1: summary = real[0].status
        default: summary = real.map { "\($0.name) \($0.status)" }.joined(separator: " · ")
        }
        connectionItem.title = real.count == 1 ? "\(real[0].name): \(summary)" : "Keypads: \(summary)"
        settings.keybowStatus = summary.prefix(1).uppercased() + summary.dropFirst()
    }

    private func log(_ event: NavigatorEvent) {
        switch event {
        case .selectionChanged(let selection):
            if let selection { Log.info("selected: \(selection.pathDescription)  [\(selection.tree.rawValue)]") }
        case .invalidPress(let key):
            Log.info("ignored key \(key)")
        case .pending(let selection):
            Log.info("pending: \(selection.pathDescription)")
        case .fire(let selection, _):
            let summary = ActionSummary(selection: selection, config: config)
            var line = "FIRE: \(summary.verb) · \(summary.subject)"
            if !summary.details.isEmpty { line += " · " + summary.details.joined(separator: " · ") }
            if !summary.missing.isEmpty { line += "  [missing: \(summary.missing.joined(separator: ", "))]" }
            Log.info(line)
        case .cleared(let reason):
            Log.info("cleared (\(reason.rawValue))")
        case .page(let page):
            Log.info(page.map { "page: \($0.node.label)  [\($0.tree.rawValue) pages]" } ?? "back to the trees")
        }
    }
}

/// What the wait is for, as it changes: read when the overlay shows it.
@MainActor
private final class WaitTitle {
    var text: String
    init(_ text: String) { self.text = text }
}
