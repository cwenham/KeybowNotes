import Foundation

/// What the navigator wants the rest of the app to know.
public enum NavigatorEvent: Equatable, Sendable {
    /// The chosen path changed; empty means everything was cleared.
    case selectionChanged(ResolvedSelection?)
    /// A key that is not a valid option right now.
    case invalidPress(key: Int)
    /// A leaf was chosen; the action runs when the commit delay elapses.
    case pending(ResolvedSelection)
    /// Run this now.
    case fire(ResolvedSelection)
    case cleared(reason: ClearReason)

    public enum ClearReason: String, Equatable, Sendable {
        case cancelled      // a press during the commit window
        case longPress
        case idleTimeout
        case completed      // the action fired
    }
}

/// The selection state machine: pure, and driven entirely by the caller.
///
/// Time is passed in rather than read, so the whole thing is testable without
/// waiting for real seconds to pass.
public struct Navigator {
    public private(set) var path: [Int] = []
    public private(set) var pendingSince: Date?

    private let config: KeybowConfig
    private var heldSince: [Int: Date] = [:]
    private var cancelledByLongPress: Set<Int> = []
    private var lastActivity: Date
    private var pendingSelection: ResolvedSelection?

    public init(config: KeybowConfig, now: Date = Date()) {
        self.config = config
        self.lastActivity = now
    }

    public var selection: ResolvedSelection? {
        config.resolve(path: path)
    }

    /// The options currently on offer, as four slots of the next row.
    public var currentOptions: [TreeNode?] {
        config.options(after: path)
    }

    /// Which row the user is choosing from now (0-3), or nil when the tree is exhausted.
    public var currentRow: Int? {
        path.count < KeybowProtocol.rows ? path.count : nil
    }

    public mutating func keyDown(_ key: Int, at now: Date) -> [NavigatorEvent] {
        lastActivity = now
        heldSince[key] = now

        // Any press during the commit window calls the whole thing off.
        if pendingSelection != nil {
            pendingSelection = nil
            pendingSince = nil
            path = []
            return [.cleared(reason: .cancelled), .selectionChanged(nil)]
        }

        let row = key / KeybowProtocol.columns
        let column = key % KeybowProtocol.columns

        // A row below the one in play is not selectable yet.
        guard row <= path.count else { return [.invalidPress(key: key)] }

        var candidate = Array(path.prefix(row))
        candidate.append(column)
        guard let resolved = config.resolve(path: candidate) else {
            return [.invalidPress(key: key)]
        }

        path = candidate
        var events: [NavigatorEvent] = [.selectionChanged(resolved)]

        if resolved.action != nil {
            if config.commitDelay > 0 {
                pendingSelection = resolved
                pendingSince = now
                events.append(.pending(resolved))
            } else {
                path = []
                events.append(.fire(resolved))
                events.append(.cleared(reason: .completed))
            }
        }
        return events
    }

    public mutating func keyUp(_ key: Int, at now: Date) -> [NavigatorEvent] {
        lastActivity = now
        heldSince.removeValue(forKey: key)
        // The long press already cleared things on the way down.
        cancelledByLongPress.remove(key)
        return []
    }

    /// Call regularly: drives long-press cancelling, the commit delay and the idle timeout.
    public mutating func tick(at now: Date) -> [NavigatorEvent] {
        var events: [NavigatorEvent] = []

        // A due action is settled first, deliberately. Otherwise simply holding
        // the last key down through the commit delay would cancel the very
        // action it had just chosen. Cancelling within the window is done by
        // pressing another key; long press is for abandoning a partial path.
        if let pending = pendingSelection, let since = pendingSince,
           now.timeIntervalSince(since) >= config.commitDelay {
            pendingSelection = nil
            pendingSince = nil
            path = []
            events.append(.fire(pending))
            events.append(.cleared(reason: .completed))
        }

        // Long press clears everything, since no key is free to act as cancel.
        for (key, since) in heldSince where !cancelledByLongPress.contains(key) {
            if now.timeIntervalSince(since) >= config.longPressCancel {
                cancelledByLongPress.insert(key)
                if !path.isEmpty || pendingSelection != nil {
                    path = []
                    pendingSelection = nil
                    pendingSince = nil
                    events.append(.cleared(reason: .longPress))
                    events.append(.selectionChanged(nil))
                }
            }
        }

        if !path.isEmpty, pendingSelection == nil, config.idleTimeout > 0,
           now.timeIntervalSince(lastActivity) >= config.idleTimeout {
            path = []
            events.append(.cleared(reason: .idleTimeout))
            events.append(.selectionChanged(nil))
        }

        return events
    }
}
