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

public struct ActionSpec: Equatable, Sendable {
    public let type: String
    public let fields: [String: JSONValue]

    public func string(_ key: String) -> String? {
        fields[key]?.stringValue
    }
}

/// A node in the category tree, with its children resolved into the four key
/// positions of the row below.
public final class TreeNode: @unchecked Sendable {
    public let label: String
    public let colour: KeyColour?
    public let params: [String: String]
    public let action: ActionSpec?
    /// Four slots; nil where no option occupies that key.
    public let children: [TreeNode?]

    init(label: String, colour: KeyColour?, params: [String: String], action: ActionSpec?, children: [TreeNode?]) {
        self.label = label
        self.colour = colour
        self.params = params
        self.action = action
        self.children = children
    }

    public var isLeaf: Bool { action != nil }
}

public struct KeybowConfig: Sendable {
    public let version: Int
    public let defaultColour: KeyColour
    public let commitDelay: TimeInterval
    public let idleTimeout: TimeInterval
    public let longPressCancel: TimeInterval
    /// Top row; four slots, nil where unused.
    public let tree: [TreeNode?]
    /// Everything under "defaults", for actions to consult.
    public let defaults: [String: JSONValue]

    /// The node reached by the given key columns, or nil if the path is invalid.
    public func node(at path: [Int]) -> TreeNode? {
        var level = tree
        var current: TreeNode?
        for column in path {
            guard column >= 0, column < level.count, let next = level[column] else { return nil }
            current = next
            level = next.children
        }
        return current
    }

    /// The four options offered at the given depth, following `path`.
    public func options(after path: [Int]) -> [TreeNode?] {
        guard !path.isEmpty else { return tree }
        return node(at: path)?.children ?? [nil, nil, nil, nil]
    }

    /// Labels and merged parameters along a path, for template expansion.
    public func resolve(path: [Int]) -> ResolvedSelection? {
        var labels: [String] = []
        var params: [String: String] = [:]
        var level = tree
        var node: TreeNode?
        for column in path {
            guard column >= 0, column < level.count, let next = level[column] else { return nil }
            labels.append(next.label)
            // Deeper nodes override shallower ones.
            params.merge(next.params) { _, deeper in deeper }
            node = next
            level = next.children
        }
        guard let node else { return nil }
        return ResolvedSelection(path: path, labels: labels, params: params, action: node.action, node: node)
    }
}

public struct ResolvedSelection: Equatable, @unchecked Sendable {
    public let path: [Int]
    public let labels: [String]
    public let params: [String: String]
    public let action: ActionSpec?
    public let node: TreeNode

    public static func == (lhs: ResolvedSelection, rhs: ResolvedSelection) -> Bool {
        lhs.path == rhs.path && lhs.labels == rhs.labels && lhs.params == rhs.params && lhs.action == rhs.action
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
    case bothChildrenAndAction(at: String)
    case neitherChildrenNorAction(at: String)
    case badColour(at: String, value: String)
    case missingActionType(at: String)
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
        case .bothChildrenAndAction(let location):
            return "\(location): has both children and an action; it must have one or the other"
        case .neitherChildrenNorAction(let location):
            return "\(location): has neither children nor an action"
        case .badColour(let location, let value):
            return "\(location): \"\(value)\" is not an rrggbb colour"
        case .missingActionType(let location):
            return "\(location): the action has no \"type\""
        case .unsupportedVersion(let version):
            return "config version \(version) is newer than this app understands"
        }
    }
}

// MARK: - Decoding

private struct RawConfig: Decodable {
    var version: Int?
    var defaults: [String: JSONValue]?
    var tree: [RawNode]
}

private struct RawNode: Decodable {
    var label: String
    var colour: String?
    var color: String?          // tolerate the American spelling
    var key: Int?
    var params: [String: JSONValue]?
    var children: [RawNode]?
    var action: [String: JSONValue]?
}

extension KeybowConfig {
    public static let supportedVersion = 1

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

        return KeybowConfig(
            version: version,
            defaultColour: defaultColour,
            commitDelay: seconds("commitDelayMs", fallback: 1.0),
            idleTimeout: seconds("idleTimeoutMs", fallback: 10.0),
            longPressCancel: seconds("longPressCancelMs", fallback: 1.5),
            tree: try slots(from: raw.tree, at: "tree"),
            defaults: defaults
        )
    }

    private static func colour(from text: String?, at location: String) throws -> KeyColour? {
        guard let text else { return nil }
        guard let parsed = KeyColour(hex: text) else {
            throw ConfigError.badColour(at: location, value: text)
        }
        return parsed
    }

    /// Places nodes into the four key positions of a row.
    private static func slots(from nodes: [RawNode], at location: String) throws -> [TreeNode?] {
        guard nodes.count <= KeybowProtocol.columns else {
            throw ConfigError.tooManyNodes(at: location, count: nodes.count)
        }

        var placed: [TreeNode?] = Array(repeating: nil, count: KeybowProtocol.columns)
        var nextFree = 0
        for (index, raw) in nodes.enumerated() {
            let here = "\(location)[\(index)] (\"\(raw.label)\")"
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
            placed[position] = try node(from: raw, at: here)
            nextFree = max(nextFree, position + 1)
        }
        return placed
    }

    private static func node(from raw: RawNode, at location: String) throws -> TreeNode {
        let hasChildren = !(raw.children ?? []).isEmpty
        let hasAction = !(raw.action ?? [:]).isEmpty
        if hasChildren && hasAction { throw ConfigError.bothChildrenAndAction(at: location) }
        if !hasChildren && !hasAction { throw ConfigError.neitherChildrenNorAction(at: location) }

        var action: ActionSpec?
        if var fields = raw.action, hasAction {
            guard let type = fields["type"]?.stringValue else {
                throw ConfigError.missingActionType(at: location)
            }
            fields.removeValue(forKey: "type")
            action = ActionSpec(type: type, fields: fields)
        }

        var params: [String: String] = [:]
        for (key, value) in raw.params ?? [:] {
            if let text = value.stringValue { params[key] = text }
        }

        return TreeNode(
            label: raw.label,
            colour: try colour(from: raw.colour ?? raw.color, at: "\(location).colour"),
            params: params,
            action: action,
            children: hasChildren ? try slots(from: raw.children ?? [], at: "\(location).children") : [nil, nil, nil, nil]
        )
    }
}
