import Foundation

/// Joins the device to the navigator: feeds key events in, pushes LED state out,
/// and publishes what the user is choosing. The app and the CLI both use this.
public final class SelectionDriver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SelectionDriver")
    private let connection: KeybowConnection
    private let config: KeybowConfig
    private let lighting: Lighting
    private let flashDuration: TimeInterval = 0.2

    private var navigator: Navigator
    private var timer: DispatchSourceTimer?
    private var consumer: Task<Void, Never>?
    private var lastSentColours: [KeyColour]?
    private var flash: (key: Int, until: Date)?
    private var continuation: AsyncStream<NavigatorEvent>.Continuation?
    private var connectionContinuation: AsyncStream<KeybowEvent>.Continuation?

    public let events: AsyncStream<NavigatorEvent>
    /// Connection news, republished. `KeybowConnection.events` has a single
    /// consumer — this driver — so anyone else must listen here instead.
    public let connectionEvents: AsyncStream<KeybowEvent>

    public init(config: KeybowConfig, connection: KeybowConnection, lighting: Lighting = Lighting()) {
        self.config = config
        self.connection = connection
        self.lighting = lighting
        self.navigator = Navigator(config: config)

        var captured: AsyncStream<NavigatorEvent>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured

        var capturedConnection: AsyncStream<KeybowEvent>.Continuation!
        self.connectionEvents = AsyncStream { capturedConnection = $0 }
        self.connectionContinuation = capturedConnection
    }

    public func start() {
        connection.start()

        consumer = Task { [weak self] in
            guard let self else { return }
            for await event in connection.events {
                connectionContinuation?.yield(event)
                switch event {
                case .message(.down(let key)):
                    apply { $0.keyDown(key, at: Date()) }
                case .message(.up(let key)):
                    apply { $0.keyUp(key, at: Date()) }
                case .connected:
                    // Re-assert the lights: a device that just reappeared is dark.
                    queue.async { self.lastSentColours = nil; self.refreshLights() }
                default:
                    break
                }
            }
        }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(100))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let produced = navigator.tick(at: Date())
            publish(produced)
            if let flash, flash.until <= Date() { self.flash = nil }
            refreshLights()
        }
        source.resume()
        timer = source
    }

    public func stop() {
        consumer?.cancel()
        consumer = nil
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            // Leave the keys dark rather than frozen mid-selection.
            connection.send(.leds([KeyColour](repeating: .off, count: KeybowProtocol.keyCount)))
            continuation?.finish()
            continuation = nil
            connectionContinuation?.finish()
            connectionContinuation = nil
        }
        connection.stop()
    }

    private func apply(_ body: @escaping (inout Navigator) -> [NavigatorEvent]) {
        queue.async { [self] in
            let produced = body(&navigator)
            for event in produced {
                if case .invalidPress(let key) = event {
                    flash = (key, Date().addingTimeInterval(flashDuration))
                }
            }
            publish(produced)
            refreshLights()
        }
    }

    private func publish(_ events: [NavigatorEvent]) {
        for event in events { continuation?.yield(event) }
    }

    /// Sends a LEDS command only when something actually changed.
    private func refreshLights() {
        let colours = lighting.colours(for: navigator, config: config, flashing: flash?.key)
        guard colours != lastSentColours else { return }
        lastSentColours = colours
        connection.send(.leds(colours))
    }
}
