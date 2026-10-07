import AppKit
import KeybowKit
import SwiftUI

/// Sets a keypad up: choose the board, then CircuitPython and the firmware
/// go on it, step by step. See `KeypadSetup`.
@MainActor
@Observable
final class KeypadSetupModel {
    /// The choice for a board that isn't plugged in yet, or is running
    /// something other than CircuitPython.
    static let newBoard = "new"

    enum StepState: Equatable {
        case pending
        case running(String)
        case waiting(String)
        case done(String)
        case skipped(String)
        case failed(String)
    }

    enum Phase {
        case choosing
        case running
        case finished(KeypadSetup.Outcome, KeypadDevice.Model)
        case failed(String, String?)
    }

    /// The newest CircuitPython for a model's board, as far as it's known.
    enum Latest: Equatable {
        case checking
        case found(CircuitPythonVersion, note: String?)
        case unavailable(String)
    }

    let package: FirmwarePackage?
    private let backups: URL
    private let isConnected: @Sendable (String) async -> Bool
    private let stopProgram: @Sendable (String) async -> Bool

    var candidates: [SetupCandidate] = []
    var selection: String?
    /// The model, for a board that can't say.
    var newModel: KeypadDevice.Model = .keybow2040
    var latest: [KeypadDevice.Model: Latest] = [:]
    var installCircuitPython = true
    var phase: Phase = .choosing
    var steps: [KeypadSetup.Step: StepState] = [:]
    private var task: Task<Void, Never>?
    private var poll: Timer?
    /// Finding out why a keypad hasn't turned up: listening from the start,
    /// shown when nothing's found soon, a wait goes on, or setting up fails.
    let troubleshooter: TroubleshooterModel
    private(set) var troubleshooterShown = false
    private var opened = Date()
    /// Since when a step has waited on the person.
    private var waitingSince: Date?
    /// When setting up began: it restarts the keypad, on purpose.
    private var runStarted: Date?
    /// The board the CircuitPython choice was last set for, so a new choice
    /// gets a fresh default.
    private var defaultsFor: String?

    init(package: FirmwarePackage?, backups: URL, stopProgram: @escaping @Sendable (String) async -> Bool,
         isConnected: @escaping @Sendable (String) async -> Bool, connectedKeypads: @escaping () -> Set<String>) {
        self.package = package
        self.backups = backups
        self.stopProgram = stopProgram
        self.isConnected = isConnected
        troubleshooter = TroubleshooterModel(sought: [], since: Date().addingTimeInterval(-1800), package: package,
                                             inSetup: true, connected: connectedKeypads)
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var selected: SetupCandidate? {
        candidates.first { $0.id == selection }
    }

    /// The model being set up: the board's own, or the one chosen for it.
    var model: KeypadDevice.Model {
        selected?.model ?? newModel
    }

    /// No CircuitPython it could keep: in its bootloader, not plugged in, or
    /// running a version the firmware doesn't.
    var mustInstallCircuitPython: Bool {
        guard let selected, let version = selected.bootOut?.version, let package else { return true }
        return selected.inBootloader || !package.majors.contains(version.major)
    }

    var newestVersion: CircuitPythonVersion? {
        if case .found(let version, _) = latest[model] { return version }
        return nil
    }

    var canStart: Bool {
        guard package != nil, !isRunning, selection != nil else { return false }
        if selection != Self.newBoard, selected == nil { return false }
        // Whether to install CircuitPython isn't settled until the newest is known.
        switch latest[model] {
        case nil, .checking?: return false
        default: break
        }
        if selected?.serial != nil, selected?.drive == nil, selected?.isKeypad == false, !installCircuitPython { return false }
        return !(installCircuitPython || mustInstallCircuitPython) || newestVersion != nil
    }

    // MARK: Looking

    func start() {
        opened = Date()
        troubleshooter.listen()
        refresh()
        poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.considerTroubleshooting()
            }
        }
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        task?.cancel()
        troubleshooter.stop()
    }

    /// Brings the troubleshooter in when a keypad hasn't turned up: none
    /// found a few seconds after opening, or one said not to be listed, or
    /// a wait on the person going on too long.
    private func considerTroubleshooting() {
        guard !troubleshooterShown else { return }
        switch phase {
        case .choosing:
            let none = candidates.isEmpty && Date().timeIntervalSince(opened) >= 4
            if none || selection == Self.newBoard && Date().timeIntervalSince(opened) >= 4 { showTroubleshooter() }
        case .running:
            if let waitingSince, Date().timeIntervalSince(waitingSince) >= 15 { showTroubleshooter() }
        case .failed:
            showTroubleshooter()
        case .finished:
            break
        }
    }

    func showTroubleshooter() {
        if let serial = selected?.serial {
            troubleshooter.sought = [SoughtKeypad(name: model.title, model: model, serial: serial)]
        } else {
            troubleshooter.sought = []
        }
        troubleshooter.restarts = runStarted.map { [DateInterval(start: $0, end: Date().addingTimeInterval(3600))] } ?? []
        troubleshooter.allowsDeviceActions = !isRunning
        troubleshooterShown = true
        troubleshooter.start()
    }

    /// What's plugged in, read off the main thread: it reads the drives.
    func refresh() {
        guard !isRunning else { return }
        let package = package
        let demo = TroubleshooterDemo.scenario != nil
        Task.detached {
            // Trying the troubleshooter out: nothing's plugged in.
            let found = demo ? [] : SetupCandidate.all(package: package)
            await MainActor.run { [weak self] in self?.update(found) }
        }
    }

    private func update(_ found: [SetupCandidate]) {
        guard !isRunning else { return }
        candidates = found
        // For trying the window out: KEYBOW_SETUP_SELECT=new, or a board's ID.
        if selection == nil, let wanted = ProcessInfo.processInfo.environment["KEYBOW_SETUP_SELECT"] {
            selection = wanted
        }
        if selection == nil || (selection != Self.newBoard && selected == nil) {
            // A board waiting for CircuitPython, else one without the
            // firmware, else the first.
            selection = (found.first { $0.inBootloader } ?? found.first { $0.firmware != .current } ?? found.first)?.id
                ?? Self.newBoard
        }
        chose()
        // Development builds only: KEYBOW_SETUP_START=1 presses Set Up once it can be.
        if Bundle.main.bundleIdentifier == nil, ProcessInfo.processInfo.environment["KEYBOW_SETUP_START"] == "1",
           !startedForTesting, canStart {
            startedForTesting = true
            run()
        }
    }

    private var startedForTesting = false

    /// Called as the choice changes: the newest CircuitPython for its model,
    /// and whether to install it.
    func chose() {
        if latest[model] == nil { checkLatest(for: model) }
        let key = "\(selection ?? "")/\(model.rawValue)"
        guard key != defaultsFor || mustInstallCircuitPython else { return }
        defaultsFor = key
        if mustInstallCircuitPython {
            installCircuitPython = true
        } else if let has = selected?.bootOut?.version, let newest = newestVersion {
            installCircuitPython = has < newest
        } else {
            installCircuitPython = false
        }
    }

    private func checkLatest(for model: KeypadDevice.Model) {
        guard let package, let board = package.board(for: model) else { return }
        latest[model] = .checking
        let downloads = CircuitPythonDownloads()
        Task {
            let result: Latest
            do {
                result = .found(try await downloads.newest(board: board.circuitPythonBoard, majors: package.majors), note: nil)
            } catch {
                if let cached = downloads.newestCached(board: board.circuitPythonBoard, majors: package.majors) {
                    result = .found(cached.version, note: "Couldn't reach the downloads, so it's one downloaded before.")
                } else {
                    result = .unavailable((error as? ModuleError)?.message ?? error.localizedDescription)
                }
            }
            latest[model] = result
            defaultsFor = nil
            chose()
        }
    }

    // MARK: Setting up

    func run() {
        guard canStart, let package else { return }
        let plan = KeypadSetup.Plan(
            model: model, serial: selected?.serial,
            circuitPython: installCircuitPython || mustInstallCircuitPython ? newestVersion : nil, backups: backups)
        let model = model
        steps = Dictionary(uniqueKeysWithValues: KeypadSetup.Step.allCases.map { ($0, StepState.pending) })
        phase = .running
        runStarted = Date()
        waitingSince = nil
        troubleshooterShown = false
        let setup = KeypadSetup(package: package, stopProgram: stopProgram, isConnected: isConnected)
        task = Task { [weak self] in
            let (events, sink) = AsyncStream.makeStream(of: KeypadSetup.Event.self)
            let listener = Task { @MainActor [weak self] in
                for await event in events { self?.apply(event) }
            }
            let result: Result<KeypadSetup.Outcome, Error>
            do {
                result = .success(try await setup.run(plan) { sink.yield($0) })
            } catch {
                result = .failure(error)
            }
            sink.finish()
            await listener.value
            self?.finish(result, model: model)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func again() {
        phase = .choosing
        troubleshooterShown = false
        opened = Date()
        steps = [:]
        defaultsFor = nil
        refresh()
    }

    private func apply(_ event: KeypadSetup.Event) {
        if case .waiting = event {
            if waitingSince == nil { waitingSince = Date() }
        } else {
            waitingSince = nil
        }
        switch event {
        case .started(let step, let text): steps[step] = .running(text)
        case .waiting(let step, let text): steps[step] = .waiting(text)
        case .done(let step, let text): steps[step] = .done(text)
        case .skipped(let step, let text): steps[step] = .skipped(text)
        }
    }

    private func finish(_ result: Result<KeypadSetup.Outcome, Error>, model: KeypadDevice.Model) {
        task = nil
        switch result {
        case .success(let outcome):
            phase = .finished(outcome, model)
            troubleshooterShown = false
            Log.info("set up a \(model.title): \(outcome.serial)")
        case .failure(let error):
            let (message, detail): (String, String?) = error is CancellationError ? ("Stopped", nil)
                : (error as? ModuleError).map { ($0.message, $0.detail) } ?? (error.localizedDescription, nil)
            for (step, state) in steps {
                switch state {
                case .running, .waiting: steps[step] = .failed(message)
                default: break
                }
            }
            phase = .failed(message, detail)
            Log.error("keypad setup: \(message)")
            if !(error is CancellationError) { showTroubleshooter() }
        }
    }
}

struct KeypadSetupView: View {
    @Bindable var model: KeypadSetupModel
    let openEditor: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.4x3.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set Up a Keypad").font(.title2.weight(.semibold))
                    Text("Puts CircuitPython and the KeybowNotes firmware on a Keybow 2040 or an RGB Keypad.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.package == nil {
                Label("The firmware isn't with this copy of KeybowNotes, so a keypad can't be set up from it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch model.phase {
                        case .choosing: chooser
                        default: progress
                        }
                    }
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.troubleshooterShown) { _, shown in
                    guard shown else { return }
                    withAnimation { scroller.scrollTo("troubleshooter", anchor: .top) }
                }
            }
            footer
        }
        .padding(20)
        .frame(width: 600, height: model.troubleshooterShown ? 700 : 560)
    }

    /// Why a keypad hasn't turned up, and what to do.
    @ViewBuilder
    private var troubleshooting: some View {
        if model.troubleshooterShown {
            GroupBox {
                TroubleshooterPanel(model: model.troubleshooter)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(troubleshootingTitle, systemImage: "stethoscope").font(.headline)
            }
            .id("troubleshooter")
        }
    }

    private var troubleshootingTitle: String {
        switch model.phase {
        case .choosing: return "Don’t see your keypad?"
        case .running: return "Still waiting? Here’s what the Mac sees"
        default: return "What went wrong"
        }
    }

    // MARK: Choosing

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(spacing: 2) {
                    ForEach(model.candidates) { candidate in row(candidate) }
                    newRow
                }
                .padding(4)
            } label: {
                Text("Keypad").font(.headline)
            }
            troubleshooting
            if model.selected == nil || model.selected?.inBootloader == true {
                modelChoice
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    circuitPython
                    Divider()
                    firmware
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("macOS may ask whether KeybowNotes can use files on a removable volume — the keypad's drive. "
                 + "Allow it. While the keypad restarts, macOS may also say a disk wasn't ejected properly; that's expected.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: model.selection) { model.chose() }
        .onChange(of: model.newModel) { model.chose() }
    }

    private func row(_ candidate: SetupCandidate) -> some View {
        choice(id: candidate.id, title: title(candidate), detail: detail(candidate),
               symbol: candidate.inBootloader ? "arrow.down.circle" : "square.grid.4x3.fill")
    }

    private var newRow: some View {
        choice(id: KeypadSetupModel.newBoard, title: "A keypad that isn't listed",
               detail: "Not plugged in yet, or running something other than CircuitPython", symbol: "plus.circle")
    }

    private func choice(id: String, title: String, detail: String, symbol: String) -> some View {
        let chosen = model.selection == id
        return Button {
            model.selection = id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(chosen ? Color.accentColor : .secondary)
                Image(systemName: symbol).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(chosen ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func title(_ candidate: SetupCandidate) -> String {
        if candidate.inBootloader { return "A board waiting for CircuitPython" }
        return candidate.model?.title ?? "Keypad"
    }

    private func detail(_ candidate: SetupCandidate) -> String {
        if candidate.inBootloader { return "In its bootloader, as \(candidate.drive?.lastPathComponent ?? "RPI-RP2")" }
        var parts: [String] = []
        if let version = candidate.bootOut?.version { parts.append("CircuitPython \(version)") }
        switch candidate.firmware {
        case .current?: parts.append("firmware up to date")
        case .older?: parts.append("older firmware")
        case .other?: parts.append("no KeybowNotes firmware")
        case nil: parts.append("its drive isn't showing")
        }
        if candidate.isKeypad { parts.append("connected") }
        if let serial = candidate.serial { parts.append("ID \(serial)") }
        return parts.joined(separator: " · ")
    }

    private var modelChoice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Model", selection: $model.newModel) {
                ForEach(KeypadDevice.Model.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Text(model.selected?.inBootloader == true
                 ? "A board in its bootloader can't say what it is: choose its model. It gets that model's CircuitPython."
                 : model.newModel.bootloaderInstructions + " Setup waits for it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var circuitPython: some View {
        let has = model.selected?.bootOut?.version
        switch model.latest[model.model] {
        case .found(let version, let note)?:
            VStack(alignment: .leading, spacing: 3) {
                Toggle(isOn: Binding(get: { model.installCircuitPython || model.mustInstallCircuitPython },
                                     set: { model.installCircuitPython = $0 })) {
                    Text("Install CircuitPython \(version.description)")
                }
                .disabled(model.mustInstallCircuitPython)
                Group {
                    if let has, model.mustInstallCircuitPython {
                        Text("It has \(has.description), which the firmware doesn't run on.")
                    } else if let has {
                        Text(has < version ? "The newest the firmware supports. It has \(has.description)."
                             : "It has \(has.description) already: no need, unless you'd like it installed again.")
                    } else {
                        Text("The newest the firmware supports, from circuitpython.org.")
                    }
                    if let note { Text(note) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
            }
        case .unavailable(let problem)?:
            Label(has == nil || model.mustInstallCircuitPython
                  ? "Can't find CircuitPython to install: \(problem)"
                  : "Keeping CircuitPython \(has!.description): the newest can't be found — \(problem)",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        default:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Finding the newest CircuitPython…").foregroundStyle(.secondary)
            }
        }
    }

    private var firmware: some View {
        let count = model.package?.files(for: model.model).count ?? 0
        return VStack(alignment: .leading, spacing: 3) {
            Label("Copy the KeybowNotes firmware", systemImage: "checkmark")
            Text("code.py, boot.py, keymap.py and the libraries a \(model.model.title) needs — \(count) files. "
                 + "Any it replaces are kept first, in Keypad Backups in KeybowNotes' folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }

    // MARK: Progress

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(KeypadSetup.Step.allCases, id: \.self) { step in stepRow(step) }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            switch model.phase {
            case .finished(let outcome, let keypad):
                VStack(alignment: .leading, spacing: 8) {
                    Label("The \(keypad.title) is set up, and connected.", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text("It uses the Default trees until it has trees of its own: in the tree editor, click + beside Default.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open the Tree Editor", action: openEditor)
                        if let folder = outcome.backupFolder {
                            Button("Show the Backup") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        }
                    }
                }
            case .failed(let message, let detail):
                VStack(alignment: .leading, spacing: 4) {
                    Label(message, systemImage: "exclamationmark.octagon.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    if let detail {
                        Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            default:
                EmptyView()
            }
            troubleshooting
        }
    }

    private func stepRow(_ step: KeypadSetup.Step) -> some View {
        let state = model.steps[step] ?? .pending
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                switch state {
                case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                case .running: ProgressView().controlSize(.small)
                case .waiting: Image(systemName: "hand.point.up.left.fill").foregroundStyle(.orange)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).foregroundStyle(state == .pending ? .secondary : .primary)
                switch state {
                case .running(let text), .done(let text), .skipped(let text), .failed(let text):
                    Text(text).font(.caption).foregroundStyle(.secondary)
                case .waiting(let text):
                    Text(text).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                case .pending:
                    EmptyView()
                }
            }
        }
    }

    // MARK: Buttons

    private var footer: some View {
        HStack {
            Spacer()
            switch model.phase {
            case .choosing:
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Set Up", action: model.run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
            case .running:
                Button("Stop", action: model.cancel).keyboardShortcut(.cancelAction)
            case .finished:
                Button("Set Up Another", action: model.again)
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            case .failed:
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                Button("Try Again", action: model.again).keyboardShortcut(.defaultAction)
            }
        }
    }
}

@MainActor
final class KeypadSetupWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: KeypadSetupModel?
    private let backups: URL
    private let stopProgram: @Sendable (String) async -> Bool
    private let isConnected: @Sendable (String) async -> Bool
    private let connectedKeypads: () -> Set<String>
    private let openEditor: () -> Void

    init(backups: URL, stopProgram: @escaping @Sendable (String) async -> Bool,
         isConnected: @escaping @Sendable (String) async -> Bool, connectedKeypads: @escaping () -> Set<String>,
         openEditor: @escaping () -> Void) {
        self.backups = backups
        self.stopProgram = stopProgram
        self.isConnected = isConnected
        self.connectedKeypads = connectedKeypads
        self.openEditor = openEditor
    }

    func show() {
        if window == nil {
            let model = KeypadSetupModel(package: FirmwarePackage.locate(), backups: backups, stopProgram: stopProgram,
                                         isConnected: isConnected, connectedKeypads: connectedKeypads)
            let view = KeypadSetupView(model: model, openEditor: { [weak self] in self?.openEditor() },
                                       close: { [weak self] in self?.window?.performClose(nil) })
            let hosting = NSHostingController(rootView: view)
            // Taller when the troubleshooter comes in.
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Set Up a Keypad"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
            self.model = model
            model.start()
            WindowSnapshots.keep(window, as: "setup")
        }
        window?.bringToFront()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, model.isRunning else { return true }
        let alert = NSAlert()
        alert.messageText = "Stop setting up the keypad?"
        alert.informativeText = "It can be set up again afterwards, from where it's left."
        alert.addButton(withTitle: "Keep Going")
        alert.addButton(withTitle: "Stop")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        model?.stop()
        model = nil
        window = nil
    }
}
