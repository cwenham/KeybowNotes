import Foundation

/// A helper program — `osascript`, `shortcuts`, `log`, `lsof`, `diskutil` —
/// run to the end. Its output and errors are read as they come, so a program
/// with a lot to say can't stall on a full pipe, and it's stopped once
/// `timeout` has passed.
public enum Subprocess {
    public struct Result: Sendable {
        public let status: Int32
        public let output: Data
        public let errors: Data
        /// Stopped for taking longer than it was given.
        public let timedOut: Bool

        public var text: String { String(decoding: output, as: UTF8.self) }
        public var errorText: String { String(decoding: errors, as: UTF8.self) }
        public var succeeded: Bool { status == 0 && !timedOut }
    }

    /// Runs `path`, blocking this thread until it's done. Throws only when
    /// it can't be started.
    public static func runAndWait(_ path: String, _ arguments: [String], input: String? = nil,
                                  timeout: TimeInterval? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        try process.run()

        let timedOut = Flag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
        }
        if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog) }

        let others = DispatchGroup()
        let said = Box()
        DispatchQueue.global().async(group: others) {
            said.data = errors.fileHandleForReading.readDataToEndOfFile()
        }
        if let stdin, let input {
            DispatchQueue.global().async(group: others) {
                try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
            }
        }
        let written = output.fileHandleForReading.readDataToEndOfFile()
        others.wait()
        process.waitUntilExit()
        watchdog.cancel()
        return Result(status: process.terminationStatus, output: written, errors: said.data, timedOut: timedOut.isSet)
    }

    /// Runs `path` until it's done, waiting off the caller's thread. Throws
    /// only when it can't be started.
    public static func run(_ path: String, _ arguments: [String], input: String? = nil,
                           timeout: TimeInterval? = nil) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Swift.Result { try runAndWait(path, arguments, input: input, timeout: timeout) })
            }
        }
    }

    /// Set from the watchdog, read once the program's done.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// Filled on another thread, read after waiting for it.
    private final class Box: @unchecked Sendable {
        var data = Data()
    }
}

/// `osascript`, and what its complaints mean.
public enum Osascript {
    public static let path = "/usr/bin/osascript"

    /// Runs `source` with each value an argument to its `on run argv` — never
    /// pasted into the script, where it could change what it does.
    public static func run(_ source: String, _ arguments: [String],
                           timeout: TimeInterval? = nil) async throws -> Subprocess.Result {
        try await Subprocess.run(path, ["-"] + arguments, input: source, timeout: timeout)
    }

    public static func runAndWait(_ source: String, _ arguments: [String],
                                  timeout: TimeInterval? = nil) throws -> Subprocess.Result {
        try Subprocess.runAndWait(path, ["-"] + arguments, input: source, timeout: timeout)
    }

    /// Error -1743: macOS hasn't let this app control the other one.
    public static func isNotAllowed(_ complaint: String) -> Bool {
        complaint.contains("-1743") || complaint.lowercased().contains("not authorized to send apple events")
    }

    /// Where a person lets it.
    public static let allowIt = "Allow it in System Settings → Privacy & Security → Automation."

    /// "…: execution error: Notes got an error: Can't get folder "X". (-1728)"
    /// → the part a person reads: `Can't get folder "X".`
    public static func reason(_ complaint: String) -> String {
        var reason = complaint.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = reason.range(of: "got an error: ") { reason = String(reason[range.upperBound...]) }
        else if let range = reason.range(of: "execution error: ") { reason = String(reason[range.upperBound...]) }
        if let open = reason.range(of: " (", options: .backwards), reason.hasSuffix(")") {
            reason = String(reason[..<open.lowerBound])
        }
        return reason
    }
}

/// The `shortcuts` command, for the Shortcuts app.
public enum ShortcutsApp {
    public static let path = "/usr/bin/shortcuts"

    /// Every shortcut, by name, in order; none when they can't be listed.
    /// Quick enough — a few milliseconds — to ask afresh each time.
    public static func names() async -> [String] {
        guard let result = try? await Subprocess.run(path, ["list"], timeout: 30) else { return [] }
        let names = result.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Set(names).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
