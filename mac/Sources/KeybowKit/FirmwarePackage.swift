import Foundation

/// The keypad's side of KeybowNotes, as it's kept with the app: `code.py`,
/// `boot.py`, `keymap.py` and the libraries each board needs, with a
/// manifest saying which files go to which board and which CircuitPython
/// versions they run on. Installing it is copying those files to the board's
/// CIRCUITPY drive.
public struct FirmwarePackage: Sendable {
    public struct Manifest: Decodable, Sendable {
        public struct CircuitPython: Decodable, Sendable {
            public let minimumMajor: Int
            public let maximumMajor: Int
            /// Versions it's been run on.
            public let tested: [String]
        }

        public struct Board: Decodable, Sendable {
            /// A `KeypadDevice.Model`: keybow2040, rgbkeypad.
            public let model: String
            /// CircuitPython's name for the board, which its downloads go by.
            public let circuitPythonBoard: String
            /// Files for this board alone; a path ending in "/" is a folder.
            public let files: [String]
        }

        public let circuitPython: CircuitPython
        /// Files every board gets.
        public let files: [String]
        public let boards: [Board]
    }

    public let root: URL
    public let manifest: Manifest

    public init(root: URL) throws {
        self.root = root
        let data = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        manifest = try JSONDecoder().decode(Manifest.self, from: data)
    }

    /// The package beside the app — in its Resources, or named by
    /// KEYBOW_FIRMWARE — else the repository's `firmware` folder, for a
    /// development build run from the package.
    public static func locate() -> FirmwarePackage? {
        if let path = ProcessInfo.processInfo.environment["KEYBOW_FIRMWARE"], !path.isEmpty {
            return try? FirmwarePackage(root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        if let bundled = Bundle.main.url(forResource: "Firmware", withExtension: nil),
           let package = try? FirmwarePackage(root: bundled) {
            return package
        }
        var folder = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = folder.appendingPathComponent("firmware")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                return try? FirmwarePackage(root: candidate)
            }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    /// The CircuitPython versions it runs on, by major version.
    public var majors: ClosedRange<Int> {
        manifest.circuitPython.minimumMajor...max(manifest.circuitPython.minimumMajor, manifest.circuitPython.maximumMajor)
    }

    public func board(for model: KeypadDevice.Model) -> Manifest.Board? {
        manifest.boards.first { $0.model == model.rawValue }
    }

    /// The model a board running CircuitPython is, from the ID it reports.
    public func model(forCircuitPythonBoard id: String) -> KeypadDevice.Model? {
        manifest.boards.first { $0.circuitPythonBoard == id }.flatMap { KeypadDevice.Model(rawValue: $0.model) }
    }

    /// Every file a model's board gets, as paths on its drive, in order.
    public func files(for model: KeypadDevice.Model) -> [String] {
        let entries = manifest.files + (board(for: model)?.files ?? [])
        var paths: [String] = []
        for entry in entries {
            if entry.hasSuffix("/") {
                let folder = root.appendingPathComponent(entry)
                let found = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                           options: [.skipsHiddenFiles])
                var inFolder: [String] = []
                while let url = found?.nextObject() as? URL {
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                    let relative = url.path.dropFirst(folder.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    inFolder.append(entry + relative)
                }
                paths += inFolder.sorted()
            } else {
                paths.append(entry)
            }
        }
        return paths
    }

    /// How a drive's files compare with the package's.
    public enum Status: Equatable, Sendable {
        /// Every file as the package has it.
        case current
        /// KeybowNotes firmware, but not this package's.
        case older
        /// Something else, or nothing.
        case other
    }

    public func status(on drive: URL, model: KeypadDevice.Model) -> Status {
        let differing = files(for: model).filter { path in
            (try? Data(contentsOf: drive.appendingPathComponent(path))) != (try? Data(contentsOf: root.appendingPathComponent(path)))
        }
        if differing.isEmpty { return .current }
        let code = (try? String(contentsOf: drive.appendingPathComponent("code.py"), encoding: .utf8)) ?? ""
        return code.contains("HELLO keybow") ? .older : .other
    }

    /// Files a board runs in place of code.py, set aside so code.py runs.
    public static let runsFirst = ["code.txt"]

    public struct Installed: Equatable, Sendable {
        /// Files written: new, or changed.
        public var written: [String] = []
        /// Files there were before, kept in the backup folder.
        public var backedUp: [String] = []
    }

    /// Copies the model's files to `drive`. Any file it replaces with
    /// something different — and code.txt, which would run instead — is
    /// copied to `backup` first, keeping its path. Files already as the
    /// package has them aren't touched.
    ///
    /// Written plainly, without the extended attributes a Finder copy brings:
    /// those become `._` files on the board's drive.
    public func install(model: KeypadDevice.Model, on drive: URL, backup: URL) throws -> Installed {
        let manager = FileManager.default
        var installed = Installed()
        var changes: [(path: String, data: Data, old: Data?)] = []
        for path in files(for: model) {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            let old = try? Data(contentsOf: drive.appendingPathComponent(path))
            if old != data { changes.append((path, data, old)) }
        }

        // Room for it: a Pico's drive holds about a megabyte.
        let needed = changes.reduce(0) { $0 + $1.data.count - ($1.old?.count ?? 0) }
        if let free = try? drive.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           needed > free - 4096 {
            throw ModuleError("The keypad's drive is too full",
                              "It needs \(needed / 1024) KB more and has \(free / 1024) KB free.")
        }

        func keep(_ path: String, _ data: Data) throws {
            let copy = backup.appendingPathComponent(path)
            try manager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: copy)
            installed.backedUp.append(path)
        }
        for change in changes {
            if let old = change.old { try keep(change.path, old) }
        }
        for path in Self.runsFirst {
            let url = drive.appendingPathComponent(path)
            if let data = try? Data(contentsOf: url) {
                try keep(path, data)
                try manager.removeItem(at: url)
            }
        }

        // Libraries first and code.py last: the board restarts code.py as
        // files change, and it should find what it imports.
        func order(_ path: String) -> Int { path.hasPrefix("lib/") ? 0 : path == "code.py" ? 2 : 1 }
        for change in changes.sorted(by: { order($0.path) < order($1.path) }) {
            let target = drive.appendingPathComponent(change.path)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try change.data.write(to: target)
            installed.written.append(change.path)
        }
        return installed
    }
}
