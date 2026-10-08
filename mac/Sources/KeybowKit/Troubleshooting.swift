import Foundation

extension KeypadDevice.Model: Codable {}

/// A keypad this Mac has worked with, remembered so it can be looked for
/// once it's gone: where it was, and when.
public struct KnownKeypad: Codable, Equatable, Sendable, Identifiable {
    public var serial: String
    public var model: KeypadDevice.Model
    public var lastSeen: Date
    public var lastLocation: UInt32?
    /// Where that was, in words, since a hub may be gone by the time it's asked.
    public var lastPlace: String?

    public var id: String { serial }

    public init(serial: String, model: KeypadDevice.Model, lastSeen: Date, lastLocation: UInt32? = nil,
                lastPlace: String? = nil) {
        self.serial = serial
        self.model = model
        self.lastSeen = lastSeen
        self.lastLocation = lastLocation
        self.lastPlace = lastPlace
    }
}

/// The keypads this Mac has known, kept with the app's settings.
public enum KnownKeypads {
    public static let key = "knownKeypads"

    public static func load(_ defaults: UserDefaults = .standard) -> [KnownKeypad] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([KnownKeypad].self, from: data)) ?? []
    }

    public static func save(_ keypads: [KnownKeypad], _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(keypads) { defaults.set(data, forKey: key) }
    }

    /// The list with what's plugged in now noted: when each was seen, and
    /// where.
    public static func record(_ present: [KeypadDevice], devices: [USBDevice], into known: [KnownKeypad],
                              now: Date = Date()) -> [KnownKeypad] {
        var known = known
        for keypad in present {
            let device = devices.first { Troubleshooter.same($0.serial, keypad.serial) }
            var entry = known.first { Troubleshooter.same($0.serial, keypad.serial) }
                ?? KnownKeypad(serial: keypad.serial, model: keypad.model, lastSeen: now)
            entry.model = keypad.model
            entry.lastSeen = now
            if let device {
                entry.lastLocation = device.location.id
                entry.lastPlace = USBInventory.place(device.location, devices: devices)
            }
            if let index = known.firstIndex(where: { Troubleshooter.same($0.serial, keypad.serial) }) {
                known[index] = entry
            } else {
                known.append(entry)
            }
        }
        return known
    }
}

/// A keypad being looked for: one this Mac knows, one the tree names, or —
/// with neither serial nor model — any keypad at all.
public struct SoughtKeypad: Equatable, Sendable {
    public var name: String
    public var model: KeypadDevice.Model?
    public var serial: String?
    public var lastSeen: Date?
    public var lastLocation: USBLocation?
    public var lastPlace: String?

    public init(name: String, model: KeypadDevice.Model? = nil, serial: String? = nil, lastSeen: Date? = nil,
                lastLocation: USBLocation? = nil, lastPlace: String? = nil) {
        self.name = name
        self.model = model
        self.serial = serial
        self.lastSeen = lastSeen
        self.lastLocation = lastLocation
        self.lastPlace = lastPlace
    }

    public init(_ known: KnownKeypad, name: String? = nil) {
        self.init(name: name ?? known.model.title, model: known.model, serial: known.serial, lastSeen: known.lastSeen,
                  lastLocation: known.lastLocation.map(USBLocation.init), lastPlace: known.lastPlace)
    }

    /// Every keypad worth looking for: those this Mac has known, and those
    /// the tree's keypad sections name.
    public static func all(known: [KnownKeypad], config: KeybowConfig?) -> [SoughtKeypad] {
        let sections = config?.keypads ?? []
        var sought = known.map { keypad in
            SoughtKeypad(keypad, name: sections.first { Troubleshooter.same($0.id, keypad.serial) }?.name)
        }
        for section in sections {
            if let id = section.id {
                if !known.contains(where: { Troubleshooter.same(id, $0.serial) }) {
                    sought.append(SoughtKeypad(name: section.name, model: section.model, serial: id))
                }
            } else if let model = section.model, !known.contains(where: { $0.model == model }),
                      !sought.contains(where: { $0.model == model }) {
                sought.append(SoughtKeypad(name: section.name, model: model))
            }
        }
        return sought
    }

    public static let any = SoughtKeypad(name: "A keypad")

    public var isAny: Bool { serial == nil && model == nil }
}

/// What a keypad's keys are doing, which the person can see and the Mac
/// can't: the firmware lights them differently for each kind of trouble.
public enum KeyLights: String, CaseIterable, Sendable {
    /// No power — or a board in its bootloader.
    case dark
    /// The firmware's running, and nothing's talking to it.
    case pulsingRed
    /// The firmware's running, but its data port is off: boot.py didn't run.
    case steadyBlue
    /// The firmware keeps crashing and starting again.
    case flashingPurple
    /// Lit as the tree has them: all's well.
    case treeColours

    public var title: String {
        switch self {
        case .dark: return "All dark"
        case .pulsingRed: return "Slowly pulsing red"
        case .steadyBlue: return "Steady blue"
        case .flashingPurple: return "Flashing purple every few seconds"
        case .treeColours: return "Lit in the tree’s colours"
        }
    }

    /// Lit at all: power's reaching it.
    public var hasPower: Bool { self != .dark }
}

/// What a keypad said on its console when its program was started again.
public struct ConsoleReading: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// The firmware's loop is running.
        case running
        /// CircuitPython's safe mode, and why.
        case safeMode(String)
        /// The program stopped with an error: its last line, and where.
        case crashed(String, place: String?)
        /// The firmware's running without its data port.
        case noDataPort
        /// The program ended, without an error.
        case ended
        case unknown
    }

    public var state: State
    public var text: String

    public init(text: String) {
        self.text = text
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let start = lines.firstIndex(where: { $0.contains("safe mode because") }) {
            let reason = lines[(start + 1)...].prefix { !$0.isEmpty && !$0.hasPrefix("Press") }
                .joined(separator: " ")
            state = .safeMode(reason)
        } else if text.contains("Traceback (most recent call last)") || text.contains("KeybowNotes crashed:") {
            let error = lines.last { line in
                let name = line.prefix { $0.isLetter || $0 == "." }
                return name.hasSuffix("Error") || name.hasSuffix("Exception") || name.hasSuffix("Interrupt")
            }
            let place = lines.last { $0.hasPrefix("File \"") }
            state = .crashed(error ?? "an error", place: place)
        } else if text.contains("usb_cdc.data is not available") {
            state = .noDataPort
        } else if text.contains("KeybowNotes: ignored Ctrl-C") {
            state = .running
        } else if text.contains("Code done running") {
            state = .ended
        } else {
            state = .unknown
        }
    }
}

extension CircuitPythonConsole {
    /// Starts the board's program again and says what it printed: Ctrl-C
    /// stops it, if it's stopped by that, and Ctrl-D runs it from the start.
    /// The KeybowNotes firmware ignores Ctrl-C while it's running well, and
    /// says so, which is an answer too.
    public static func listen(port path: String, seconds: Double = 6) throws -> String {
        let port = try SerialPort(path: path)
        var heard = Data()
        func gather(for seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                let chunk = port.readAvailable()
                if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.05) } else { heard.append(chunk) }
            }
        }
        try port.write(Data([0x03, 0x03]))
        gather(for: 1)
        try? port.write(Data([0x04]))
        gather(for: seconds)
        return String(decoding: heard, as: UTF8.self)
    }
}

/// Another program with a port open.
public struct PortUser: Equatable, Sendable {
    public var pid: Int32
    public var name: String

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }

    /// Who else has `path` open, by `lsof`; empty when no one has, or it
    /// can't say.
    public static func of(_ path: String) -> [PortUser] {
        guard let result = try? Subprocess.runAndWait("/usr/sbin/lsof", ["-F", "pc", "--", path], timeout: 30) else { return [] }
        var users: [PortUser] = []
        var pid: Int32?
        for line in result.text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("c"), let current = pid, current != getpid() {
                users.append(PortUser(pid: current, name: String(line.dropFirst())))
            }
        }
        return users
    }
}

/// A keypad's drive, while it's running CircuitPython.
public struct CircuitPythonDrive: Equatable, Sendable {
    public var drive: URL
    public var bootOut: BootOut
    /// The KeybowNotes firmware on it, compared with this app's.
    public var firmware: FirmwarePackage.Status?
    /// The model its board makes it, when it's a keypad's.
    public var model: KeypadDevice.Model?

    public init(drive: URL, bootOut: BootOut, firmware: FirmwarePackage.Status? = nil, model: KeypadDevice.Model? = nil) {
        self.drive = drive
        self.bootOut = bootOut
        self.firmware = firmware
        self.model = model
    }
}

/// Everything known about the keypads, the ports, and what's happened on
/// them: what the diagnosis is drawn from.
public struct TroubleshootingFacts: Sendable {
    public var now: Date
    public var sought: [SoughtKeypad]
    public var devices: [USBDevice]
    public var boards: [USBSerialPorts.Board]
    public var drives: [CircuitPythonDrive]
    public var bootloaderDrives: [URL]
    /// What the USB log said, oldest first.
    public var events: [USBLogEvent]
    /// How far back the log was read.
    public var eventsSince: Date
    /// The keypads the app is talking to, by unique ID; nil when there's no
    /// app to ask.
    public var connected: Set<String>?
    /// Others with a keypad's port open, by port.
    public var portUsers: [String: [PortUser]]
    public var keys: KeyLights?
    /// What keypads said on their consoles, by unique ID.
    public var console: [String: ConsoleReading]
    /// While the person unplugged it and plugged it in, watched.
    public var watchedPlugIn: DateInterval?
    /// When keypads were restarted on purpose — by Set Up — so their going
    /// and coming back isn't taken for a loose cable.
    public var restarts: [DateInterval] = []
    public var isAppleSilicon: Bool
    public var supportedMajors: ClosedRange<Int>?

    public init(now: Date = Date(), sought: [SoughtKeypad] = [], devices: [USBDevice] = [],
                boards: [USBSerialPorts.Board] = [], drives: [CircuitPythonDrive] = [], bootloaderDrives: [URL] = [],
                events: [USBLogEvent] = [], eventsSince: Date? = nil, connected: Set<String>? = nil,
                portUsers: [String: [PortUser]] = [:], keys: KeyLights? = nil, console: [String: ConsoleReading] = [:],
                watchedPlugIn: DateInterval? = nil, isAppleSilicon: Bool = false,
                supportedMajors: ClosedRange<Int>? = nil) {
        self.now = now
        self.sought = sought
        self.devices = devices
        self.boards = boards
        self.drives = drives
        self.bootloaderDrives = bootloaderDrives
        self.events = events
        self.eventsSince = eventsSince ?? now.addingTimeInterval(-3600)
        self.connected = connected
        self.portUsers = portUsers
        self.keys = keys
        self.console = console
        self.watchedPlugIn = watchedPlugIn
        self.isAppleSilicon = isAppleSilicon
        self.supportedMajors = supportedMajors
    }

    /// Looks at everything now: what's plugged in, its drives and ports, and
    /// the USB log since `since`. Reads drives and runs programs, so it's
    /// done off the main thread.
    public static func gather(sought: [SoughtKeypad], since: Date, connected: Set<String>?,
                              package: FirmwarePackage?, readLog: Bool = true) async -> TroubleshootingFacts {
        let events = readLog ? await USBLog.history(since: since) : []
        return await Task.detached {
            let boards = USBSerialPorts.boards()
            let volumes = KeypadDrives.volumes()
            let drives = KeypadDrives.circuitPython(in: volumes).map { entry -> CircuitPythonDrive in
                let model = entry.bootOut.boardID.flatMap { package?.model(forCircuitPythonBoard: $0) }
                return CircuitPythonDrive(drive: entry.drive, bootOut: entry.bootOut,
                                          firmware: model.flatMap { model in package?.status(on: entry.drive, model: model) },
                                          model: model)
            }
            var users: [String: [PortUser]] = [:]
            for board in boards where !(connected?.contains(board.serial.uppercased()) ?? false) {
                for port in board.ports {
                    let found = PortUser.of(port)
                    if !found.isEmpty { users[port] = found }
                }
            }
            var arm: Int32 = 0
            var size = MemoryLayout<Int32>.size
            let isAppleSilicon = sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0 && arm == 1
            return TroubleshootingFacts(
                sought: sought, devices: USBInventory.devices(), boards: boards, drives: drives,
                bootloaderDrives: KeypadDrives.bootloaders(in: volumes), events: events, eventsSince: since,
                connected: connected, portUsers: users, isAppleSilicon: isAppleSilicon,
                supportedMajors: package?.majors)
        }.value
    }
}

/// One thing found: what's wrong, or right, and what to do about it.
public struct Finding: Identifiable, Equatable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        case good, note, warning, problem

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// Something the app can do from here.
    public enum Action: Equatable, Sendable {
        /// Open Set Up, to install CircuitPython or the firmware.
        case setUp
        /// Watch while the person unplugs it and plugs it back in.
        case watchPlugIn
        /// Ask what its keys are doing.
        case askKeys
        /// Start its program again, and read what it says.
        case readConsole(serial: String)
        /// Restart it, as if it were unplugged, from its console.
        case restart(serial: String)
    }

    public var id: String
    public var severity: Severity
    public var title: String
    public var detail: String
    /// What to try, in order.
    public var fixes: [String]
    public var actions: [Action]

    public init(id: String, severity: Severity, title: String, detail: String = "", fixes: [String] = [],
                actions: [Action] = []) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.fixes = fixes
        self.actions = actions
    }
}
