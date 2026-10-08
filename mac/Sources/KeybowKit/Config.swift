import Foundation

/// A JSON value of any shape, so action definitions can carry whatever fields
/// their type needs without KeybowKit knowing every action up front.
public enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public var stringValue: String? {
        switch self {
        case .string(let text): return text
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return String(value)
        default: return nil
        }
    }
}

extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }
}

/// An action after inheritance and defaults have been applied: ready to run.
public struct ActionSpec: Equatable, Sendable {
    public let type: String
    public let fields: [String: JSONValue]

    public init(type: String, fields: [String: JSONValue]) {
        self.type = type
        self.fields = fields
    }

    public func string(_ key: String) -> String? {
        fields[key]?.stringValue
    }

    /// An action held in one of this one's fields — a display's `ok` — or nil
    /// when there's none, or it names no type. `find.byName` inside it becomes
    /// `find: {byName}`, as it would be in an action of its own.
    public func nestedAction(_ key: String) -> ActionSpec? {
        guard case .object(let object)? = fields[key], let type = object["type"]?.stringValue, !type.isEmpty else {
            return nil
        }
        var nested: [String: JSONValue] = [:]
        for (field, value) in object where field != "type" {
            let parts = field.split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                var inner: [String: JSONValue] = [:]
                if case .object(let existing)? = nested[parts[0]] { inner = existing }
                inner[parts[1]] = value
                nested[parts[0]] = .object(inner)
            } else {
                nested[field] = value
            }
        }
        return ActionSpec(type: type, fields: nested)
    }
}

/// The four trees the keypad can hold. The first key pressed decides which one
/// is in play: each starts on a different row.
public enum TreeKind: String, CaseIterable, Sendable {
    /// Row 1 downwards: four levels.
    case main
    /// Row 2 downwards: three levels.
    case row2
    /// Row 3 downwards: two levels.
    case row3
    /// Row 4 upwards: four levels.
    case bottom

    /// Rows visited in order, zero-based from the top.
    public var rows: [Int] {
        switch self {
        case .main: return [0, 1, 2, 3]
        case .row2: return [1, 2, 3]
        case .row3: return [2, 3]
        case .bottom: return [3, 2, 1, 0]
        }
    }

    /// "main", "row 2", "row 3", "bottom": as people name it, and as
    /// scripts and agents are told it.
    public var name: String {
        switch self {
        case .main: return "main"
        case .row2: return "row 2"
        case .row3: return "row 3"
        case .bottom: return "bottom"
        }
    }

    /// "Main", "Row 2"…: the name as a title.
    public var title: String { name.prefix(1).uppercased() + name.dropFirst() }

    public var startRow: Int { rows[0] }
    public var levels: Int { rows.count }

    /// As pages: how many keys a page holds — every key on the rows below its
    /// own. The bottom tree has no rows below, so it can't have pages.
    public var pageKeys: Int { self == .bottom ? 0 : (levels - 1) * KeybowProtocol.columns }

    public var canHavePages: Bool { pageKeys > 0 }

    /// The keypad key a page's key sits on: numbered from 0, left to right,
    /// row by row down from the one under the pages.
    public func key(onPage slot: Int) -> Int {
        KeybowProtocol.key(row: startRow + 1 + slot / KeybowProtocol.columns, column: slot % KeybowProtocol.columns)
    }

    /// The page key a keypad key is, or nil when it's off the page.
    public func pageSlot(ofKey key: Int) -> Int? {
        let row = key / KeybowProtocol.columns
        guard canHavePages, row > startRow else { return nil }
        return (row - startRow - 1) * KeybowProtocol.columns + key % KeybowProtocol.columns
    }

    public static func starting(at row: Int) -> TreeKind? {
        allCases.first { $0.startRow == row }
    }

    /// Accepts the spellings people are likely to write.
    public init?(name: String) {
        let key = name.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        switch key {
        case "main", "top", "row1": self = .main
        case "row2": self = .row2
        case "row3": self = .row3
        case "bottom", "bottomup", "row4", "row4up": self = .bottom
        default: return nil
        }
    }
}

/// A node in a tree, with its children resolved into the four key positions of
/// the next row.
public final class TreeNode: @unchecked Sendable {
    public let label: String
    /// Resolved colour: the node's own, else inherited from its parent.
    public let colour: KeyColour?
    public let params: [String: String]
    /// This node's own contribution to the action, before inheritance. May be
    /// partial — a "type" alone, or fields without one — and applies to every
    /// leaf beneath it.
    public let actionFields: [String: JSONValue]?
    /// Four slots; nil where no option occupies that key.
    public let children: [TreeNode?]

    init(label: String, colour: KeyColour?, params: [String: String],
         actionFields: [String: JSONValue]?, children: [TreeNode?]) {
        self.label = label
        self.colour = colour
        self.params = params
        self.actionFields = actionFields
        self.children = children
    }

    /// A leaf is anything without children. It needs no action of its own:
    /// it inherits one, or falls back to the configured default.
    public var isLeaf: Bool { children.allSatisfy { $0 == nil } }
}

/// Settings for turning words like "tomorrow" into dates.
public struct DateRules: Equatable, Sendable {
    /// "today" with no time means this long from now.
    public var todayOffset: TimeInterval = 30 * 60
    /// …rounded up to a multiple of this.
    public var rounding: TimeInterval = 5 * 60
    /// Every other day with no time given starts at this hour and minute.
    public var defaultHour = 9
    public var defaultMinute = 0

    public init() {}
}

public struct KeybowConfig: Sendable {
    public let version: Int
    public let defaultColour: KeyColour
    public let commitDelay: TimeInterval
    public let idleTimeout: TimeInterval
    public let longPressCancel: TimeInterval
    public let dateRules: DateRules

    /// The top level of each tree; four slots, nil where unused.
    public let trees: [TreeKind: [TreeNode?]]

    /// Used for leaves that inherit no action type at all.
    public let defaultAction: ActionSpec
    /// Filled in beneath whatever a node specifies, per action type.
    public let typeDefaults: [String: [String: JSONValue]]
    /// Named people and projects. A label on the chosen path that matches a
    /// name brings that entry's fields in as `contact.*` / `project.*`.
    public let contacts: [String: [String: String]]
    public let projects: [String: [String: String]]
    /// Everything under "defaults", for actions to consult.
    public let defaults: [String: JSONValue]
    /// Keypads with trees of their own; `trees` are the first keypad's —
    /// the ones before any `# keypad` heading — which any keypad without a
    /// section of its own shares.
    public let keypads: [Keypad]

    /// A keypad's own trees, and which device they're for.
    public struct Keypad: Sendable {
        public let name: String
        /// The model it's for; nil for any.
        public let model: KeypadDevice.Model?
        /// One board's unique ID, for two keypads of the same model.
        public let id: String?
        public let trees: [TreeKind: [TreeNode?]]
        public let pages: Set<TreeKind>

        public init(name: String, model: KeypadDevice.Model?, id: String?, trees: [TreeKind: [TreeNode?]],
                    pages: Set<TreeKind> = []) {
            self.name = name
            self.model = model
            self.id = id
            self.trees = trees
            self.pages = pages
        }
    }

    /// Trees whose first row picks a page: pressing one of its keys turns the
    /// rows below into that page's keys, each running its action at once,
    /// until another page is chosen — or a row above, which goes back to
    /// choosing in the trees.
    public internal(set) var pages: Set<TreeKind> = []

    public func isPaged(_ tree: TreeKind) -> Bool {
        tree.canHavePages && pages.contains(tree)
    }

    public static let emptyRow: [TreeNode?] = [nil, nil, nil, nil]

    /// The main tree's top row.
    public var tree: [TreeNode?] { roots(.main) }

    /// The same config with some timings replaced — by the settings window,
    /// which overrides the file's values once the user moves a slider.
    public func with(commitDelay: TimeInterval? = nil, idleTimeout: TimeInterval? = nil,
                     longPressCancel: TimeInterval? = nil) -> KeybowConfig {
        KeybowConfig(
            version: version, defaultColour: defaultColour,
            commitDelay: commitDelay ?? self.commitDelay,
            idleTimeout: idleTimeout ?? self.idleTimeout,
            longPressCancel: longPressCancel ?? self.longPressCancel,
            dateRules: dateRules, trees: trees, defaultAction: defaultAction, typeDefaults: typeDefaults,
            contacts: contacts, projects: projects, defaults: defaults, keypads: keypads, pages: pages
        )
    }

    /// The same config, with a keypad's trees: 0 is the first keypad's —
    /// `trees` — and 1… those of `keypads`, in order.
    public func forKeypad(_ index: Int) -> KeybowConfig {
        guard index > 0, index <= keypads.count else { return self }
        return KeybowConfig(
            version: version, defaultColour: defaultColour, commitDelay: commitDelay, idleTimeout: idleTimeout,
            longPressCancel: longPressCancel, dateRules: dateRules, trees: keypads[index - 1].trees,
            defaultAction: defaultAction, typeDefaults: typeDefaults, contacts: contacts, projects: projects,
            defaults: defaults, keypads: keypads, pages: keypads[index - 1].pages
        )
    }

    /// Which keypad's trees a device uses: the section naming its ID, else
    /// the first naming its model and no ID — else the first keypad's.
    public func keypadIndex(for device: KeypadDevice) -> Int {
        if let index = keypads.firstIndex(where: { $0.id?.caseInsensitiveCompare(device.serial) == .orderedSame }) {
            return index + 1
        }
        if let index = keypads.firstIndex(where: { $0.id == nil && $0.model == device.model }) {
            return index + 1
        }
        // The first keypad's trees, or — when it has none, and every keypad
        // has a section — the first section's.
        let firstIsEmpty = trees.values.allSatisfy { $0.allSatisfy { $0 == nil } }
        return firstIsEmpty && !keypads.isEmpty ? 1 : 0
    }

    public func forDevice(_ device: KeypadDevice) -> KeybowConfig {
        forKeypad(keypadIndex(for: device))
    }

    public func roots(_ tree: TreeKind) -> [TreeNode?] {
        trees[tree] ?? Self.emptyRow
    }

    /// The node reached by the given key columns, or nil if the path is invalid.
    public func node(in tree: TreeKind = .main, at path: [Int]) -> TreeNode? {
        nodes(in: tree, along: path)?.last
    }

    /// The four options offered after `path`.
    public func options(in tree: TreeKind = .main, after path: [Int]) -> [TreeNode?] {
        guard !path.isEmpty else { return roots(tree) }
        return node(in: tree, at: path)?.children ?? Self.emptyRow
    }

    private func nodes(in tree: TreeKind, along path: [Int]) -> [TreeNode]? {
        var level = roots(tree)
        var found: [TreeNode] = []
        for column in path {
            guard column >= 0, column < level.count, let next = level[column] else { return nil }
            found.append(next)
            level = next.children
        }
        return found
    }

    /// Everything needed to act on a path: labels, merged parameters, and — for
    /// a leaf — the action with inheritance and defaults applied.
    public func resolve(tree: TreeKind = .main, path: [Int]) -> ResolvedSelection? {
        guard !path.isEmpty, let chain = nodes(in: tree, along: path), let node = chain.last else { return nil }
        let labels = chain.map(\.label)

        var params = computedParams(labels: labels, tree: tree)
        var explicit: [String: String] = [:]
        for step in chain {
            // Deeper nodes override shallower ones.
            explicit.merge(step.params) { _, deeper in deeper }
        }
        params.merge(entityParams(labels: labels, explicit: explicit)) { _, entity in entity }
        params.merge(explicit) { _, given in given }

        return ResolvedSelection(
            tree: tree,
            path: path,
            labels: labels,
            params: params,
            action: node.isLeaf ? effectiveAction(for: chain) : nil,
            node: node
        )
    }

    /// How long a chosen leaf waits for a press that cancels it. `instant: true`
    /// on the path skips the wait and `instant: false` keeps it; otherwise a
    /// module may ask for its action to run at once — a stopwatch has to start
    /// on the press, not a second later.
    public func commitDelay(for selection: ResolvedSelection, registry: ModuleRegistry = .shared) -> TimeInterval {
        // A page's keys are the action, pressed: there's nothing to cancel.
        if isPaged(selection.tree), selection.path.count == 2 { return 0 }
        guard let action = selection.action else { return commitDelay }
        if case .bool(let instant)? = action.fields["instant"] { return instant ? 0 : commitDelay }
        if let module = registry.module(handling: action.type) {
            let request = ModuleRequest(type: action.type, fields: action.fields.compactMapValues(\.stringValue),
                                        labels: selection.labels)
            if module.firesAtOnce(request) { return 0 }
        }
        return commitDelay
    }

    /// The action a node's leaves would get from everything down to and
    /// including it — for a branch, what its leaves inherit; for a leaf, its
    /// action. For showing, not running: `resolve` is what runs.
    public func inheritedAction(tree: TreeKind = .main, path: [Int]) -> ActionSpec? {
        guard let chain = nodes(in: tree, along: path), !chain.isEmpty else { return nil }
        return effectiveAction(for: chain)
    }

    /// Inheritance, in increasing priority:
    ///   1. per-type defaults
    ///   2. the default action, if nothing on the path named a type
    ///   3. each node's fields, shallow to deep
    /// A node naming a *different* type from the one inherited starts afresh:
    /// fields meant for another kind of action are dropped rather than leaking in.
    private func effectiveAction(for chain: [TreeNode]) -> ActionSpec {
        var type: String?
        var fields: [String: JSONValue] = [:]
        for node in chain {
            guard var own = node.actionFields else { continue }
            if let declared = own.removeValue(forKey: "type")?.stringValue {
                if let current = type, current != declared { fields = [:] }
                type = declared
            }
            fields.merge(own) { _, deeper in deeper }
        }

        var result: [String: JSONValue] = [:]
        let resolvedType: String
        if let type {
            resolvedType = type
            result = typeDefaults[type] ?? [:]
        } else {
            resolvedType = defaultAction.type
            result = typeDefaults[resolvedType] ?? [:]
            result.merge(defaultAction.fields) { _, given in given }
        }
        result.merge(fields) { _, given in given }
        return ActionSpec(type: resolvedType, fields: result)
    }

    private func computedParams(labels: [String], tree: TreeKind) -> [String: String] {
        // "/" separates folder levels, so it cannot appear inside one.
        let folderSafe = labels.map { $0.replacingOccurrences(of: "/", with: "-") }
        var params: [String: String] = [
            "leaf": labels.last ?? "",
            // A top-level leaf has no parent; it stands for itself, so an event
            // named "{{parent}}" by default gets the leaf's own label.
            "parent": labels.count > 1 ? labels[labels.count - 2] : (labels.last ?? ""),
            "path": labels.joined(separator: " / "),
            "parentPath": folderSafe.dropLast().joined(separator: "/"),
            "folderPath": folderSafe.joined(separator: "/"),
            "tree": tree.rawValue,
        ]
        for (index, label) in labels.enumerated() {
            params["level\(index + 1)"] = label
        }
        return params
    }

    /// Finds a contact and a project for the path. An explicit `contact` or
    /// `project` parameter names one directly; otherwise the deepest label on
    /// the path that matches a name wins.
    private func entityParams(labels: [String], explicit: [String: String]) -> [String: String] {
        var params: [String: String] = [:]
        for (prefix, table) in [("contact", contacts), ("project", projects)] {
            let name = explicit[prefix] ?? labels.reversed().first { table[$0] != nil }
            guard let name, let entry = table[name] else { continue }
            params["\(prefix).name"] = name
            for (key, value) in entry {
                params["\(prefix).\(key)"] = value
            }
        }
        return params
    }
}

public struct ResolvedSelection: Equatable, @unchecked Sendable {
    public let tree: TreeKind
    public let path: [Int]
    public let labels: [String]
    public let params: [String: String]
    /// Present for leaves only.
    public let action: ActionSpec?
    public let node: TreeNode

    public static func == (lhs: ResolvedSelection, rhs: ResolvedSelection) -> Bool {
        lhs.tree == rhs.tree && lhs.path == rhs.path && lhs.labels == rhs.labels
            && lhs.params == rhs.params && lhs.action == rhs.action
    }

    /// "Work / Meeting / 1:1"
    public var pathDescription: String { labels.joined(separator: " / ") }

    /// The same choice, doing something else: a display's follow-up.
    public func with(action: ActionSpec) -> ResolvedSelection {
        ResolvedSelection(tree: tree, path: path, labels: labels, params: params, action: action, node: node)
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case unreadable(URL, Error)
    case malformedJSON(String)
    case tooManyNodes(at: String, count: Int, limit: Int)
    case keyOutOfRange(at: String, key: Int, limit: Int)
    case duplicateKey(at: String, key: Int)
    case tooDeep(at: String, tree: TreeKind)
    /// Under a page's keys: they run actions, and have no keys of their own.
    case tooDeepForPage(at: String)
    /// The bottom tree has no rows below to make pages of.
    case noRoomForPages(TreeKind)
    case unknownList(at: String, name: String)
    case unknownTree(String)
    case badColour(at: String, value: String)
    case defaultActionNeedsType
    case unsupportedVersion(Int)
    /// An outline that compiles to nothing that loads.
    case doesNotCompile(String)
    /// Everything under a branch was left out, so it is too.
    case nothingLeftUnder(at: String)

    public var description: String {
        switch self {
        case .unreadable(let url, let error):
            return "cannot read \(url.path): \(error.localizedDescription)"
        case .malformedJSON(let detail):
            return "malformed JSON: \(detail)"
        case .tooManyNodes(let location, let count, let limit):
            return "\(location): \(limit == 4 ? "a row" : "a page") holds at most \(limit) keys, found \(count)"
        case .keyOutOfRange(let location, let key, let limit):
            return "\(location): key \(key) is outside 0-\(limit - 1)"
        case .duplicateKey(let location, let key):
            return "\(location): two nodes both claim key \(key)"
        case .tooDeep(let location, let tree):
            return "\(location): too deep — the \(tree.rawValue) tree has only \(tree.levels) levels"
                + " (a list that includes itself also ends up here)"
        case .tooDeepForPage(let location):
            return "\(location): a page's keys run actions, and can't have keys under them"
        case .noRoomForPages(let tree):
            return "the \(tree.rawValue) tree can't be pages: there are no rows below it"
        case .unknownList(let location, let name):
            return "\(location): no list called \"\(name)\" under \"lists\""
        case .unknownTree(let name):
            return "\"trees\" has an entry \"\(name)\"; expected main, row2, row3 or bottom"
        case .badColour(let location, let value):
            return "\(location): \"\(value)\" is not an rrggbb colour"
        case .defaultActionNeedsType:
            return "defaults.action must have a \"type\""
        case .unsupportedVersion(let version):
            return "config version \(version) is newer than this app understands"
        case .doesNotCompile(let detail):
            return "the tree doesn't compile: \(detail)"
        case .nothingLeftUnder(let location):
            return "\(location): everything under it was left out, so it is too"
        }
    }
}

// MARK: - Decoding

private struct RawConfig: Decodable {
    var version: Int?
    var defaults: [String: JSONValue]?
    var contacts: [String: [String: JSONValue]]?
    var projects: [String: [String: JSONValue]]?
    var lists: [String: [RawNode]]?
    /// Version 1 had a single tree.
    var tree: [RawNode]?
    var trees: [String: [RawNode]]?
    var pages: [String]?
    var keypads: [RawKeypad]?
}

private struct RawKeypad: Decodable {
    var name: String?
    var model: String?
    var id: String?
    var trees: [String: [RawNode]]?
    var pages: [String]?
}

private enum RawChildren: Decodable {
    case nodes([RawNode])
    /// "@name": the list of that name under "lists".
    case reference(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .reference(text.hasPrefix("@") ? String(text.dropFirst()) : text)
        } else {
            self = .nodes(try container.decode([RawNode].self))
        }
    }
}

private struct RawNode: Decodable {
    var label: String
    var colour: String?
    var color: String?          // tolerate the American spelling
    var key: Int?
    var params: [String: JSONValue]?
    var children: RawChildren?
    var action: [String: JSONValue]?
}

extension KeybowConfig {
    public static let supportedVersion = 2

    /// The action for leaves that inherit none: a new note, filed in nested
    /// folders that mirror the path through the tree. A new note's own
    /// defaults, so a note is filed alike whether its leaf is bare or marked
    /// [Notes] or [new].
    public static let builtInDefaultAction = ActionSpec(type: "notes.create", fields: BuiltInActions.notesCreate.defaults)

    public static func load(from url: URL) throws -> KeybowConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError.unreadable(url, error)
        }
        return try parse(data)
    }

    /// Strict unless `skipped` is given. Then whatever doesn't fit — a node
    /// too deep for its tree, a list that doesn't exist, two nodes on one
    /// key, a colour that isn't one — is left out, with what's wrong passed
    /// to `skipped`, and the rest loads: one mistake in a tree costs only
    /// what it touches.
    public static func parse(_ data: Data, skipped: ((String) -> Void)? = nil) throws -> KeybowConfig {
        let raw: RawConfig
        do {
            raw = try JSONDecoder().decode(RawConfig.self, from: data)
        } catch {
            throw ConfigError.malformedJSON("\(error)")
        }

        let version = raw.version ?? supportedVersion
        guard version <= supportedVersion else { throw ConfigError.unsupportedVersion(version) }

        let defaults = raw.defaults ?? [:]
        let fallbackColour = KeyColour(red: 32, green: 32, blue: 32)
        let defaultColour: KeyColour
        do {
            defaultColour = try colour(from: defaults["colour"]?.stringValue ?? defaults["color"]?.stringValue,
                                       at: "defaults.colour") ?? fallbackColour
        } catch let error as ConfigError {
            guard let skipped else { throw error }
            skipped(error.description)
            defaultColour = fallbackColour
        }

        func seconds(_ key: String, fallback: TimeInterval) -> TimeInterval {
            guard case .number(let milliseconds)? = defaults[key] else { return fallback }
            return milliseconds / 1000
        }

        var rules = DateRules()
        if case .object(let dates)? = defaults["dates"] {
            if case .number(let minutes)? = dates["todayOffsetMinutes"] { rules.todayOffset = minutes * 60 }
            if case .number(let minutes)? = dates["roundToMinutes"] { rules.rounding = minutes * 60 }
            if let time = dates["defaultTime"]?.stringValue, let parsed = DateExpression.parseClock(time) {
                rules.defaultHour = parsed.hour
                rules.defaultMinute = parsed.minute
            }
        }

        var defaultAction = builtInDefaultAction
        if case .object(var fields)? = defaults["action"] {
            if let type = fields.removeValue(forKey: "type")?.stringValue {
                defaultAction = ActionSpec(type: type, fields: fields)
            } else if let skipped {
                skipped(ConfigError.defaultActionNeedsType.description)
            } else {
                throw ConfigError.defaultActionNeedsType
            }
        }

        // Built-in per-type defaults, with the config's own laid over the top.
        var typeDefaults = BuiltInActions.defaults
        if case .object(let types)? = defaults["types"] {
            for (type, value) in types {
                guard case .object(let fields) = value else { continue }
                typeDefaults[type, default: [:]].merge(fields) { _, given in given }
            }
        }

        // Trees: the version 1 "tree" is the main tree.
        var rawTrees: [TreeKind: [RawNode]] = [:]
        if let single = raw.tree { rawTrees[.main] = single }
        for (name, nodes) in raw.trees ?? [:] {
            guard let kind = TreeKind(name: name) else {
                guard let skipped else { throw ConfigError.unknownTree(name) }
                skipped(ConfigError.unknownTree(name).description)
                continue
            }
            rawTrees[kind] = nodes
        }

        /// Trees named as pages, of those that can be.
        func pageTrees(_ names: [String]?) throws -> Set<TreeKind> {
            var found = Set<TreeKind>()
            for name in names ?? [] {
                do {
                    guard let kind = TreeKind(name: name) else { throw ConfigError.unknownTree(name) }
                    guard kind.canHavePages else { throw ConfigError.noRoomForPages(kind) }
                    found.insert(kind)
                } catch let error as ConfigError {
                    guard let skipped else { throw error }
                    skipped(error.description)
                }
            }
            return found
        }

        let builder = TreeBuilder(lists: raw.lists ?? [:], skipped: skipped)
        let pages = try pageTrees(raw.pages)
        var trees: [TreeKind: [TreeNode?]] = [:]
        for (kind, nodes) in rawTrees {
            trees[kind] = try builder.slots(from: nodes, at: kind.rawValue, tree: kind, depth: 1, inheritedColour: nil,
                                            paged: pages.contains(kind))
        }

        return KeybowConfig(
            version: version,
            defaultColour: defaultColour,
            commitDelay: seconds("commitDelayMs", fallback: 1.0),
            idleTimeout: seconds("idleTimeoutMs", fallback: 10.0),
            longPressCancel: seconds("longPressCancelMs", fallback: 1.5),
            dateRules: rules,
            trees: trees,
            defaultAction: defaultAction,
            typeDefaults: typeDefaults,
            contacts: stringTable(raw.contacts),
            projects: stringTable(raw.projects),
            defaults: defaults,
            keypads: try (raw.keypads ?? []).enumerated().map { index, keypad in
                let keypadPages = try pageTrees(keypad.pages)
                var keypadTrees: [TreeKind: [TreeNode?]] = [:]
                for (name, nodes) in keypad.trees ?? [:] {
                    guard let kind = TreeKind(name: name) else {
                        guard let skipped else { throw ConfigError.unknownTree(name) }
                        skipped(ConfigError.unknownTree(name).description)
                        continue
                    }
                    keypadTrees[kind] = try builder.slots(from: nodes, at: "keypads[\(index)].\(kind.rawValue)", tree: kind,
                                                          depth: 1, inheritedColour: nil, paged: keypadPages.contains(kind))
                }
                return Keypad(name: keypad.name ?? "Keypad \(index + 2)", model: keypad.model.flatMap(KeypadDevice.Model.init(words:)),
                              id: keypad.id, trees: keypadTrees, pages: keypadPages)
            },
            pages: pages
        )
    }

    private static func stringTable(_ raw: [String: [String: JSONValue]]?) -> [String: [String: String]] {
        (raw ?? [:]).mapValues { entry in entry.compactMapValues(\.stringValue) }
    }

    fileprivate static func colour(from text: String?, at location: String) throws -> KeyColour? {
        guard let text else { return nil }
        guard let parsed = KeyColour(hex: text) else {
            throw ConfigError.badColour(at: location, value: text)
        }
        return parsed
    }
}

/// Builds validated trees from the raw JSON, expanding list references.
private struct TreeBuilder {
    let lists: [String: [RawNode]]
    /// Given, a node that doesn't fit is left out and reported here.
    let skipped: ((String) -> Void)?

    /// Places nodes into the four key positions of a row — or, under a page,
    /// into every key on the rows below it.
    func slots(from nodes: [RawNode], at location: String, tree: TreeKind, depth: Int,
               inheritedColour: KeyColour?, paged: Bool = false) throws -> [TreeNode?] {
        let width = paged && depth == 2 ? tree.pageKeys : KeybowProtocol.columns
        guard nodes.count <= width || skipped != nil else {
            throw ConfigError.tooManyNodes(at: location, count: nodes.count, limit: width)
        }

        var placed: [TreeNode?] = Array(repeating: nil, count: width)
        var nextFree = 0
        for (index, raw) in nodes.enumerated() {
            let here = "\(location)[\(index)] (\"\(raw.label)\")"
            do {
                if paged, depth > 2 { throw ConfigError.tooDeepForPage(at: here) }
                guard depth <= tree.levels else { throw ConfigError.tooDeep(at: here, tree: tree) }

                let position: Int
                if let explicit = raw.key {
                    guard (0..<width).contains(explicit) else {
                        throw ConfigError.keyOutOfRange(at: here, key: explicit, limit: width)
                    }
                    position = explicit
                } else {
                    position = nextFree
                    guard position < width else {
                        throw ConfigError.tooManyNodes(at: location, count: nodes.count, limit: width)
                    }
                }
                guard placed[position] == nil else {
                    throw ConfigError.duplicateKey(at: here, key: position)
                }
                placed[position] = try node(from: raw, at: here, tree: tree, depth: depth, inheritedColour: inheritedColour,
                                            paged: paged)
                nextFree = max(nextFree, position + 1)
            } catch let error as ConfigError {
                // Leave this node, and what's under it, out; keep the rest.
                guard let skipped else { throw error }
                skipped(error.description)
            }
        }
        return placed
    }

    private func node(from raw: RawNode, at location: String, tree: TreeKind, depth: Int,
                      inheritedColour: KeyColour?, paged: Bool) throws -> TreeNode {
        var colour = inheritedColour
        do {
            colour = try KeybowConfig.colour(from: raw.colour ?? raw.color, at: "\(location).colour") ?? inheritedColour
        } catch let error as ConfigError {
            // A bad colour costs the colour, not the node.
            guard let skipped else { throw error }
            skipped(error.description)
        }

        var childNodes: [RawNode] = []
        var childLocation = "\(location).children"
        switch raw.children {
        case .nodes(let nodes)?:
            childNodes = nodes
        case .reference(let name)?:
            guard let list = lists[name] else { throw ConfigError.unknownList(at: location, name: name) }
            childNodes = list
            childLocation = "\(location) → @\(name)"
        case nil:
            break
        }

        var params: [String: String] = [:]
        for (key, value) in raw.params ?? [:] {
            if let text = value.stringValue { params[key] = text }
        }

        let action = (raw.action?.isEmpty ?? true) ? nil : raw.action
        let children = childNodes.isEmpty
            ? KeybowConfig.emptyRow
            : try slots(from: childNodes, at: childLocation, tree: tree, depth: depth + 1, inheritedColour: colour,
                        paged: paged)
        // Still a branch, not a leaf with an action it was never meant to run.
        if !childNodes.isEmpty, children.allSatisfy({ $0 == nil }) {
            throw ConfigError.nothingLeftUnder(at: location)
        }

        return TreeNode(label: raw.label, colour: colour, params: params, actionFields: action, children: children)
    }
}
