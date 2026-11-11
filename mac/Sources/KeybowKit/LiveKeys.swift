import Foundation

/// A key that shows something as it changes — the CPU's load, unread mail,
/// free disk space, a count of views — on a keypad with screens.
///
/// A module makes one of its action types live by answering
/// `liveInterval(for:)` with how often to look again, and `reading(for:now:)`
/// with what to show. The host asks only for live keys a keypad with screens
/// is showing, at that pace, and draws each reading on its key: the value
/// large, a caption under it, and — given a level — a fill rising from the
/// bottom like a thermometer. Pressing the key runs its action as usual.

/// Which live key: its type and fields. Keys alike share their readings.
public struct LiveKeySpec: Hashable, Sendable {
    public let type: String
    public let fields: [String: String]

    public init(type: String, fields: [String: String] = [:]) {
        self.type = type
        self.fields = fields
    }

    /// From an action, its fields as text. Nil for an action that isn't live.
    public init?(_ action: ActionSpec?, registry: ModuleRegistry = .shared) {
        guard let action, registry.isLive(action.type) else { return nil }
        var fields: [String: String] = [:]
        for (key, value) in action.fields { if let text = value.stringValue { fields[key] = text } }
        self.init(type: action.type, fields: fields)
    }
}

/// What a live key shows, at one moment.
public struct LiveKeyReading: Hashable, Sendable {
    /// Large, in the middle: "23%", "4", "1.2 TB".
    public var value: String
    /// Small, under it: "CPU". Without one, the key's own caption or label.
    public var caption: String?
    /// 0 to 1: how far the fill rises from the bottom. Nil for none.
    public var level: Double?
    /// The fill's colour. Nil: green, turning amber past 60% and red past 85%.
    public var levelColour: KeyColour?

    public init(value: String, caption: String? = nil, level: Double? = nil, levelColour: KeyColour? = nil) {
        self.value = value
        self.caption = caption
        self.level = level.map { min(1, max(0, $0)) }
        self.levelColour = levelColour
    }

    /// The fill's colour, worked out from the level when not given.
    public var fillColour: KeyColour {
        if let levelColour { return levelColour }
        let level = level ?? 0
        if level >= 0.85 { return KeyColour(red: 0xE0, green: 0x30, blue: 0x30) }
        if level >= 0.6 { return KeyColour(red: 0xF0, green: 0xA0, blue: 0x20) }
        return KeyColour(red: 0x20, green: 0xB0, blue: 0x50)
    }
}

extension ModuleRegistry {
    /// A type a module draws live, on keypads with screens.
    public func isLive(_ type: String) -> Bool {
        guard let module = module(handling: type) else { return false }
        return module.liveInterval(for: LiveKeySpec(type: type)) != nil
    }

    /// A type that only makes sense on a keypad with screens.
    public func needsDisplay(_ type: String) -> Bool {
        vocabulary.types.first { $0.type == type }?.needsDisplay ?? false
    }
}

extension KeybowConfig {
    /// Every live key in the trees and the pinned keys, as it would run.
    public func liveKeys(registry: ModuleRegistry = .shared) -> Set<LiveKeySpec> {
        var found = Set<LiveKeySpec>()
        func walk(_ nodes: [TreeNode?], tree: TreeKind, path: [Int]) {
            for (slot, node) in nodes.enumerated() {
                guard let node else { continue }
                let here = path + [slot]
                if node.isLeaf {
                    if let spec = LiveKeySpec(resolve(tree: tree, path: here)?.action, registry: registry) {
                        found.insert(spec)
                    }
                } else {
                    walk(node.children, tree: tree, path: here)
                }
            }
        }
        for tree in TreeKind.everyTree { walk(roots(tree), tree: tree, path: []) }
        return found
    }
}

/// Keeps live keys' readings coming: one loop for each key being shown, at
/// its module's pace. The host says which keys to watch and hears each reading.
public final class LiveKeyWatcher: @unchecked Sendable {
    private let registry: ModuleRegistry
    private let lock = NSLock()
    private var loops: [LiveKeySpec: Task<Void, Never>] = [:]
    private let onReading: @Sendable (LiveKeySpec, LiveKeyReading) -> Void

    public init(registry: ModuleRegistry = .shared, onReading: @escaping @Sendable (LiveKeySpec, LiveKeyReading) -> Void) {
        self.registry = registry
        self.onReading = onReading
    }

    deinit { watch([]) }

    /// Starts loops for keys not yet watched; stops those no longer wanted.
    public func watch(_ specs: Set<LiveKeySpec>) {
        lock.lock()
        defer { lock.unlock() }
        for (spec, loop) in loops where !specs.contains(spec) {
            loop.cancel()
            loops[spec] = nil
        }
        for spec in specs where loops[spec] == nil {
            guard let module = registry.module(handling: spec.type),
                  let interval = module.liveInterval(for: spec) else { continue }
            let onReading = onReading
            loops[spec] = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    if let reading = await module.reading(for: spec, now: Date()), !Task.isCancelled {
                        onReading(spec, reading)
                    }
                    try? await Task.sleep(for: .seconds(max(0.25, interval)))
                }
            }
        }
    }

    public var watching: Set<LiveKeySpec> {
        lock.lock()
        defer { lock.unlock() }
        return Set(loops.keys)
    }
}
