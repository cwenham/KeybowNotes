import Foundation

public enum KeybowEvent: Equatable, Sendable {
    case connected(path: String)
    case disconnected(reason: String)
    case message(DeviceMessage)
}

/// Keeps a connection to the Keybow alive: finds the device, holds the data port
/// open, sends heartbeats, and reconnects after unplugging or sleep.
///
/// Events arrive on `events`; commands go out through `send(_:)`. Everything is
/// serialised on a private queue, so it is safe to call from anywhere.
public final class KeybowConnection: @unchecked Sendable {
    public struct Timings: Sendable {
        /// How often to look for the device while disconnected, and to ping while connected.
        public var tick: TimeInterval = 1.0
        /// Ping at most this often.
        public var heartbeat: TimeInterval = 2.0
        /// Give up on a connection that has said nothing for this long.
        public var silenceTimeout: TimeInterval = 8.0

        public init() {}
    }

    private let queue = DispatchQueue(label: "KeybowConnection")
    private let timings: Timings

    private var port: SerialPort?
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var assembler = LineAssembler()
    private var lastHeard = Date.distantPast
    private var lastPinged = Date.distantPast
    private var continuation: AsyncStream<KeybowEvent>.Continuation?

    public let events: AsyncStream<KeybowEvent>

    public init(timings: Timings = Timings()) {
        self.timings = timings
        var capturedContinuation: AsyncStream<KeybowEvent>.Continuation!
        self.events = AsyncStream { capturedContinuation = $0 }
        self.continuation = capturedContinuation
    }

    public var isConnected: Bool {
        queue.sync { port != nil }
    }

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: timings.tick)
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            timer = source
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            teardown(reason: "stopped")
            continuation?.finish()
            continuation = nil
        }
    }

    public func send(_ command: HostCommand) {
        queue.async { [self] in
            guard let port else { return }
            do {
                try port.write(line: command.line)
            } catch {
                teardown(reason: "write failed: \(error)")
            }
        }
    }

    // MARK: - Private

    private func tick() {
        guard port != nil else {
            attemptConnect()
            return
        }

        // Has the device gone away from the IO registry?
        if let path = port?.path, USBSerialPorts.keybowDataPort()?.path != path {
            teardown(reason: "device disappeared")
            return
        }

        let now = Date()
        if now.timeIntervalSince(lastHeard) > timings.silenceTimeout {
            teardown(reason: "no reply for \(Int(timings.silenceTimeout))s")
            return
        }
        if now.timeIntervalSince(lastPinged) >= timings.heartbeat {
            lastPinged = now
            if let port {
                do {
                    try port.write(line: HostCommand.ping.line)
                } catch {
                    teardown(reason: "write failed: \(error)")
                }
            }
        }
    }

    private func attemptConnect() {
        guard let candidate = USBSerialPorts.keybowDataPort() else { return }
        do {
            let opened = try SerialPort(path: candidate.path)
            port = opened
            assembler = LineAssembler()
            lastHeard = Date()
            lastPinged = .distantPast

            let source = DispatchSource.makeReadSource(fileDescriptor: opened.descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.readIncoming() }
            source.resume()
            readSource = source

            continuation?.yield(.connected(path: opened.path))
            // Say hello immediately rather than waiting for the heartbeat: the
            // firmware answers with HELLO, which tells us the protocol version.
            try opened.write(line: HostCommand.ping.line)
            lastPinged = Date()
        } catch {
            continuation?.yield(.disconnected(reason: "\(error)"))
            port = nil
        }
    }

    private func readIncoming() {
        guard let port else { return }
        let data = port.readAvailable()
        guard !data.isEmpty else { return }
        lastHeard = Date()
        for line in assembler.append(data) {
            continuation?.yield(.message(DeviceMessage(line: line)))
        }
    }

    private func teardown(reason: String) {
        readSource?.cancel()
        readSource = nil
        guard port != nil else { return }
        port = nil
        continuation?.yield(.disconnected(reason: reason))
    }
}
