import Foundation

/// Everything a display needs to draw the current state, in one value.
public struct SelectionSnapshot: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let column: Int
        public let label: String
        public let colour: KeyColour
        public let isLeaf: Bool
    }

    /// The page in use: its key, and its keys by their place on it — an
    /// option's `column` is that place, 0 to 11.
    public struct Page: Equatable, Sendable {
        public let tree: TreeKind
        public let column: Int
        public let label: String
        public let colour: KeyColour
        public let keys: [Option]
    }

    public let tree: TreeKind?
    public let selection: ResolvedSelection?
    /// The row being chosen from, zero-based.
    public let currentRow: Int?
    /// The options on that row; empty while idle.
    public let options: [Option]
    /// Exactly what the keypad is showing.
    public let colours: [KeyColour]
    /// When the pending action runs, if one is waiting.
    public let pending: ClosedRange<Date>?
    /// While a page is showing. The keypad counts as idle — nothing is being
    /// chosen — though its keys are the page's.
    public var page: Page? = nil

    public var isIdle: Bool { tree == nil }

    public static let idle = SelectionSnapshot(
        tree: nil, selection: nil, currentRow: nil, options: [],
        colours: [KeyColour](repeating: .off, count: KeybowProtocol.keyCount), pending: nil
    )
}

/// Joins the device to the navigator: feeds key events in, pushes LED state out,
/// and publishes what the user is choosing. The app and the CLI both use this.
public final class SelectionDriver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SelectionDriver")
    private let connection: KeybowConnection
    private var config: KeybowConfig
    private var lighting: Lighting
    private let flashDuration: TimeInterval = 0.2

    private var navigator: Navigator
    private var timer: DispatchSourceTimer?
    private var consumer: Task<Void, Never>?
    private var lastSentColours: [KeyColour]?
    private var lastSnapshot: SelectionSnapshot?
    private var flash: (key: Int, until: Date)?
    /// A page's key, pressed: bright while its action starts.
    private var firing: (key: Int, until: Date)?
    private var continuation: AsyncStream<NavigatorEvent>.Continuation?
    private var connectionContinuation: AsyncStream<KeybowEvent>.Continuation?
    private var snapshotContinuation: AsyncStream<SelectionSnapshot>.Continuation?

    public let events: AsyncStream<NavigatorEvent>
    /// Connection news, republished. `KeybowConnection.events` has a single
    /// consumer — this driver — so anyone else must listen here instead.
    public let connectionEvents: AsyncStream<KeybowEvent>
    /// The whole state, whenever it changes. Like the others, one consumer.
    public let snapshots: AsyncStream<SelectionSnapshot>

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

        var capturedSnapshot: AsyncStream<SelectionSnapshot>.Continuation!
        self.snapshots = AsyncStream { capturedSnapshot = $0 }
        self.snapshotContinuation = capturedSnapshot
    }

    public func start() {
        connection.start()

        consumer = Task { [weak self] in
            guard let self else { return }
            for await event in connection.events {
                connectionContinuation?.yield(event)
                switch event {
                case .message(let message):
                    inject(message)
                case .connected:
                    // Re-assert the lights: a device that just reappeared is dark.
                    queue.async { self.lastSentColours = nil; self.refresh() }
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
            if let firing, firing.until <= Date() { self.firing = nil }
            refresh()
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
            snapshotContinuation?.finish()
            snapshotContinuation = nil
        }
        connection.stop()
    }

    /// Swaps in a new config — after the file was edited, say. Any selection in
    /// progress is dropped, since its path may not exist any more.
    public func replaceConfig(_ newConfig: KeybowConfig) {
        queue.async { [self] in
            config = newConfig
            // A page stays up through an edit, if it's still there.
            let page = navigator.page
            navigator = Navigator(config: newConfig)
            navigator.restore(page: page)
            flash = nil
            refresh()
        }
    }

    /// 0.05 to 1: dims every key, for a dark room.
    public func setBrightness(_ value: Double) {
        queue.async { [self] in
            lighting.brightness = min(1, max(0.05, value))
            refresh()
        }
    }

    /// Idle keys to pulse: those leading to a module that's busy — and, on
    /// pages, the keys that run its actions.
    public func setPulsingKeys(_ keys: Set<Int>, onPages: [KeypadPage: Set<Int>] = [:]) {
        queue.async { [self] in
            guard lighting.pulsing != keys || lighting.pulsingOnPages != onPages else { return }
            lighting.pulsing = keys
            lighting.pulsingOnPages = onPages
            refresh()
        }
    }

    /// Sends a command straight to the keypad: STOP, before it's set up again.
    public func send(_ command: HostCommand) {
        connection.send(command)
    }

    /// Feeds a key event in as though it came from the device. The device's own
    /// events arrive this way too; the demo uses it to simulate presses.
    public func inject(_ message: DeviceMessage) {
        switch message {
        case .down(let key):
            apply(pressing: key) { $0.keyDown(key, at: Date()) }
        case .up(let key):
            apply { $0.keyUp(key, at: Date()) }
        default:
            break
        }
    }

    private func apply(pressing pressed: Int? = nil, _ body: @escaping (inout Navigator) -> [NavigatorEvent]) {
        queue.async { [self] in
            let produced = body(&navigator)
            for event in produced {
                if case .invalidPress(let key) = event {
                    flash = (key, Date().addingTimeInterval(flashDuration))
                }
                // A page's key runs its action as it's pressed.
                if case .fire = event, let pressed, navigator.page != nil {
                    firing = (pressed, Date().addingTimeInterval(flashDuration))
                }
            }
            publish(produced)
            refresh()
        }
    }

    private func publish(_ events: [NavigatorEvent]) {
        for event in events { continuation?.yield(event) }
    }

    /// Sends LEDs and a snapshot, each only when something actually changed.
    private func refresh() {
        let colours = lighting.colours(for: navigator, config: config, flashing: flash?.key, firing: firing?.key)
        if colours != lastSentColours {
            lastSentColours = colours
            connection.send(.leds(colours))
        }

        let options = navigator.currentOptions.enumerated().compactMap { column, node -> SelectionSnapshot.Option? in
            guard let node else { return nil }
            return .init(column: column, label: node.label, colour: node.colour ?? config.defaultColour,
                         isLeaf: node.isLeaf)
        }
        var page: SelectionSnapshot.Page?
        if let current = navigator.page, let resolved = navigator.pageSelection {
            let colour = resolved.node.colour ?? config.defaultColour
            let keys = resolved.node.children.enumerated().compactMap { slot, node -> SelectionSnapshot.Option? in
                guard let node else { return nil }
                return .init(column: slot, label: node.label, colour: node.colour ?? colour, isLeaf: node.isLeaf)
            }
            page = .init(tree: current.tree, column: current.column, label: resolved.node.label, colour: colour, keys: keys)
        }
        let snapshot = SelectionSnapshot(
            tree: navigator.tree,
            selection: navigator.selection,
            currentRow: navigator.currentRow,
            options: options,
            colours: colours,
            pending: navigator.pendingWindow,
            page: page
        )
        if snapshot != lastSnapshot {
            lastSnapshot = snapshot
            snapshotContinuation?.yield(snapshot)
        }
    }
}
