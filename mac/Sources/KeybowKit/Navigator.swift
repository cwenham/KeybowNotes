import Foundation

/// What the navigator wants the rest of the app to know.
public enum NavigatorEvent: Equatable, Sendable {
    /// The chosen path changed; nil means everything was cleared.
    case selectionChanged(ResolvedSelection?)
    /// A key that is not a valid option right now.
    case invalidPress(key: Int)
    /// A leaf was chosen; the action runs when the commit delay elapses.
    case pending(ResolvedSelection)
    /// Run this now. `chosenAt` is when its key was pressed — before the time
    /// to cancel, if it had one — for actions where the moment matters.
    case fire(ResolvedSelection, chosenAt: Date)
    case cleared(reason: ClearReason)
    /// A page was turned to — or, with nil, left for the trees.
    case page(ResolvedSelection?)

    public enum ClearReason: String, Equatable, Sendable {
        case cancelled      // a press during the commit window
        case longPress
        case idleTimeout
        case completed      // the action fired
    }
}

/// A page in use: which tree's pages, and which key on its row.
public struct KeypadPage: Hashable, Sendable {
    public let tree: TreeKind
    public let column: Int

    public init(tree: TreeKind, column: Int) {
        self.tree = tree
        self.column = column
    }
}

/// The selection state machine: pure, and driven entirely by the caller.
///
/// Time is passed in rather than read, so the whole thing is testable without
/// waiting for real seconds to pass.
///
/// With nothing chosen, the row of the first press picks the tree (see
/// `TreeKind`). From then on:
/// - a press on a row already passed, or the next row, chooses at that depth
///   and drops everything beyond it
/// - a press further along than the next row is ignored
/// - the top row always restarts the main tree when it is not a legal move in
///   the current one — the one way to switch trees without finishing
///
/// A tree set as pages works differently. Its first row picks a page, which
/// stays: the rows below become the page's keys, each running its action the
/// moment it's pressed, until another page is picked. Pressing the page's own
/// key again, or any key on a row above, goes back to the trees — the latter
/// counting as the first press of its tree.
public struct Navigator {
    public private(set) var tree: TreeKind?
    public private(set) var path: [Int] = []
    /// The page in use, while the keypad shows one.
    public private(set) var page: KeypadPage?
    public private(set) var pendingSince: Date?
    /// How long the pending leaf waits: the config's time to cancel, or none
    /// for an action that runs at once.
    public private(set) var pendingDelay: TimeInterval = 0

    /// From the choice to the moment it runs.
    public var pendingWindow: ClosedRange<Date>? {
        pendingSince.map { $0...$0.addingTimeInterval(pendingDelay) }
    }

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
        guard let tree else { return nil }
        return config.resolve(tree: tree, path: path)
    }

    /// The page in use, resolved: its label, colour and keys.
    public var pageSelection: ResolvedSelection? {
        page.flatMap { config.resolve(tree: $0.tree, path: [$0.column]) }
    }

    /// Back on a page after the config was reloaded, if it's still there.
    public mutating func restore(page wanted: KeypadPage?) {
        guard let wanted, tree == nil, config.isPaged(wanted.tree),
              config.resolve(tree: wanted.tree, path: [wanted.column]) != nil else { return }
        page = wanted
    }

    /// The options on offer in the current tree, as four slots of the next row.
    /// Empty while idle, when every tree's first row is on offer at once.
    public var currentOptions: [TreeNode?] {
        guard let tree else { return KeybowConfig.emptyRow }
        return config.options(in: tree, after: path)
    }

    /// Which row the user is choosing from now (0-3), or nil while idle or when
    /// the tree is exhausted.
    public var currentRow: Int? {
        guard let tree, path.count < tree.levels else { return nil }
        return tree.rows[path.count]
    }

    public mutating func keyDown(_ key: Int, at now: Date) -> [NavigatorEvent] {
        lastActivity = now
        heldSince[key] = now

        // Any press during the commit window calls the whole thing off.
        if pendingSelection != nil {
            reset()
            return [.cleared(reason: .cancelled), .selectionChanged(nil)]
        }

        let row = key / KeybowProtocol.columns
        let column = key % KeybowProtocol.columns

        // On a page: its row turns pages, and the rows below are its keys.
        if let page {
            if row == page.tree.startRow {
                // Its own key again: back to the trees.
                if column == page.column { return leavePage() }
                return turn(to: KeypadPage(tree: page.tree, column: column), key: key)
            }
            if let slot = page.tree.pageSlot(ofKey: key) {
                guard let resolved = config.resolve(tree: page.tree, path: [page.column, slot]),
                      resolved.node.isLeaf else { return [.invalidPress(key: key) ] }
                return [.fire(resolved, chosenAt: now)]
            }
            // A row above: back to the trees, this press the first in one.
            let left = leavePage()
            return left + press(row: row, column: column, key: key, at: now)
        }
        return press(row: row, column: column, key: key, at: now)
    }

    /// A press while choosing in the trees.
    private mutating func press(row: Int, column: Int, key: Int, at now: Date) -> [NavigatorEvent] {
        // A legal move in the tree already in play?
        if let tree, let depth = tree.rows.firstIndex(of: row), depth <= path.count {
            return choose(tree: tree, path: Array(path.prefix(depth)) + [column], at: now, key: key)
        }

        // Starting fresh: the row picks the tree — or, for pages, the page.
        if tree == nil, let fresh = TreeKind.starting(at: row) {
            if config.isPaged(fresh) { return turn(to: KeypadPage(tree: fresh, column: column), key: key) }
            return choose(tree: fresh, path: [column], at: now, key: key)
        }

        // Mid-path, the top row escapes to the main tree — or to its pages.
        if tree != nil, row == TreeKind.main.startRow, config.roots(.main)[column] != nil {
            if config.isPaged(.main) {
                reset()
                return [.selectionChanged(nil)] + turn(to: KeypadPage(tree: .main, column: column), key: key)
            }
            return choose(tree: .main, path: [column], at: now, key: key)
        }

        return [.invalidPress(key: key)]
    }

    private mutating func turn(to candidate: KeypadPage, key: Int) -> [NavigatorEvent] {
        guard let resolved = config.resolve(tree: candidate.tree, path: [candidate.column]) else {
            return [.invalidPress(key: key)]
        }
        page = candidate
        return [.page(resolved)]
    }

    private mutating func leavePage() -> [NavigatorEvent] {
        page = nil
        return [.page(nil)]
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
           now.timeIntervalSince(since) >= pendingDelay {
            reset()
            events.append(.fire(pending, chosenAt: since))
            events.append(.cleared(reason: .completed))
        }

        // Long press clears everything, since no key is free to act as cancel.
        for (key, since) in heldSince where !cancelledByLongPress.contains(key) {
            if now.timeIntervalSince(since) >= config.longPressCancel {
                cancelledByLongPress.insert(key)
                if tree != nil {
                    reset()
                    events.append(.cleared(reason: .longPress))
                    events.append(.selectionChanged(nil))
                }
            }
        }

        if tree != nil, pendingSelection == nil, config.idleTimeout > 0,
           now.timeIntervalSince(lastActivity) >= config.idleTimeout {
            reset()
            events.append(.cleared(reason: .idleTimeout))
            events.append(.selectionChanged(nil))
        }

        return events
    }

    // MARK: - Private

    private mutating func choose(tree chosenTree: TreeKind, path candidate: [Int], at now: Date,
                                 key: Int) -> [NavigatorEvent] {
        guard let resolved = config.resolve(tree: chosenTree, path: candidate) else {
            return [.invalidPress(key: key)]
        }

        tree = chosenTree
        path = candidate
        var events: [NavigatorEvent] = [.selectionChanged(resolved)]

        if resolved.node.isLeaf {
            let delay = config.commitDelay(for: resolved)
            if delay > 0 {
                pendingSelection = resolved
                pendingSince = now
                pendingDelay = delay
                events.append(.pending(resolved))
            } else {
                reset()
                events.append(.fire(resolved, chosenAt: now))
                events.append(.cleared(reason: .completed))
            }
        }
        return events
    }

    private mutating func reset() {
        tree = nil
        path = []
        pendingSelection = nil
        pendingSince = nil
    }
}
