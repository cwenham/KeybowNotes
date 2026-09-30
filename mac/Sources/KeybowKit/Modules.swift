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

    /// Commands for the menu bar's menu, asked each time it opens: a way to
    /// do things for which no key has been set up — stopping a stopwatch that
    /// was started from a key that only starts it.
    func menuItems(now: Date) -> [ModuleMenuItem]

    /// Does a menu command, and says what happened.
    func performMenuItem(_ id: String, now: Date) -> ActionOutcome?

    /// The reply to one of its blocks — `{{#ai}}…{{/ai}}` — whose contents
    /// have already been filled in. Runs off the main thread, perhaps
    /// alongside others; cancelling the task cancels it. Throw a
    /// `ModuleError` to say what went wrong.
    func reply(to call: TemplateBlockCall) async throws -> String

    /// What a block shows in previews, where nothing is asked: "‹Claude's reply›".
    func standIn(for call: TemplateBlockCall) -> String

    /// Values it fetches when an action uses them — `{{api.weather}}` for a
    /// module whose manifest lists "api" in `fetches`. Asked before an action
    /// runs, only for the names it uses, with the values it can draw on.
    /// Runs off the main thread; cancelling the task cancels it.
    func fetch(_ names: [String], params: [String: String], now: Date) async throws -> [String: String]

    /// Other values those names need to be fetched — a URL's `{{city}}` or
    /// `{{selection}}` — so the host gets them ready first. They may be
    /// another module's fetched values, `{{location.latitude}}`, which are
    /// fetched before these.
    func valuesNeeded(toFetch names: [String]) -> Set<String>

    /// What a fetched value shows in previews: "‹weather›".
    func standIn(forValue name: String) -> String

    /// What's being fetched, for the overlay's "Fetching …": "weather",
    /// "your location".
    func fetchSubject(for names: [String]) -> String
}

/// A module's reason, fit to show on the overlay.
public struct ModuleError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let detail: String?

    public init(_ message: String, _ detail: String? = nil) {
        self.message = message
        self.detail = detail
    }

    public var description: String { detail.map { "\(message) — \($0)" } ?? message }
}

extension KeybowModule {
    public func problem(with request: ModuleRequest) -> String? { nil }
    public func firesAtOnce(_ request: ModuleRequest) -> Bool { false }
    public func values(now: Date) -> [String: String] { [:] }
    public func status(now: Date) -> ModuleStatus? { nil }
    public func menuItems(now: Date) -> [ModuleMenuItem] { [] }
    public func performMenuItem(_ id: String, now: Date) -> ActionOutcome? { nil }
    public func reply(to call: TemplateBlockCall) async throws -> String {
        throw ModuleError("{{#\(call.name)}} isn't something this module can reply to")
    }
    public func standIn(for call: TemplateBlockCall) -> String { "‹\(call.name)›" }
    public func fetch(_ names: [String], params: [String: String], now: Date) async throws -> [String: String] {
        throw ModuleError("This module doesn't fetch values")
    }
    public func valuesNeeded(toFetch names: [String]) -> Set<String> { [] }
    public func standIn(forValue name: String) -> String { "‹\(name)›" }
    public func fetchSubject(for names: [String]) -> String { manifest.name }
}

/// A command a module offers in the menu bar's menu — or a submenu of them,
/// or, with an empty id, a line of information: a lap time.
public struct ModuleMenuItem: Equatable, Sendable {
    /// Handed back to `performMenuItem` when it's chosen. Empty for a line
    /// that only shows something, or one that opens a submenu.
    public let id: String
    public let title: String
    /// Shown either way, so it can be found; only usable when this is true.
    public let isEnabled: Bool
    /// Items in a submenu under this one.
    public let submenu: [ModuleMenuItem]

    public init(id: String, title: String, isEnabled: Bool, submenu: [ModuleMenuItem] = []) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
        self.submenu = submenu
    }

    /// A line that only shows something.
    public static func information(_ title: String) -> ModuleMenuItem {
        ModuleMenuItem(id: "", title: title, isEnabled: true)
    }
}

/// What a module adds to the outline language and the editor.
public struct ModuleManifest: Sendable {
    /// Short and lowercase: "stopwatch". Prefixes its values and saved state.
    public let id: String
    public let name: String
    public let actionTypes: [ModuleActionType]
    /// Template blocks it replies to: `{{#ai}}`.
    public let blocks: [ModuleBlockType]
    /// Its part of the Settings window.
    public let settings: [ModuleSetting]
    /// Value prefixes it fetches: "api" for `{{api.weather}}`.
    public let fetches: [String]

    public init(id: String, name: String, actionTypes: [ModuleActionType] = [], blocks: [ModuleBlockType] = [],
                settings: [ModuleSetting] = [], fetches: [String] = []) {
        self.id = id
        self.name = name
        self.actionTypes = actionTypes
        self.blocks = blocks
        self.settings = settings
        self.fetches = fetches
    }
}

/// A template block a module replies to.
public struct ModuleBlockType: Sendable {
    /// As written in templates: "ai" for `{{#ai}}…{{/ai}}`.
    public let name: String
    /// Who replies, for messages: "Claude".
    public let title: String

    public init(name: String, title: String) {
        self.name = name
        self.title = title
    }
}

/// A setting in the module's part of the Settings window. The host draws it
/// and keeps it: secrets in the Keychain, the rest with the app's settings.
public struct ModuleSetting: Sendable {
    public enum Kind: Sendable, Equatable {
        case text
        /// Kept in the Keychain, never shown once saved: an API key.
        case secret
        case choice([Choice])
        case flag
    }

    public struct Choice: Sendable, Equatable {
        public let value: String
        public let title: String

        public init(_ value: String, _ title: String) {
            self.value = value
            self.title = title
        }
    }

    public let key: String
    public let title: String
    public let kind: Kind
    /// Used until the person sets one.
    public let defaultValue: String
    /// The tooltip: what it does, and an example.
    public let help: String

    public init(key: String, title: String, kind: Kind, defaultValue: String = "", help: String = "") {
        self.key = key
        self.title = title
        self.kind = kind
        self.defaultValue = defaultValue
        self.help = help
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
    /// Takes a template or text, like Copy: the planner fills it in whole —
    /// the `template` file, else `text`, else the label — trims it, and hands
    /// it over as the request's `text`. Values placed into an HTML document
    /// are escaped as HTML.
    public let takesText: Bool

    public init(type: String, title: String, keywords: [String], symbol: String, fields: [ModuleField],
                takesText: Bool = false) {
        self.type = type
        self.title = title
        self.keywords = keywords
        self.symbol = symbol
        self.fields = fields
        self.takesText = takesText
    }
}

public struct ModuleField: Sendable {
    public enum Kind: Sendable, Equatable {
        case text
        case number
        case flag
        /// One of a few words, offered as a menu.
        case choice([String])
        /// An action of its own, run on an outcome — a display's OK: written
        /// `ok: Copy` for its type and `ok.text: …` for its fields, and chosen
        /// in the editor like any action. The module never sees it; it names
        /// it in its outcome's `followUp`, and the host runs it.
        case action
    }

    public let key: String
    public let title: String
    public let kind: Kind
    /// A few words under or inside the field.
    public let hint: String
    /// The editor's tooltip: what the field does, what can go in it, and an
    /// example.
    public let help: String

    public init(key: String, title: String, kind: Kind = .text, hint: String = "", help: String = "") {
        self.key = key
        self.title = title
        self.kind = kind
        self.hint = hint
        self.help = help
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

/// Something for the host to put on screen, above everything, until it's
/// dismissed: text in a panel sized to fit it, perhaps with buttons.
public struct ModuleDisplay: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case markdown(String)
        /// A document of its own, shown as a web page would be.
        case html(String)
    }

    public enum Button: String, CaseIterable, Sendable {
        case ok, cancel
    }

    /// A text field under the text, for an answer — an Ask.
    public struct Field: Equatable, Sendable {
        /// What's in it to begin with, selected so typing replaces it.
        public let initial: String
        /// Grey words in it while it's empty.
        public let hint: String
        /// Several lines; ⌘Return is OK.
        public let multiline: Bool

        public init(initial: String = "", hint: String = "", multiline: Bool = false) {
            self.initial = initial
            self.hint = hint
            self.multiline = multiline
        }
    }

    /// How it went away.
    public enum Result: Equatable, Sendable {
        case ok
        /// OK, with what was typed in its field.
        case entered(String)
        /// The Cancel button, or Esc when there is one.
        case cancel
        /// Faded, closed, Esc without a Cancel button, or replaced by another.
        case dismissed
    }

    public let content: Content
    /// None: it fades by itself.
    public let buttons: [Button]
    /// Seconds before it fades, when it has no buttons.
    public let fadeAfter: TimeInterval
    /// With a field, it takes the keyboard — without taking the app in use
    /// from the front — and OK waits for something to be typed.
    public let field: Field?

    public init(content: Content, buttons: [Button] = [], fadeAfter: TimeInterval = 10, field: Field? = nil) {
        self.content = content
        self.buttons = buttons
        self.fadeAfter = fadeAfter
        self.field = field
    }
}

/// What the host offers a module.
public protocol ModuleHost: AnyObject, Sendable {
    /// Saved between runs of the app, per module: in the app, the module's
    /// part of `state.json`, which the app reads and writes for it.
    func load(_ key: String, for module: String) -> Data?
    func save(_ data: Data?, as key: String, for module: String)
    /// The folder beside the tree that its templates — and other files it
    /// names, like a `{{quote}}`'s — are found in. Nil where there's none.
    var templatesFolder: URL? { get }
    /// The module's status or values changed outside an action it was asked
    /// to run: show it.
    func statusChanged()
    /// Puts text on the clipboard.
    func copy(_ text: String)
    /// A setting from the module's part of the Settings window, or nil if the
    /// person hasn't set it.
    func setting(_ key: String, for module: String) -> String?
    /// A secret setting, from the Keychain.
    func secret(_ key: String, for module: String) -> String?
    /// Keeps a secret in the Keychain — for a module with a window of its
    /// own, like Data Sources' API keys. Nil removes it. Says why, if it
    /// couldn't.
    func setSecret(_ value: String?, _ key: String, for module: String) -> String?
    /// Shows something until it's dismissed, and says how it was. One at a
    /// time: a new one replaces the last, which is then `.dismissed`.
    func display(_ display: ModuleDisplay) async -> ModuleDisplay.Result
}

extension ModuleHost {
    public var templatesFolder: URL? { nil }
    public func setting(_ key: String, for module: String) -> String? { nil }
    public func secret(_ key: String, for module: String) -> String? { nil }
    public func setSecret(_ value: String?, _ key: String, for module: String) -> String? {
        "This host can't keep secrets"
    }
    public func display(_ display: ModuleDisplay) async -> ModuleDisplay.Result { .dismissed }
}

/// Keeps modules' state in memory only: for tools and tests, where nothing
/// needs to outlive the run.
public final class MemoryModuleHost: ModuleHost, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]
    private var folder: URL?

    public init(templatesFolder: URL? = nil) {
        folder = templatesFolder
    }

    public var templatesFolder: URL? { lock.withLock { folder } }

    /// What was shown, last first; and how the next is dismissed.
    public private(set) var displayed: [ModuleDisplay] = []
    public var displayResult: ModuleDisplay.Result = .dismissed

    public func display(_ display: ModuleDisplay) async -> ModuleDisplay.Result {
        lock.withLock {
            displayed.insert(display, at: 0)
            return displayResult
        }
    }

    public func load(_ key: String, for module: String) -> Data? {
        lock.withLock { stored["\(module).\(key)"] }
    }

    public func save(_ data: Data?, as key: String, for module: String) {
        lock.withLock { stored["\(module).\(key)"] = data }
    }

    public func statusChanged() {}

    /// What was copied, last first: nothing touches the real clipboard.
    public private(set) var copied: [String] = []

    public func copy(_ text: String) {
        lock.withLock { copied.insert(text, at: 0) }
    }

    private var settings: [String: String] = [:]

    public func setting(_ key: String, for module: String) -> String? {
        lock.withLock { settings["\(module).\(key)"] }
    }

    public func secret(_ key: String, for module: String) -> String? {
        lock.withLock { settings["\(module).secret.\(key)"] }
    }

    /// For tests: as though set in the Settings window.
    public func set(_ value: String?, for key: String, of module: String, secret: Bool = false) {
        lock.withLock { settings[secret ? "\(module).secret.\(key)" : "\(module).\(key)"] = value }
    }

    public func setSecret(_ value: String?, _ key: String, for module: String) -> String? {
        set(value, for: key, of: module, secret: true)
        return nil
    }
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

    /// The module that replies to `{{#name}}` blocks.
    public func module(handlingBlock name: String) -> KeybowModule? {
        all.first { $0.manifest.blocks.contains { $0.name == name } }
    }

    /// What a block shows in previews, whether or not anything handles it.
    public func standIn(for call: TemplateBlockCall) -> String {
        module(handlingBlock: call.name)?.standIn(for: call) ?? "‹\(call.name)›"
    }

    /// The module that fetches a value: `api.weather` → the one fetching
    /// "api"; `quote file="q.md"` → the one fetching "quote".
    public func module(fetching name: String) -> KeybowModule? {
        let prefix = String(name.prefix { $0 != "." && !$0.isWhitespace })
        return all.first { $0.manifest.fetches.contains(prefix) }
    }

    /// The names among these that some module fetches.
    public func fetchedNames(in names: Set<String>) -> [String] {
        names.filter { module(fetching: $0) != nil }.sorted()
    }

    /// What those names need first, from the modules that fetch them — and
    /// what those need in turn, when they're fetched too.
    public func valuesNeeded(toFetch names: [String]) -> Set<String> {
        var needed = Set<String>()
        var seen = Set(names)
        var frontier = names
        while !frontier.isEmpty {
            var next: [String] = []
            for (module, group) in grouped(frontier) {
                for name in module.valuesNeeded(toFetch: group) where needed.insert(name).inserted {
                    if self.module(fetching: name) != nil, seen.insert(name).inserted { next.append(name) }
                }
            }
            frontier = next
        }
        return needed
    }

    /// Everything fetching these involves, in the order it's fetched: each
    /// round needs only what came before. A name already in `params` isn't
    /// fetched — the tree's own values win — so a node can set
    /// `location.latitude` for a place of its own.
    public func fetchRounds(_ names: [String], given params: [String: String] = [:]) throws -> [[String]] {
        var remaining = Set(names).union(valuesNeeded(toFetch: names).filter { module(fetching: $0) != nil })
        remaining = remaining.filter { params[$0] == nil && module(fetching: $0) != nil }
        var rounds: [[String]] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { name in
                module(fetching: name).map { $0.valuesNeeded(toFetch: [name]).isDisjoint(with: remaining) } ?? false
            }
            guard !ready.isEmpty else {
                throw ModuleError("These values each need another to be fetched first",
                                  remaining.sorted().map { "{{\($0)}}" }.joined(separator: ", "))
            }
            rounds.append(ready.sorted())
            remaining.subtract(ready)
        }
        return rounds
    }

    /// "your location and weather", for the overlay's "Fetching …".
    public func fetchSubject(for names: [String], given params: [String: String] = [:]) -> String {
        let ordered = ((try? fetchRounds(names, given: params)) ?? [names]).flatMap { $0 }
        var subjects: [String] = []
        for (module, group) in grouped(ordered) {
            let subject = module.fetchSubject(for: group)
            if !subjects.contains(subject) { subjects.append(subject) }
        }
        switch subjects.count {
        case 0: return "values"
        case 1: return subjects[0]
        default: return subjects.dropLast().joined(separator: ", ") + " and " + subjects.last!
        }
    }

    /// Fetches them, and whatever they need that's fetched too — a round at a
    /// time, each module's names in a round at once, the modules side by
    /// side. Each round's values are there for the next: a data source's URL
    /// gets `{{location.latitude}}`. Returns every value fetched.
    public func fetch(_ names: [String], params: [String: String], now: Date) async throws -> [String: String] {
        var params = params
        var values: [String: String] = [:]
        for round in try fetchRounds(names, given: params) {
            let groups = grouped(round)
            let given = params
            let fetched = try await withThrowingTaskGroup(of: [String: String].self) { group in
                for (module, names) in groups {
                    group.addTask { try await module.fetch(names, params: given, now: now) }
                }
                var fetched: [String: String] = [:]
                for try await result in group { fetched.merge(result) { first, _ in first } }
                return fetched
            }
            values.merge(fetched) { first, _ in first }
            params.merge(fetched) { _, new in new }
        }
        return values
    }

    public func standIn(forValue name: String) -> String {
        module(fetching: name)?.standIn(forValue: name) ?? "‹\(name)›"
    }

    private func grouped(_ names: [String]) -> [(KeybowModule, [String])] {
        var groups: [(KeybowModule, [String])] = []
        for name in names {
            guard let module = module(fetching: name) else { continue }
            if let index = groups.firstIndex(where: { $0.0 === module }) {
                groups[index].1.append(name)
            } else {
                groups.append((module, [name]))
            }
        }
        return groups
    }

    /// Works out a block through the module that handles it.
    public func reply(to call: TemplateBlockCall) async throws -> String {
        guard let module = module(handlingBlock: call.name) else {
            throw ModuleError("Nothing here replies to {{#\(call.name)}} blocks")
        }
        return try await module.reply(to: call)
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
