import Foundation

/// A CircuitPython release number: 10.3.1, or 10.4.0-beta.1.
public struct CircuitPythonVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// "beta.1", "rc.0" — nil for a release.
    public let prerelease: String?

    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-", maxSplits: 1)
        guard let numbers = parts.first else { return nil }
        let fields = numbers.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(fields.count), !fields.contains(nil) else { return nil }
        major = fields[0]!
        minor = fields.count > 1 ? fields[1]! : 0
        patch = fields.count > 2 ? fields[2]! : 0
        prerelease = parts.count > 1 ? String(parts[1]) : nil
    }

    public var isRelease: Bool { prerelease == nil }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (a: Self, b: Self) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        // A prerelease comes before its release.
        switch (a.prerelease, b.prerelease) {
        case (nil, _): return false
        case (_, nil): return true
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
        }
    }
}

/// What a board running CircuitPython says of itself in `boot_out.txt`:
///
///     Adafruit CircuitPython 8.2.10 on 2024-02-14; Raspberry Pi Pico with rp2040
///     Board ID:raspberry_pi_pico
///     UID:E66000000000CCCC
public struct BootOut: Equatable, Sendable {
    public var version: CircuitPythonVersion?
    /// "Raspberry Pi Pico with rp2040".
    public var boardName: String?
    /// "raspberry_pi_pico": the name its downloads go by.
    public var boardID: String?
    /// The board's unique ID, which is also its USB serial number.
    public var uid: String?

    public init(text: String) {
        let heading = "Adafruit CircuitPython "
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(heading) {
                let rest = line.dropFirst(heading.count)
                version = rest.split(separator: " ").first.flatMap { CircuitPythonVersion(String($0)) }
                if let semicolon = rest.firstIndex(of: ";") {
                    boardName = rest[rest.index(after: semicolon)...].trimmingCharacters(in: .whitespaces)
                }
            } else if line.hasPrefix("Board ID:") {
                boardID = line.dropFirst("Board ID:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("UID:") {
                uid = line.dropFirst("UID:".count).trimmingCharacters(in: .whitespaces)
            }
        }
    }
}

/// UF2, the format a board's bootloader takes: 512-byte blocks, each saying
/// which chip family it's for.
public enum UF2 {
    /// The RP2040, in both the Keybow 2040 and the Pico.
    public static let rp2040: UInt32 = 0xE48B_FF56

    /// Why `data` isn't a whole UF2 image for `family` — nil when it is.
    /// Checked before it's written, so a truncated download or a page of HTML
    /// never reaches a board.
    public static func problem(with data: Data, family: UInt32) -> String? {
        guard !data.isEmpty, data.count % 512 == 0 else { return "it isn't a UF2 file" }
        let blocks = data.count / 512
        return data.withUnsafeBytes { bytes -> String? in
            func word(_ block: Int, _ offset: Int) -> UInt32 {
                UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: block * 512 + offset, as: UInt32.self))
            }
            for block in 0..<blocks {
                guard word(block, 0) == 0x0A32_4655, word(block, 4) == 0x9E5D_5157, word(block, 508) == 0x0AB1_6F30 else {
                    return "it isn't a UF2 file"
                }
                // The family ID is present, and this one.
                guard word(block, 8) & 0x2000 != 0, word(block, 28) == family else {
                    return "it's for another kind of board"
                }
                guard word(block, 20) == UInt32(block), word(block, 24) == UInt32(blocks) else {
                    return "it's incomplete"
                }
            }
            return nil
        }
    }
}

/// CircuitPython's releases, and the files they're published as.
public enum CircuitPythonReleases {
    public struct Release: Decodable, Sendable {
        public let tag: String
        public let prerelease: Bool
        public let draft: Bool

        public init(tag: String, prerelease: Bool = false, draft: Bool = false) {
            self.tag = tag
            self.prerelease = prerelease
            self.draft = draft
        }

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name", prerelease, draft
        }
    }

    /// GitHub's list of releases, newest first.
    public static let releasesURL = URL(string: "https://api.github.com/repos/adafruit/circuitpython/releases?per_page=50")!

    /// The releases — no betas — whose major version is in `majors`, newest first.
    public static func candidates(_ releases: [Release], majors: ClosedRange<Int>) -> [CircuitPythonVersion] {
        let versions = releases.filter { !$0.prerelease && !$0.draft }.compactMap { CircuitPythonVersion($0.tag) }
        return Set(versions.filter { $0.isRelease && majors.contains($0.major) }).sorted(by: >)
    }

    public static func fileName(board: String, version: CircuitPythonVersion, language: String = "en_US") -> String {
        "adafruit-circuitpython-\(board)-\(language)-\(version).uf2"
    }

    public static func downloadURL(board: String, version: CircuitPythonVersion, language: String = "en_US") -> URL {
        URL(string: "https://downloads.circuitpython.org/bin/\(board)/\(language)/")!
            .appendingPathComponent(fileName(board: board, version: version, language: language))
    }

    /// The version a cached file holds, from its name.
    public static func version(ofFile name: String, board: String, language: String = "en_US") -> CircuitPythonVersion? {
        let prefix = "adafruit-circuitpython-\(board)-\(language)-"
        guard name.hasPrefix(prefix), name.hasSuffix(".uf2") else { return nil }
        return CircuitPythonVersion(String(name.dropFirst(prefix.count).dropLast(".uf2".count)))
    }
}

/// The drives keypads show: CIRCUITPY, while CircuitPython runs, and RPI-RP2,
/// the RP2040's bootloader, waiting for a UF2 file.
public enum KeypadDrives {
    /// Every volume mounted, but the startup disk.
    public static func volumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.volumeIsRootFileSystemKey]))?.volumeIsRootFileSystem != true }
    }

    /// Boards waiting in their bootloader.
    public static func bootloaders(in volumes: [URL] = volumes()) -> [URL] {
        volumes.filter(isBootloader)
    }

    public static func isBootloader(_ volume: URL) -> Bool {
        guard let info = try? String(contentsOf: volume.appendingPathComponent("INFO_UF2.TXT"), encoding: .utf8) else {
            return false
        }
        return info.contains("Board-ID: RPI-RP2")
    }

    /// Boards running CircuitPython, with what each says of itself.
    public static func circuitPython(in volumes: [URL] = volumes()) -> [(drive: URL, bootOut: BootOut)] {
        volumes.compactMap { volume in
            guard let text = try? String(contentsOf: volume.appendingPathComponent("boot_out.txt"), encoding: .utf8),
                  text.hasPrefix("Adafruit CircuitPython") else { return nil }
            return (volume, BootOut(text: text))
        }
    }

    /// Unmounts and ejects a drive, which writes out everything still
    /// waiting to be. False when it couldn't be — it's in use.
    @discardableResult
    public static func eject(_ volume: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["eject", volume.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// CircuitPython's console: the REPL, where a line of Python can restart a
/// board without anyone pressing its buttons. The KeybowNotes firmware
/// ignores Ctrl-C there, so it's asked to STOP on its data port first.
public enum CircuitPythonConsole {
    /// The "1200-baud touch": opening the console at 1200 baud and dropping
    /// DTR restarts a board in its bootloader, whatever its program's doing.
    public static func touch1200(port path: String) {
        let descriptor = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var settings = termios()
        guard tcgetattr(descriptor, &settings) == 0 else { return }
        cfmakeraw(&settings)
        cfsetispeed(&settings, speed_t(B1200))
        cfsetospeed(&settings, speed_t(B1200))
        guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else { return }
        var dtr: Int32 = TIOCM_DTR
        _ = ioctl(descriptor, TIOCMBIS, &dtr)
        Thread.sleep(forTimeInterval: 0.1)
        _ = ioctl(descriptor, TIOCMBIC, &dtr)
        Thread.sleep(forTimeInterval: 0.1)
    }

    /// Restarts the board as if it were unplugged, so boot.py runs.
    public static func reset(port: String) throws {
        try run("import microcontroller; microcontroller.reset()", port: port)
    }

    /// Restarts the board in its bootloader, ready for a UF2 file.
    public static func restartInBootloader(port: String) throws {
        try run("import microcontroller; microcontroller.on_next_reset(microcontroller.RunMode.BOOTLOADER); "
                + "microcontroller.reset()", port: port)
    }

    /// Stops what's running — Ctrl-C — and runs `statement` at the prompt.
    /// The board restarts before answering, so nothing is waited for.
    public static func run(_ statement: String, port path: String) throws {
        let port = try SerialPort(path: path)
        func drain(after seconds: Double) {
            Thread.sleep(forTimeInterval: seconds)
            while !port.readAvailable().isEmpty {}
        }
        try port.write(Data([0x03, 0x03]))
        drain(after: 0.8)
        // "Press any key to enter the REPL."
        try port.write(Data("\r\n".utf8))
        drain(after: 0.4)
        // The port goes as the board restarts, which can fail the write's end.
        try? port.write(Data((statement + "\r\n").utf8))
        drain(after: 0.3)
    }
}
