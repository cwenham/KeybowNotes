import Foundation

/// Sets a keypad up from nothing, or brings one up to date: CircuitPython,
/// flashed through the board's bootloader; then the firmware, copied to its
/// CIRCUITPY drive; then a restart, so boot.py turns on the data port.
public struct KeypadSetup: Sendable {
    public enum Step: Int, CaseIterable, Sendable {
        case download, bootloader, circuitPython, firmware, restart, connect

        public var title: String {
            switch self {
            case .download: return "Get CircuitPython"
            case .bootloader: return "Start its bootloader"
            case .circuitPython: return "Install CircuitPython"
            case .firmware: return "Copy the KeybowNotes firmware"
            case .restart: return "Restart it"
            case .connect: return "Connect"
            }
        }
    }

    public enum Event: Equatable, Sendable {
        case started(Step, String)
        /// Waiting on the person: pressing buttons, or replugging.
        case waiting(Step, String)
        case done(Step, String)
        case skipped(Step, String)
    }

    public struct Plan: Sendable {
        public var model: KeypadDevice.Model
        /// The board's unique ID, when it's running CircuitPython. Nil for a
        /// board in its bootloader, or about to be.
        public var serial: String?
        /// The version to install; nil keeps the one it has.
        public var circuitPython: CircuitPythonVersion?
        /// Where replaced files are kept, each setup in a folder of its own.
        public var backups: URL

        public init(model: KeypadDevice.Model, serial: String?, circuitPython: CircuitPythonVersion?, backups: URL) {
            self.model = model
            self.serial = serial
            self.circuitPython = circuitPython
            self.backups = backups
        }
    }

    public struct Outcome: Sendable {
        public var serial: String
        public var installed: FirmwarePackage.Installed
        /// Where the files it replaced were kept, when there were any.
        public var backupFolder: URL?
    }

    public let package: FirmwarePackage
    public let downloads: CircuitPythonDownloads
    /// Whether the keypad's talking: its HELLO heard on the data port.
    public let isConnected: @Sendable (String) async -> Bool
    /// Sends STOP on the keypad's data port, which whoever has it open must
    /// do: the firmware ignores Ctrl-C on its console. False if it couldn't.
    public let stopProgram: @Sendable (String) async -> Bool

    public init(package: FirmwarePackage, downloads: CircuitPythonDownloads = CircuitPythonDownloads(),
                stopProgram: @escaping @Sendable (String) async -> Bool,
                isConnected: @escaping @Sendable (String) async -> Bool) {
        self.package = package
        self.downloads = downloads
        self.stopProgram = stopProgram
        self.isConnected = isConnected
    }

    public func run(_ plan: Plan, report: @escaping @Sendable (Event) -> Void) async throws -> Outcome {
        guard let board = package.board(for: plan.model) else {
            throw ModuleError("The firmware has nothing for a \(plan.model.title)")
        }
        var serial = plan.serial

        // 1. CircuitPython, from the cache or downloaded.
        var image: URL?
        if let version = plan.circuitPython {
            report(.started(.download, "CircuitPython \(version) for the \(plan.model.title)"))
            image = try await downloads.file(board: board.circuitPythonBoard, version: version)
            report(.done(.download, "CircuitPython \(version)"))
        } else {
            report(.skipped(.download, "Keeping the CircuitPython it has"))
        }

        // 2. The bootloader: asked for at the console, or by hand.
        var bootloader: URL?
        if image != nil {
            let before = Set(KeypadDrives.bootloaders())
            if let serial, Self.board(serial) != nil {
                report(.started(.bootloader, "Restarting it in its bootloader"))
                if let drive = Self.drive(serial) { KeypadDrives.eject(drive) }
                func arrived() -> URL? { KeypadDrives.bootloaders().first { !before.contains($0) } }
                if try await restart(serial, intoBootloader: true, done: { arrived() != nil }) {
                    bootloader = arrived()
                }
            } else {
                bootloader = before.first
            }
            if bootloader == nil {
                report(.waiting(.bootloader, plan.model.bootloaderInstructions))
                bootloader = try await Self.wait(seconds: 900) { KeypadDrives.bootloaders().first }
                guard bootloader != nil else { throw ModuleError("No board started its bootloader") }
            }
            report(.done(.bootloader, "Its bootloader is waiting"))
        } else {
            report(.skipped(.bootloader, "Not needed"))
        }

        // 3. CircuitPython onto the bootloader's drive, and its own drive back.
        var drive: URL
        var bootOut: BootOut
        if let image, let bootloader, let version = plan.circuitPython {
            let others = Set(KeypadDrives.circuitPython().compactMap(\.bootOut.uid))
            var shown = -1
            try await Self.copy(image, to: bootloader) { share in
                // Every tenth: enough to see it move.
                let tenths = Int(share * 10)
                guard tenths != shown else { return }
                shown = tenths
                report(.started(.circuitPython, "Copying CircuitPython \(version): \(tenths * 10)%"))
            }
            report(.started(.circuitPython, "Waiting for CircuitPython to start"))
            let found = try await Self.wait(seconds: 120) {
                KeypadDrives.circuitPython().first { entry in
                    if let serial { return Self.same(entry.bootOut.uid, serial) }
                    return entry.bootOut.boardID == board.circuitPythonBoard && !others.contains(entry.bootOut.uid ?? "")
                }
            }
            guard let found else {
                throw ModuleError("CircuitPython didn't start", "Its drive, CIRCUITPY, didn't appear. Unplug the keypad, "
                                  + "plug it in again, and set it up again.")
            }
            (drive, bootOut) = found
            report(.done(.circuitPython, "CircuitPython \(bootOut.version?.description ?? version.description)"))
        } else {
            guard let known = serial else { throw ModuleError("Which board? It isn't running CircuitPython") }
            if Self.drive(known) == nil, let console = Self.board(known)?.consolePort {
                // Its drive was ejected: a restart brings it back.
                report(.started(.circuitPython, "Restarting it to show its drive"))
                try CircuitPythonConsole.reset(port: console)
                _ = try await Self.wait(seconds: 30) { Self.drive(known) }
            }
            guard let found = KeypadDrives.circuitPython().first(where: { Self.same($0.bootOut.uid, known) }) else {
                throw ModuleError("Its drive, CIRCUITPY, isn't showing", "Unplug the keypad and plug it in again.")
            }
            (drive, bootOut) = found
            report(.skipped(.circuitPython, "Keeping CircuitPython \(bootOut.version?.description ?? "")"))
        }
        if let id = bootOut.boardID, id != board.circuitPythonBoard {
            throw ModuleError("That board isn't a \(plan.model.title)",
                              "It says it's a \(bootOut.boardName ?? id). Choose the model it is.")
        }
        guard let uid = bootOut.uid ?? serial else { throw ModuleError("The board didn't give its unique ID") }
        serial = uid

        // 4. The firmware, keeping what it replaces.
        report(.started(.firmware, "Copying files to \(drive.lastPathComponent)"))
        let stamp = Self.stampFormat.string(from: Date())
        let folder = plan.backups.appendingPathComponent("\(plan.model.title) \(uid) \(stamp)", isDirectory: true)
        let installed = try package.install(model: plan.model, on: drive, backup: folder)
        let written = installed.written.isEmpty ? "Already up to date"
            : "\(installed.written.count) file\(installed.written.count == 1 ? "" : "s") copied"
        let kept = installed.backedUp.isEmpty ? "" : "; \(installed.backedUp.count) replaced, and backed up first"
        report(.done(.firmware, written + kept))

        // 5. A restart: boot.py only runs at power-on.
        report(.started(.restart, "Ejecting its drive and restarting it"))
        sync()
        KeypadDrives.eject(drive)
        // Copying the files restarted its program: a moment for the new one.
        if !installed.written.isEmpty { try await Task.sleep(for: .seconds(2)) }
        let before = Self.board(uid)?.registryIDs
        func restarted() -> Bool { Self.board(uid)?.registryIDs != before }
        if try await !restart(uid, intoBootloader: false, done: restarted) {
            report(.waiting(.restart, "Unplug the keypad and plug it in again."))
            _ = try await Self.wait(seconds: 900) { restarted() ? true : nil }
        }
        let keypad = try await Self.wait(seconds: 30) { USBSerialPorts.keypads().first { Self.same($0.serial, uid) } }
        guard keypad != nil else {
            throw ModuleError("It restarted without its data port", "boot.py didn't run. Unplug the keypad and plug it in again.")
        }
        report(.done(.restart, "Restarted with its data port"))

        // 6. Talking to the app.
        report(.started(.connect, "Waiting for it to say hello"))
        let hello = try await Self.wait(seconds: 20) { await isConnected(uid) ? true : nil }
        guard hello == true else {
            throw ModuleError("It's running, but hasn't said hello", "Its data port is there, but the firmware didn't answer.")
        }
        report(.done(.connect, "Connected"))
        return Outcome(serial: uid, installed: installed, backupFolder: installed.backedUp.isEmpty ? nil : folder)
    }

    // MARK: - Pieces

    /// Restarts a board — in its bootloader, or as if replugged — whichever
    /// way works: its program asked to STOP on its data port, so the
    /// console's prompt can run the restart; then, for the bootloader, the
    /// 1200-baud touch. True once `done` says it's happened.
    private func restart(_ serial: String, intoBootloader: Bool, done: () async -> Bool) async throws -> Bool {
        func happened() async throws -> Bool {
            try await Self.wait(seconds: 10) { await done() ? true : nil } == true
        }
        if USBSerialPorts.keypads().contains(where: { Self.same($0.serial, serial) }), await stopProgram(serial) {
            try await Task.sleep(for: .milliseconds(500))
        }
        // Something else holding its console — a terminal — fails this,
        // leaving it to the touch, or to the person.
        if let console = Self.board(serial)?.consolePort {
            if intoBootloader {
                try? CircuitPythonConsole.restartInBootloader(port: console)
            } else {
                try? CircuitPythonConsole.reset(port: console)
            }
            if try await happened() { return true }
        }
        if intoBootloader, let console = Self.board(serial)?.consolePort {
            CircuitPythonConsole.touch1200(port: console)
            if try await happened() { return true }
        }
        return false
    }

    private static let stampFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return format
    }()

    static func same(_ a: String?, _ b: String) -> Bool {
        a?.caseInsensitiveCompare(b) == .orderedSame
    }

    static func board(_ serial: String) -> USBSerialPorts.Board? {
        USBSerialPorts.boards().first { same($0.serial, serial) }
    }

    static func drive(_ serial: String) -> URL? {
        KeypadDrives.circuitPython().first { same($0.bootOut.uid, serial) }?.drive
    }

    /// Checks every half second until there's an answer or time's up.
    static func wait<T>(seconds: Double, _ check: () async -> T?) async throws -> T? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try Task.checkCancellation()
            if let answer = await check() { return answer }
            try await Task.sleep(for: .milliseconds(500))
        }
        return await check()
    }

    /// Writes a UF2 image to a bootloader's drive. The board restarts the
    /// moment the last block arrives, taking the drive with it, so a failure
    /// once the drive's gone is the copy having worked.
    static func copy(_ image: URL, to bootloader: URL, progress: (Double) -> Void) async throws {
        let data = try Data(contentsOf: image)
        let target = bootloader.appendingPathComponent(image.lastPathComponent)
        let descriptor = open(target.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else {
            throw ModuleError("CircuitPython couldn't be copied to the board", String(cString: strerror(errno)))
        }
        var failure: Int32 = 0
        let chunk = 64 * 1024
        var offset = 0
        while offset < data.count, failure == 0 {
            try Task.checkCancellation()
            let length = min(chunk, data.count - offset)
            let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress!.advanced(by: offset), length) }
            if written < 0 {
                if errno == EINTR { continue }
                failure = errno
            } else {
                offset += written
                progress(Double(offset) / Double(data.count))
            }
        }
        // Out to the board now, not when the cache gets round to it.
        if failure == 0, fcntl(descriptor, F_FULLFSYNC) != 0 { failure = errno }
        close(descriptor)
        if failure != 0, FileManager.default.fileExists(atPath: bootloader.path) {
            throw ModuleError("CircuitPython couldn't be copied to the board", String(cString: strerror(failure)))
        }
    }
}

extension KeypadDevice.Model {
    /// How to start the board's bootloader by hand.
    public var bootloaderInstructions: String {
        switch self {
        case .keybow2040:
            return "Hold the BOOT button on the Keybow and press its RESET button — or hold BOOT while you plug it in."
        case .rgbKeypad:
            return "Hold the BOOTSEL button on the Pico while you plug the keypad in."
        }
    }
}

/// A board that could be set up: running CircuitPython, or waiting in its
/// bootloader for it.
public struct SetupCandidate: Identifiable, Equatable, Sendable {
    /// Its unique ID, or for a bootloader its drive.
    public let id: String
    /// Nil for a board in its bootloader, which can't say what it is.
    public var model: KeypadDevice.Model?
    public var serial: String?
    public var bootOut: BootOut?
    public var drive: URL?
    /// The firmware on its drive, when that's showing.
    public var firmware: FirmwarePackage.Status?
    /// Running the firmware, with its data port.
    public var isKeypad: Bool

    public var inBootloader: Bool { serial == nil }

    /// Every board connected that could be set up, as it is now.
    public static func all(package: FirmwarePackage?) -> [SetupCandidate] {
        let drives = KeypadDrives.circuitPython()
        var found: [SetupCandidate] = []
        for board in USBSerialPorts.boards() {
            let entry = drives.first { KeypadSetup.same($0.bootOut.uid, board.serial) }
            let model = entry?.bootOut.boardID.flatMap { package?.model(forCircuitPythonBoard: $0) } ?? board.model
            found.append(SetupCandidate(
                id: board.serial, model: model, serial: board.serial, bootOut: entry?.bootOut, drive: entry?.drive,
                firmware: entry.flatMap { entry in package.map { $0.status(on: entry.drive, model: model) } },
                isKeypad: board.ports.count >= 2))
        }
        // A keypad board whose ports aren't the ones expected, by its drive.
        for entry in drives where !found.contains(where: { KeypadSetup.same(entry.bootOut.uid, $0.id) }) {
            guard let uid = entry.bootOut.uid, let model = entry.bootOut.boardID.flatMap({ package?.model(forCircuitPythonBoard: $0) })
            else { continue }
            found.append(SetupCandidate(id: uid, model: model, serial: uid, bootOut: entry.bootOut, drive: entry.drive,
                                        firmware: package?.status(on: entry.drive, model: model), isKeypad: false))
        }
        for volume in KeypadDrives.bootloaders() {
            found.append(SetupCandidate(id: volume.path, model: nil, serial: nil, bootOut: nil, drive: volume,
                                        firmware: nil, isKeypad: false))
        }
        return found
    }
}
