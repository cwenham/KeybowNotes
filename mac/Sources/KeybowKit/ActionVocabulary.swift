import Foundation

/// What the outline language knows of actions: every type — those built in,
/// then each module's — by name and keyword, with its fields. A snapshot of a
/// registry's modules, handed to what reads the outline — the compiler, the
/// editor — so it reads one consistent picture rather than reaching for the
/// modules as it goes.
public struct ActionVocabulary: Sendable {
    /// Those built in, then each module's.
    public let types: [ModuleActionType]
    /// Every field any action takes.
    public let fields: [ModuleField]
    private let byType: [String: ModuleActionType]
    /// Lowercased keyword → type.
    private let byKeyword: [String: String]
    private let fieldKeys: Set<String>
    /// Fields that hold an action of their own: a display's `ok`.
    private let holders: Set<String>

    /// The built-in types, and these from modules. A module's type or keyword
    /// can't take one that's built in, or another module's before it.
    public init(modules: [ModuleActionType] = []) {
        types = BuiltInActions.types + modules
        fields = types.flatMap(\.fields)
        var byType: [String: ModuleActionType] = [:]
        var byKeyword: [String: String] = [:]
        for type in types {
            if byType[type.type] == nil { byType[type.type] = type }
            for word in type.keywords where byKeyword[word.lowercased()] == nil { byKeyword[word.lowercased()] = type.type }
        }
        self.byType = byType
        self.byKeyword = byKeyword
        fieldKeys = Set(fields.map(\.key)).union(["type", "instant"])
        holders = Set(fields.filter { $0.kind == .action }.map(\.key))
    }

    /// A type, built in or a module's.
    public func describe(_ type: String) -> ModuleActionType? { byType[type] }

    /// Every keyword, lowercased.
    public var keywords: Set<String> { Set(byKeyword.keys) }

    /// The type a keyword names: `Copy` → clipboard.copy.
    public func type(forKeyword word: String) -> String? {
        byKeyword[word.lowercased()]
    }

    /// A type, from a keyword or its full name. Nil for one nothing here runs.
    public func knownType(_ word: String) -> String? {
        let text = word.trimmingCharacters(in: .whitespaces)
        if let type = type(forKeyword: text) { return type }
        return byType[text] != nil ? text : nil
    }

    /// The keyword a type is written with; those without one are written
    /// `type: …`.
    public func keyword(for type: String) -> String? {
        byType[type]?.keywords.first
    }

    /// An action's field — every action's `type` and `instant` too — or a
    /// field of an action held in one: `ok.text`.
    public func isActionField(_ key: String) -> Bool {
        fieldKeys.contains(key) || heldField(key) != nil
    }

    /// True for a field that holds an action of its own: a display's `ok`.
    public func holdsAction(_ key: String) -> Bool {
        holders.contains(key)
    }

    /// `ok.text` → ("ok", "text"), when `ok` holds an action.
    public func heldField(_ key: String) -> (holder: String, field: String)? {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, holdsAction(parts[0]) else { return nil }
        return (parts[0], parts[1])
    }

    /// Whether a field takes a number, for an action of `type` — or, with no
    /// type known, for any action. A name means different things to different
    /// actions: an event's `show` is yes or no, Exposé's is what to show.
    public func isNumericField(_ key: String, type: String?) -> Bool {
        isField(key, type: type, kind: .number)
    }

    /// `instant` is every action's.
    public func isBooleanField(_ key: String, type: String?) -> Bool {
        key == "instant" || isField(key, type: type, kind: .flag)
    }

    private func isField(_ key: String, type: String?, kind: ModuleField.Kind) -> Bool {
        let fields = type.map { describe($0)?.fields ?? [] } ?? fields
        return fields.contains { $0.key == key && $0.kind == kind }
    }
}
