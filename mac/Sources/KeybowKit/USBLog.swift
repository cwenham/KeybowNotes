import Foundation

/// Something macOS's USB system said about a port, from the unified log:
///
///     HS06@14500000: AppleUSBHostPort::enumerateDeviceComplete_block_invoke: enumerated 0x16d0/08c6/0100 (Keybow 2040 / 58) at 12 Mbps
///     AppleUSB20HubPort@14420000: AppleUSB20HubPort::resetAndCreateDevice: failed to address device, disabling port
///     AppleUSB20HubPort@14420000: AppleUSBHostPort::disconnect: persistent enumeration failures
///
/// The kernel says this much to anyone, without an admin's password, which
/// is what makes it worth reading: it sees a plug go in even when nothing
/// comes of it.
public struct USBLogEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A device arrived and was set up.
        case arrived(vendor: Int, product: Int, name: String, speed: String)
        /// A device went: unplugged, or its connection lost.
        case left(vendor: Int, product: Int, name: String, reason: String)
        /// Something's plugged in, but couldn't be given an address: the Mac
        /// can't talk to it.
        case couldNotAddress
        /// After failing enough times, the port's switched off.
        case gaveUp
        /// The port was switched off for drawing too much power.
        case overcurrent
    }

    public let date: Date
    public let location: USBLocation
    public let kind: Kind

    public init(date: Date, location: USBLocation, kind: Kind) {
        self.date = date
        self.location = location
        self.kind = kind
    }
}

public enum USBLog {
    /// The messages worth reading. Narrow, so a day's history comes back in
    /// seconds.
    static let predicate = #"subsystem == "com.apple.usb" AND (eventMessage CONTAINS "AppleUSBHostPort::" "#
        + #"OR eventMessage CONTAINS "HubPort::" OR eventMessage CONTAINS[c] "overcurrent" "#
        + #"OR eventMessage CONTAINS[c] "over-current")"#

    private static let line = try! NSRegularExpression(pattern: #"^\S+@([0-9a-fA-F]{8}): \w+::\w+: (.*)$"#)
    private static let arrived = try! NSRegularExpression(
        pattern: #"enumerated 0x([0-9a-fA-F]{4})/([0-9a-fA-F]{4})/[0-9a-fA-F]{4} \((.*) / \d+\) at (.+)$"#)
    private static let left = try! NSRegularExpression(
        pattern: #"destroying 0x([0-9a-fA-F]{4})/([0-9a-fA-F]{4})/[0-9a-fA-F]{4} \((.*)\): (.+)$"#)

    /// One log message, read; nil for one that says nothing useful here.
    public static func event(message: String, date: Date) -> USBLogEvent? {
        guard let parts = match(line, message), parts.count == 2, let location = USBLocation(hex: parts[0]) else {
            return nil
        }
        let text = parts[1]
        let kind: USBLogEvent.Kind
        if let parts = match(arrived, text), let vendor = Int(parts[0], radix: 16), let product = Int(parts[1], radix: 16) {
            kind = .arrived(vendor: vendor, product: product, name: parts[2], speed: parts[3])
        } else if let parts = match(left, text), let vendor = Int(parts[0], radix: 16),
                  let product = Int(parts[1], radix: 16) {
            kind = .left(vendor: vendor, product: product, name: parts[2], reason: parts[3])
        } else if text.contains("persistent enumeration failures") {
            kind = .gaveUp
        } else if text.contains("failed to address device") {
            // "failed to create device" comes with it: one attempt, counted once.
            kind = .couldNotAddress
        } else if text.range(of: "overcurrent", options: .caseInsensitive) != nil
                    || text.range(of: "over-current", options: .caseInsensitive) != nil {
            kind = .overcurrent
        } else {
            return nil
        }
        return USBLogEvent(date: date, location: location, kind: kind)
    }

    /// A line of `log show --style ndjson`, read.
    public static func event(json line: String) -> USBLogEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["eventMessage"] as? String,
              let stamp = object["timestamp"] as? String, let date = timestamp.date(from: stamp) else { return nil }
        return event(message: message, date: date)
    }

    /// What the log has said since `start`. macOS keeps these for a day or
    /// so — less on a busy Mac. Empty, rather than an error, when the log
    /// can't be read.
    public static func history(since start: Date, timeout: TimeInterval = 60) async -> [USBLogEvent] {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let arguments = ["show", "--style", "ndjson", "--start", format.string(from: start), "--predicate", predicate]
        // Cut short, it's what was read in the time.
        guard let result = try? await Subprocess.run("/usr/bin/log", arguments, timeout: timeout) else { return [] }
        return result.text.split(whereSeparator: \.isNewline).compactMap { event(json: String($0)) }
    }

    static let timestamp: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return format
    }()

    private static func match(_ expression: NSRegularExpression, _ text: String) -> [String]? {
        let whole = text as NSString
        guard let result = expression.firstMatch(in: text, range: NSRange(location: 0, length: whole.length)) else {
            return nil
        }
        return (1..<result.numberOfRanges).map {
            result.range(at: $0).location == NSNotFound ? "" : whole.substring(with: result.range(at: $0))
        }
    }
}

/// The USB log as it happens: `log stream`, read line by line, for as long
/// as it's watched.
public final class USBLogWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var continuation: AsyncStream<USBLogEvent>.Continuation?

    public init() {}

    deinit { stop() }

    /// Starts watching; each event as it's logged. A second call gives a
    /// fresh stream and ends the first.
    public func start() -> AsyncStream<USBLogEvent> {
        stop()
        let (events, continuation) = AsyncStream.makeStream(of: USBLogEvent.self)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--predicate", USBLog.predicate]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let reading = output.fileHandleForReading
        Task.detached {
            do {
                for try await line in reading.bytes.lines {
                    if let event = USBLog.event(json: line) { continuation.yield(event) }
                }
            } catch {}
            continuation.finish()
        }
        process.terminationHandler = { _ in continuation.finish() }
        do {
            try process.run()
        } catch {
            continuation.finish()
            return events
        }
        lock.lock()
        self.process = process
        self.continuation = continuation
        lock.unlock()
        return events
    }

    public func stop() {
        lock.lock()
        let process = process
        let continuation = continuation
        self.process = nil
        self.continuation = nil
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
        continuation?.finish()
    }
}

extension USBLogEvent {
    /// What happened, in words, for watching as it happens.
    public func describe(devices: [USBDevice]) -> String {
        let place = USBInventory.place(location, devices: devices)
        switch kind {
        case .arrived(_, _, let name, _): return "“\(name)” arrived on \(place)"
        case .left(_, _, let name, _): return "“\(name)” left \(place)"
        case .couldNotAddress: return "Something’s plugged into \(place), but macOS couldn’t set it up"
        case .gaveUp: return "macOS gave up on \(place), and switched it off"
        case .overcurrent: return "\(place.capitalizedFirst) was switched off for drawing too much power"
        }
    }
}
