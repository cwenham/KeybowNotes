import Foundation

// Modules: features built in behind one interface, so they can be added
// without touching the core — the stopwatch is the first. A module declares
// what it adds to the outline language, runs its own actions, and reports what
// it's doing; the host (the app) owns the Keybow, the overlay, the menu bar and
// the outline, and does all the showing.
//
// What a module can do:
//   - add action types, with keywords and fields, to the outline and editor
//   - run those actions when their keys are pressed
//   - offer {{placeholder}} values to every action — "{{stopwatch}}"
//   - report a status, shown on the overlay and in the menu bar, and light the
//     keys that lead to its actions while it's busy
//   - keep state between runs of the app, through its host
//
// Modules find each other through the registry, `ModuleRegistry.shared.module(id:)`,
// and may offer a Swift interface of their own to other modules. See docs/MODULES.md.

/// A feature plugged into KeybowNotes. Called from any thread: keep state
/// behind a lock.
public protocol KeybowModule: AnyObject, Sendable {
    /// What it adds. Read once, when it's registered.
    var manifest: ModuleManifest { get }

    /// Called once, when registered: the place to load saved state.
    func start(host: ModuleHost)

    /// What pressing a key with this action will do, for the overlay and the
    /// tree editor. Fields have their placeholders filled in.
    func summary(of request: ModuleRequest, now: Date) -> ModuleSummary

    /// Why this action can't be done as written — shown before anything
    /// runs — or nil when it can.
    func problem(with request: ModuleRequest) -> String?

    /// True to run the moment its key is pressed, skipping the time to cancel:
    /// for actions where the moment matters, like starting a stopwatch.
    /// Fields here are as written, placeholders unfilled. `instant:` on the
    /// node overrides it either way.
    func firesAtOnce(_ request: ModuleRequest) -> Bool

    /// Does it. `now` is when the key was pressed, which may be a moment ago.
    func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome

    /// Values for {{placeholders}}, offered to every action. Names should start
    /// with the module's id: "stopwatch", "stopwatch.laps".
    func values(now: Date) -> [String: String]

    /// What it's doing in the background, or nil when there's nothing to show.
    func status(now: Date) -> ModuleStatus?
}

extension KeybowModule {
    public func problem(with request: ModuleRequest) -> String? { nil }
    public func firesAtOnce(_ request: ModuleRequest) -> Bool { false }
    public func values(now: Date) -> [String: String] { [:] }
    public func status(now: Date) -> ModuleStatus? { nil }
}

/// What a module adds to the outline language and the editor.
public struct ModuleManifest: Sendable {
    /// Short and lowercase: "stopwatch". Prefixes its values and saved state.
    public let id: String
    public let name: String
    public let actionTypes: [ModuleActionType]

    public init(id: String, name: String, actionTypes: [ModuleActionType]) {
        self.id = id
        self.name = name
        self.actionTypes = actionTypes
    }
}

public struct ModuleActionType: Sendable {
    /// The type as the config names it: "stopwatch".
    public let type: String
    /// Shown in the editor's Type menu: "Stopwatch".
    public let title: String
    /// Words that mark a node with this type in the outline, as they should be
    /// written: "Stopwatch". Matched without regard to case.
    public let keywords: [String]
    /// An SF Symbol for the overlay.
    public let symbol: String
    public let fields: [ModuleField]

    public init(type: String, title: String, keywords: [String], symbol: String, fields: [ModuleField]) {
        self.type = type
        self.title = title
        self.keywords = keywords
        self.symbol = symbol
        self.fields = fields
    }
}

public struct ModuleField: Sendable {
    public enum Kind: Sendable, Equatable {
        case text
        case number
        case flag
        /// One of a few words, offered as a menu.
        case choice([String])
    }

    public let key: String
    public let title: String
    public let kind: Kind
    public let hint: String

    public init(key: String, title: String, kind: Kind = .text, hint: String = "") {
        self.key = key
        self.title = title
        self.kind = kind
        self.hint = hint
    }
}

/// An action for a module to carry out: its type, and its fields with every
/// placeholder filled in.
public struct ModuleRequest: Equatable, Sendable {
    public let type: String
    public let fields: [String: String]
    /// The labels chosen, from the top of the tree.
    public let labels: [String]
    /// When its key was pressed.
    public let time: Date

    public init(type: String, fields: [String: String], labels: [String], time: Date = Date()) {
        self.type = type
        self.fields = fields
        self.labels = labels
        self.time = time
    }

    public var leaf: String { labels.last ?? "" }

    /// A field, or nil when it's missing or empty.
    public func field(_ key: String) -> String? {
        fields[key].flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct ModuleSummary: Equatable, Sendable {
    /// "Start stopwatch".
    public let verb: String
    public let subject: String
    public let details: [String]

    public init(verb: String, subject: String, details: [String] = []) {
        self.verb = verb
        self.subject = subject
        self.details = details
    }
}

/// What a module is doing, for the overlay, the menu bar and the keys.
public struct ModuleStatus: Equatable, Sendable {
    public let moduleID: String
    public let symbol: String
    public let title: String
    /// Set while a clock is running up from this moment, so the host can show
    /// it live without asking again.
    public let countingFrom: Date?
    /// Shown when nothing is counting: "3:12".
    public let text: String
    public let detail: String?
    /// Pulse the keys that lead to this module's actions, in their own colours.
    public let lightsKeys: Bool

    public init(moduleID: String, symbol: String, title: String, countingFrom: Date? = nil, text: String = "",
                detail: String? = nil, lightsKeys: Bool = false) {
        self.moduleID = moduleID
        self.symbol = symbol
        self.title = title
        self.countingFrom = countingFrom
        self.text = text
        self.detail = detail
        self.lightsKeys = lightsKeys
    }
}

/// What the host offers a module.
public protocol ModuleHost: AnyObject, Sendable {
    /// Saved between runs of the app, per module.
    func load(_ key: String, for module: String) -> Data?
    func save(_ data: Data?, as key: String, for module: String)
    /// The module's status or values changed outside an action it was asked
    /// to run: show it.
    func statusChanged()
}

/// Keeps modules' state in memory only: for tools and tests, where nothing
/// needs to outlive the run.
public final class MemoryModuleHost: ModuleHost, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]

    public init() {}

    public func load(_ key: String, for module: String) -> Data? {
        lock.withLock { stored["\(module).\(key)"] }
    }

    public func save(_ data: Data?, as key: String, for module: String) {
        lock.withLock { stored["\(module).\(key)"] = data }
    }

    public func statusChanged() {}
}

/// The modules in this app, and what they add together.
public final class ModuleRegistry: @unchecked Sendable {
    public static let shared = ModuleRegistry()

    private let lock = NSLock()
    private var modules: [KeybowModule] = []

    public init() {}

    /// Adds a module, replacing one with the same id, and starts it.
    public func register(_ module: KeybowModule, host: ModuleHost) {
        lock.withLock {
            modules.removeAll { $0.manifest.id == module.manifest.id }
            modules.append(module)
        }
        module.start(host: host)
    }

    public var all: [KeybowModule] { lock.withLock { modules } }

    public func module(id: String) -> KeybowModule? {
        all.first { $0.manifest.id == id }
    }

    public func module(handling type: String) -> KeybowModule? {
        all.first { $0.manifest.actionTypes.contains { $0.type == type } }
    }

    public var actionTypes: [ModuleActionType] { all.flatMap(\.manifest.actionTypes) }

    public func actionType(_ type: String) -> ModuleActionType? {
        actionTypes.first { $0.type == type }
    }

    /// Lowercased keyword → action type.
    public var keywords: [String: String] {
        var result: [String: String] = [:]
        for type in actionTypes {
            for word in type.keywords { result[word.lowercased()] = type.type }
        }
        return result
    }

    public var fields: [ModuleField] { actionTypes.flatMap(\.fields) }

    /// Every module's values, together.
    public func values(now: Date) -> [String: String] {
        all.reduce(into: [:]) { result, module in
            result.merge(module.values(now: now)) { first, _ in first }
        }
    }

    public func statuses(now: Date) -> [ModuleStatus] {
        all.compactMap { $0.status(now: now) }
    }
}

extension KeybowConfig {
    /// The idle keys that lead to leaves whose action is one of `types`: the
    /// first key of each tree path that gets there.
    public func entryKeys(toActionTypes types: Set<String>) -> Set<Int> {
        var keys = Set<Int>()
        for tree in TreeKind.allCases {
            for (column, root) in roots(tree).enumerated() {
                guard let root else { continue }
                if leads(to: types, node: root, tree: tree, path: [column]) {
                    keys.insert(KeybowProtocol.key(row: tree.startRow, column: column))
                }
            }
        }
        return keys
    }

    private func leads(to types: Set<String>, node: TreeNode, tree: TreeKind, path: [Int]) -> Bool {
        if node.isLeaf {
            return resolve(tree: tree, path: path)?.action.map { types.contains($0.type) } ?? false
        }
        return node.children.enumerated().contains { slot, child in
            guard let child else { return false }
            return leads(to: types, node: child, tree: tree, path: path + [slot])
        }
    }
}
