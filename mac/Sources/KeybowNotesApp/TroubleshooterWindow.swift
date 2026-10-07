import AppKit
import KeybowKit
import SwiftUI

/// Finds out why a keypad isn't working, on its own: it looks at what's
/// plugged in and what macOS's USB log says happened, watches while the
/// keypad's plugged in, and asks what its keys are doing — then says what
/// to do. See `Troubleshooter` for the rules. Shown in its own window, and
/// inside Set Up when a keypad doesn't turn up.
@MainActor
@Observable
final class TroubleshooterModel {
    enum Watch: Equatable {
        case idle
        /// Waiting for it to be unplugged.
        case unplug(String)
        /// Watching it plugged in, until then.
        case plugIn(String, until: Date)
    }

    /// What's looked for; empty for any keypad.
    var sought: [SoughtKeypad]
    private(set) var findings: [Finding] = []
    private(set) var facts: TroubleshootingFacts?
    private(set) var checking = false
    private(set) var watch: Watch = .idle
    /// What the person says its keys are doing.
    var keys: KeyLights? { didSet { if keys != oldValue { diagnose() } } }
    /// Something being done that takes a moment: "Reading its console…".
    private(set) var busy: String?
    /// Something to say about what was just done.
    private(set) var notice: String?
    /// The USB log as it happened, while this was open.
    private(set) var heard: [USBLogEvent] = []
    private(set) var watchStarted: Date?
    /// Set Up: no button to open it, and nothing that would get in its way
    /// while it's running.
    let inSetup: Bool
    var allowsDeviceActions = true
    /// When keypads were restarted on purpose.
    var restarts: [DateInterval] = [] { didSet { diagnose() } }
    /// How far back the USB log is read.
    let since: Date

    @ObservationIgnored var openSetup: (() -> Void)?
    @ObservationIgnored private let package: FirmwarePackage?
    @ObservationIgnored private let connected: () -> Set<String>
    @ObservationIgnored private let watcher = USBLogWatcher()
    @ObservationIgnored private var base: TroubleshootingFacts?
    @ObservationIgnored private var logged: [USBLogEvent] = []
    @ObservationIgnored private var console: [String: ConsoleReading] = [:]
    @ObservationIgnored private var watched: DateInterval?
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var watching: Task<Void, Never>?
    @ObservationIgnored private var recheck: Task<Void, Never>?
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var generation = 0

    init(sought: [SoughtKeypad], since: Date, package: FirmwarePackage?, inSetup: Bool = false,
         connected: @escaping () -> Set<String>) {
        self.sought = sought
        self.since = since
        self.package = package
        self.inSetup = inSetup
        self.connected = connected
    }

    /// Listens to the USB log from now on, so a plug-in that goes wrong is
    /// caught even before anyone asks.
    func listen() {
        guard listening == nil, TroubleshooterDemo.scenario == nil else { return }
        let events = watcher.start()
        listening = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.heard.append(event)
                self.diagnose()
                self.scheduleRecheck()
            }
        }
    }

    /// Listens, looks, and keeps looking every few seconds.
    func start() {
        listen()
        check()
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.checking, self.watch == .idle, self.busy == nil else { return }
                self.check(readLog: false)
            }
        }
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        watcher.stop()
        listening?.cancel()
        listening = nil
        watching?.cancel()
        recheck?.cancel()
    }

    /// Looks at everything again; `readLog` reads the USB log's history too,
    /// which takes a few seconds.
    func check(readLog: Bool = true) {
        generation += 1
        let generation = generation
        checking = true
        let sought = sought, since = since, package = package
        let connected = Set(connected().map { $0.uppercased() })
        if let scenario = TroubleshooterDemo.scenario {
            base = TroubleshooterDemo.facts(scenario, sought: sought)
            logged = base?.events ?? []
            checking = false
            diagnose()
            return
        }
        Task {
            let facts = await TroubleshootingFacts.gather(sought: sought, since: since, connected: connected,
                                                         package: package, readLog: readLog)
            guard generation == self.generation else { return }
            if readLog { logged = facts.events }
            base = facts
            checking = false
            diagnose()
        }
    }

    private func scheduleRecheck() {
        recheck?.cancel()
        recheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, !self.checking else { return }
            self.check(readLog: false)
        }
    }

    private func diagnose() {
        guard var facts = base else { return }
        var events = logged
        for event in heard where !events.contains(event) { events.append(event) }
        facts.events = events.sorted { $0.date < $1.date }
        facts.keys = keys
        facts.console = console
        facts.watchedPlugIn = watched ?? facts.watchedPlugIn
        facts.restarts = restarts
        self.facts = facts
        findings = Troubleshooter.diagnose(facts)
    }

    /// Whether to ask about the keys: something found depends on it.
    var asksAboutKeys: Bool {
        findings.contains { $0.actions.contains(.askKeys) } || keys != nil
    }

    /// Whether watching a plug-in is what to do next.
    var suggestsWatching: Bool {
        findings.contains { $0.actions.contains(.watchPlugIn) }
    }

    // MARK: Doing

    func perform(_ action: Finding.Action) {
        switch action {
        case .setUp: openSetup?()
        case .watchPlugIn: watchPlugIn()
        case .askKeys: break
        case .readConsole(let serial): readConsole(serial)
        case .restart(let serial): restart(serial)
        }
    }

    func title(of action: Finding.Action) -> String? {
        switch action {
        case .setUp: return inSetup ? nil : "Set Up…"
        case .watchPlugIn, .askKeys: return nil
        case .readConsole: return allowsDeviceActions ? "Read What It Says" : nil
        case .restart: return allowsDeviceActions ? "Restart It" : nil
        }
    }

    /// Watches while the person unplugs the keypad and plugs it back in:
    /// whatever reaches the Mac, or doesn't, says what's wrong.
    func watchPlugIn() {
        watching?.cancel()
        notice = nil
        let name = sought.count == 1 ? "the \(sought[0].name)" : "the keypad"
        watching = Task { [weak self] in
            guard let self else { return }
            if self.isPluggedIn() {
                self.watch = .unplug(name)
                let end = Date().addingTimeInterval(60)
                while Date() < end, self.isPluggedIn(), self.watch == .unplug(name) {
                    try? await Task.sleep(for: .milliseconds(500))
                    if Task.isCancelled { return }
                }
            }
            let start = Date()
            let end = start.addingTimeInterval(30)
            self.watchStarted = start
            self.watch = .plugIn(name, until: end)
            while Date() < end {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                if self.isPluggedIn() {
                    // A moment for its ports and drive to follow.
                    try? await Task.sleep(for: .seconds(3))
                    break
                }
                if self.heard.contains(where: { $0.date >= start && $0.kind == .gaveUp }) { break }
            }
            self.watched = DateInterval(start: start, end: Date())
            self.watch = .idle
            self.check()
        }
    }

    /// Unplugged already, as far as the person's concerned.
    func skipUnplug() {
        if case .unplug(let name) = watch { watch = .plugIn(name, until: Date().addingTimeInterval(30)) }
    }

    func cancelWatch() {
        watching?.cancel()
        watch = .idle
        watchStarted = nil
    }

    /// What's being looked for, on USB now: a keypad, or a board that could
    /// be one.
    private func isPluggedIn() -> Bool {
        let devices = USBInventory.devices()
        if sought.isEmpty { return devices.contains { $0.identity.isRP2040 } }
        return sought.contains { keypad in
            devices.contains { device in
                if let serial = keypad.serial { return Troubleshooter.same(device.serial, serial) }
                if let model = keypad.model { return device.identity == .keypad(model) }
                return device.identity.isRP2040
            }
        }
    }

    func readConsole(_ serial: String) {
        guard let port = USBSerialPorts.boards().first(where: { Troubleshooter.same($0.serial, serial) })?.consolePort else {
            notice = "Its console isn’t there any more."
            return
        }
        busy = "Starting its program again, and listening…"
        notice = nil
        Task {
            let result = await Task.detached { () -> Result<String, Error> in
                Result { try CircuitPythonConsole.listen(port: port) }
            }.value
            busy = nil
            switch result {
            case .success(let text):
                console[serial.uppercased()] = ConsoleReading(text: text)
                if text.isEmpty { notice = "It said nothing." }
            case .failure(let error):
                notice = "Its console couldn’t be opened: \(error)"
            }
            check(readLog: false)
        }
    }

    func restart(_ serial: String) {
        guard let port = USBSerialPorts.boards().first(where: { Troubleshooter.same($0.serial, serial) })?.consolePort else {
            notice = "Its console isn’t there any more."
            return
        }
        busy = "Restarting it…"
        notice = nil
        let start = Date()
        Task {
            let failure = await Task.detached { () -> String? in
                do { try CircuitPythonConsole.reset(port: port); return nil } catch { return "\(error)" }
            }.value
            try? await Task.sleep(for: .seconds(5))
            restarts.append(DateInterval(start: start, end: Date()))
            busy = nil
            notice = failure.map { "It couldn’t be restarted from here: \($0). Unplug it and plug it back in." }
            check()
        }
    }

    func copyReport() {
        guard let facts else { return }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Troubleshooter.report(facts, findings: findings, version: version), forType: .string)
        notice = "The report’s on the clipboard: paste it into an email or a message to whoever’s helping."
    }
}

/// Made-up keypads in made-up trouble, for trying the troubleshooter out
/// and taking pictures of it without anyone's own: development builds only,
/// with KEYBOW_TROUBLESHOOT_DEMO=hub, nodata, dataport or setup.
enum TroubleshooterDemo {
    static var scenario: String? {
        guard Bundle.main.bundleIdentifier == nil else { return nil }
        return ProcessInfo.processInfo.environment["KEYBOW_TROUBLESHOOT_DEMO"]
    }

    static let keybow = SoughtKeypad(name: "Keybow 2040", model: .keybow2040, serial: "E6600000000000AA",
                                     lastSeen: Date().addingTimeInterval(-5400), lastLocation: USBLocation(0x1441_0000),
                                     lastPlace: "port 1 of the hub “USB2.0 HUB”")

    static func facts(_ scenario: String, sought: [SoughtKeypad]) -> TroubleshootingFacts {
        let now = Date()
        let hub = USBDevice(name: "USB2.0 HUB", vendorID: 0x1A40, productID: 0x0101, location: USBLocation(0x1440_0000),
                            isHub: true)
        func failures(_ port: String, _ ago: TimeInterval) -> [USBLogEvent] {
            (0..<8).compactMap { attempt in
                USBLog.event(message: "AppleUSB20HubPort@\(port): AppleUSB20HubPort::resetAndCreateDevice: failed to address device, disabling port",
                             date: now.addingTimeInterval(-ago + Double(attempt) * 2))
            } + [USBLog.event(message: "AppleUSB20HubPort@\(port): AppleUSBHostPort::disconnect: persistent enumeration failures",
                              date: now.addingTimeInterval(-ago + 15))!]
        }
        var facts = TroubleshootingFacts(now: now, sought: sought, devices: [hub], eventsSince: now.addingTimeInterval(-7200),
                                         connected: [], supportedMajors: 8...10)
        switch scenario {
        case "hub":
            facts.events = failures("14410000", 1500) + failures("14420000", 300)
        case "nodata":
            facts.watchedPlugIn = DateInterval(start: now.addingTimeInterval(-35), end: now.addingTimeInterval(-5))
        case "dataport":
            let serial = keybow.serial!
            facts.devices.append(USBDevice(name: "Keybow 2040", vendorID: 0x16D0, productID: 0x08C6, serial: serial,
                                           location: USBLocation(0x1450_0000)))
            facts.boards = [USBSerialPorts.Board(serial: serial, model: .keybow2040, ports: ["/dev/cu.usbmodem101"],
                                                 registryIDs: [1])]
            facts.drives = [CircuitPythonDrive(drive: URL(fileURLWithPath: "/Volumes/CIRCUITPY"),
                                               bootOut: BootOut(text: "Adafruit CircuitPython 10.3.1 on 2026-09-14; "
                                                                + "Pimoroni Keybow 2040 with rp2040\nUID:\(serial)"),
                                               firmware: .current, model: .keybow2040)]
        default:
            facts.events = failures("14420000", 40)
        }
        return facts
    }
}

// MARK: - Views

/// The findings, what to do about them, and the questions that narrow them.
struct TroubleshooterPanel: View {
    @Bindable var model: TroubleshooterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.watch != .idle { watching }
            if model.findings.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking at the USB ports, and what macOS’s USB log says happened…").foregroundStyle(.secondary)
                }
            }
            ForEach(model.findings) { finding in
                FindingRow(finding: finding, model: model)
            }
            if model.asksAboutKeys, model.watch == .idle { keysQuestion }
            if let busy = model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                }
            }
            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
    }

    private var buttons: some View {
        HStack {
            if model.suggestsWatching {
                Button("Watch While I Plug It In", action: model.watchPlugIn)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.watch != .idle)
            } else {
                Button("Watch While I Plug It In", action: model.watchPlugIn)
                    .disabled(model.watch != .idle)
            }
            Button("Check Again") { model.check() }
                .disabled(model.checking || model.watch != .idle)
            Spacer()
            Button("Copy Report", action: model.copyReport)
                .disabled(model.facts == nil)
                .help("Everything found, as text, for someone helping you")
        }
    }

    @ViewBuilder
    private var watching: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                switch model.watch {
                case .unplug(let name):
                    Label("Unplug \(name) now.", systemImage: "cable.connector.slash")
                        .font(.headline)
                    Text("Then plug it back in when this says so.").foregroundStyle(.secondary)
                    HStack {
                        Button("It’s Unplugged", action: model.skipUnplug)
                        Button("Stop", action: model.cancelWatch)
                    }
                case .plugIn(let name, let until):
                    Label("Now plug \(name) back in.", systemImage: "cable.connector")
                        .font(.headline)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Watching for \(max(0, Int(until.timeIntervalSince(context.date).rounded()))) more seconds…")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    let devices = model.facts?.devices ?? []
                    ForEach(Array(model.heard.filter { $0.date >= (model.watchStarted ?? .distantFuture) }.enumerated()),
                            id: \.offset) { _, event in
                        Text("• " + event.describe(devices: devices)).font(.callout)
                    }
                    Button("Stop", action: model.cancelWatch)
                case .idle:
                    EmptyView()
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var keysQuestion: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What are its keys doing?").font(.headline)
            Text("The firmware lights them differently for each kind of trouble.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(KeyLights.allCases, id: \.self) { lights in
                Button {
                    model.keys = model.keys == lights ? nil : lights
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.keys == lights ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(model.keys == lights ? Color.accentColor : .secondary)
                        Swatch(lights: lights)
                        Text(lights.title)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A little picture of a key lit as `lights` says.
private struct Swatch: View {
    let lights: KeyLights
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.4)))
            .frame(width: 16, height: 16)
            .opacity(lights == .pulsingRed || lights == .flashingPurple ? (bright ? 1 : 0.25) : 1)
            .onAppear {
                let period = lights == .pulsingRed ? 1.5 : 0.4
                withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) { bright = true }
            }
    }

    private var fill: AnyShapeStyle {
        switch lights {
        case .dark: return AnyShapeStyle(Color.black.opacity(0.8))
        case .pulsingRed: return AnyShapeStyle(Color.red)
        case .steadyBlue: return AnyShapeStyle(Color.blue)
        case .flashingPurple: return AnyShapeStyle(Color.purple)
        case .treeColours:
            return AnyShapeStyle(LinearGradient(colors: [.orange, .green, .cyan], startPoint: .topLeading,
                                                endPoint: .bottomTrailing))
        }
    }
}

private struct FindingRow: View {
    let finding: Finding
    let model: TroubleshooterModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.title).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if !finding.detail.isEmpty {
                    Text(finding.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !finding.fixes.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(finding.fixes.enumerated()), id: \.offset) { number, fix in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(number + 1).").monospacedDigit().foregroundStyle(.secondary)
                                Text(fix).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                let buttons = finding.actions.compactMap { action in model.title(of: action).map { (action, $0) } }
                if !buttons.isEmpty {
                    HStack {
                        ForEach(buttons, id: \.1) { action, title in
                            Button(title) { model.perform(action) }
                                .disabled(model.busy != nil || model.watch != .idle)
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch finding.severity {
        case .problem: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .note: Image(systemName: "info.circle.fill").foregroundStyle(.blue)
        case .good: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

/// The troubleshooter in a window of its own, from Settings or the menu.
struct TroubleshooterView: View {
    @Bindable var model: TroubleshooterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find a Keypad").font(.title2.weight(.semibold))
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ScrollView {
                TroubleshooterPanel(model: model)
                    .padding(.trailing, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 640)
    }

    private var subtitle: String {
        let names = model.sought.map(\.name)
        let looking = names.isEmpty ? "Looking for any keypad" : "Looking for the " + names.joined(separator: " and the ")
        return looking + ": what’s plugged in, and what macOS saw happen on its USB ports."
    }
}

@MainActor
final class TroubleshooterWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: TroubleshooterModel?
    private let connected: () -> Set<String>
    private let openSetup: () -> Void

    init(connected: @escaping () -> Set<String>, openSetup: @escaping () -> Void) {
        self.connected = connected
        self.openSetup = openSetup
    }

    /// Opens on these keypads; open already, it looks for them instead.
    func show(sought: [SoughtKeypad]) {
        if let model {
            model.sought = sought
            model.check()
        } else {
            // Since the oldest last sighting, within reason: macOS keeps a
            // day or so of the USB log anyway.
            let earliest = sought.compactMap(\.lastSeen).min() ?? Date().addingTimeInterval(-3 * 3600)
            let since = max(earliest.addingTimeInterval(-60), Date().addingTimeInterval(-24 * 3600))
            let model = TroubleshooterModel(sought: sought, since: since, package: FirmwarePackage.locate(),
                                            connected: connected)
            model.openSetup = openSetup
            let window = NSWindow(contentViewController: NSHostingController(rootView: TroubleshooterView(model: model)))
            window.title = "Find a Keypad"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 620, height: 640))
            window.center()
            self.window = window
            self.model = model
            model.start()
            WindowSnapshots.keep(window, as: "troubleshooter")
        }
        window?.bringToFront()
    }

    func windowWillClose(_ notification: Notification) {
        model?.stop()
        model = nil
        window = nil
    }
}
