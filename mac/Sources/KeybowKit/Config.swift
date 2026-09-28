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

    public var startRow: Int { rows[0] }
    public var levels: Int { rows.count }

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
            contacts: contacts, projects: projects, defaults: defaults
        )
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
    public func commitDelay(for selection: ResolvedSelection) -> TimeInterval {
        guard let action = selection.action else { return commitDelay }
        if case .bool(let instant)? = action.fields["instant"] { return instant ? 0 : commitDelay }
        if let module = ModuleRegistry.shared.module(handling: action.type) {
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
}

public enum ConfigError: Error, CustomStringConvertible {
    case unreadable(URL, Error)
    case malformedJSON(String)
    case tooManyNodes(at: String, count: Int)
    case keyOutOfRange(at: String, key: Int)
    case duplicateKey(at: String, key: Int)
    case tooDeep(at: String, tree: TreeKind)
    case unknownList(at: String, name: String)
    case unknownTree(String)
    case badColour(at: String, value: String)
    case defaultActionNeedsType
    case unsupportedVersion(Int)

    public var description: String {
        switch self {
        case .unreadable(let url, let error):
            return "cannot read \(url.path): \(error.localizedDescription)"
        case .malformedJSON(let detail):
            return "malformed JSON: \(detail)"
        case .tooManyNodes(let location, let count):
            return "\(location): a row holds at most 4 keys, found \(count)"
        case .keyOutOfRange(let location, let key):
            return "\(location): key \(key) is outside 0-3"
        case .duplicateKey(let location, let key):
            return "\(location): two nodes both claim key \(key)"
        case .tooDeep(let location, let tree):
            return "\(location): too deep — the \(tree.rawValue) tree has only \(tree.levels) levels"
                + " (a list that includes itself also ends up here)"
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
    /// folders that mirror the path through the tree.
    public static let builtInDefaultAction = ActionSpec(
        type: "notes.create",
        fields: [
            "folder": .string("{{folderPath}}"),
            "title": .string("{{leaf}} — {{date:d MMM yyyy}}"),
        ]
    )

    public static let builtInTypeDefaults: [String: [String: JSONValue]] = [
        // The same as the default action, so a note is filed alike whether its
        // leaf is bare or marked "(Notes)" or "new".
        "notes.create": [
            "folder": .string("{{folderPath}}"),
            "title": .string("{{leaf}} — {{date:d MMM yyyy}}"),
        ],
        "notes.append": [
            "folder": .string("{{parentPath}}"),
            "find": .object(["byName": .string("{{leaf}}")]),
            "createIfMissing": .bool(true),
        ],
        "calendar.createEvent": [
            "title": .string("{{parent}}"),
            "start": .string("{{when}}"),
            "duration": .string("+30m"),
            "show": .bool(true),
        ],
        "reminders.create": [
            "title": .string("{{leaf}}"),
        ],
        "messages.compose": [
            "to": .string("{{contact.phone}}"),
        ],
        "mail.compose": [
            "to": .string("{{contact.email}}"),
        ],
        "phone.call": [
            "to": .string("{{contact.phone}}"),
        ],
        "app.open": [
            "open": .string("{{project.path|}}"),
        ],
    ]

    public static func load(from url: URL) throws -> KeybowConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError.unreadable(url, error)
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> KeybowConfig {
        let raw: RawConfig
        do {
            raw = try JSONDecoder().decode(RawConfig.self, from: data)
        } catch {
            throw ConfigError.malformedJSON("\(error)")
        }

        let version = raw.version ?? supportedVersion
        guard version <= supportedVersion else { throw ConfigError.unsupportedVersion(version) }

        let defaults = raw.defaults ?? [:]
        let defaultColour = try colour(from: defaults["colour"]?.stringValue ?? defaults["color"]?.stringValue,
                                       at: "defaults.colour") ?? KeyColour(red: 32, green: 32, blue: 32)

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
            guard let type = fields.removeValue(forKey: "type")?.stringValue else {
                throw ConfigError.defaultActionNeedsType
            }
            defaultAction = ActionSpec(type: type, fields: fields)
        }

        // Built-in per-type defaults, with the config's own laid over the top.
        var typeDefaults = builtInTypeDefaults
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
            guard let kind = TreeKind(name: name) else { throw ConfigError.unknownTree(name) }
            rawTrees[kind] = nodes
        }

        let builder = TreeBuilder(lists: raw.lists ?? [:])
        var trees: [TreeKind: [TreeNode?]] = [:]
        for (kind, nodes) in rawTrees {
            trees[kind] = try builder.slots(from: nodes, at: kind.rawValue, tree: kind, depth: 1, inheritedColour: nil)
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
            defaults: defaults
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

    /// Places nodes into the four key positions of a row.
    func slots(from nodes: [RawNode], at location: String, tree: TreeKind, depth: Int,
               inheritedColour: KeyColour?) throws -> [TreeNode?] {
        guard nodes.count <= KeybowProtocol.columns else {
            throw ConfigError.tooManyNodes(at: location, count: nodes.count)
        }

        var placed: [TreeNode?] = Array(repeating: nil, count: KeybowProtocol.columns)
        var nextFree = 0
        for (index, raw) in nodes.enumerated() {
            let here = "\(location)[\(index)] (\"\(raw.label)\")"
            guard depth <= tree.levels else { throw ConfigError.tooDeep(at: here, tree: tree) }

            let position: Int
            if let explicit = raw.key {
                guard (0..<KeybowProtocol.columns).contains(explicit) else {
                    throw ConfigError.keyOutOfRange(at: here, key: explicit)
                }
                position = explicit
            } else {
                position = nextFree
                guard position < KeybowProtocol.columns else {
                    throw ConfigError.tooManyNodes(at: location, count: nodes.count)
                }
            }
            guard placed[position] == nil else {
                throw ConfigError.duplicateKey(at: here, key: position)
            }
            placed[position] = try node(from: raw, at: here, tree: tree, depth: depth, inheritedColour: inheritedColour)
            nextFree = max(nextFree, position + 1)
        }
        return placed
    }

    private func node(from raw: RawNode, at location: String, tree: TreeKind, depth: Int,
                      inheritedColour: KeyColour?) throws -> TreeNode {
        let colour = try KeybowConfig.colour(from: raw.colour ?? raw.color, at: "\(location).colour") ?? inheritedColour

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
            : try slots(from: childNodes, at: childLocation, tree: tree, depth: depth + 1, inheritedColour: colour)

        return TreeNode(label: raw.label, colour: colour, params: params, actionFields: action, children: children)
    }
}
