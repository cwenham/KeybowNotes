import Foundation

/// Completion inside an outline line's brackets: where the caret is — an
/// item, a pair's value, or a {{value}} in one — what's been typed of it,
/// and what could finish it. The line may be half typed, its `]` not yet
/// there.
public struct OutlineCompletion: Equatable, Sendable {
    public enum Slot: Equatable, Sendable {
        /// An item: an action's keyword, a field's key, a list, a template,
        /// an app.
        case item
        /// A pair's value, after `key:`.
        case value(key: String)
        /// A {{value}} in a pair's value — or a block's name, after `{{#`.
        case placeholder(block: Bool)
    }

    public let slot: Slot
    /// What's been typed of it, in the line: what a completion replaces.
    public let range: NSRange
    public let partial: String
    /// The other items in the brackets, for offering what isn't there yet.
    public let others: [Annotation]

    /// Where the caret is in a line — nil when it isn't in its brackets.
    public static func at(_ caret: Int, in line: String) -> OutlineCompletion? {
        let text = line as NSString
        guard caret <= text.length, let (items, current) = itemsAround(caret, in: text) else { return nil }
        let others = items.filter { $0 != current }.map { Annotation(parsing: text.substring(with: $0)) }
        let typed = text.substring(with: NSRange(location: current.location, length: caret - current.location))
        let lead = typed.prefix { $0 == " " }.utf16.count

        // A pair, when what's before a colon is a key: its value's being typed.
        if let colon = typed.firstIndex(of: ":"),
           Annotation.isKey(typed[..<colon].trimmingCharacters(in: .whitespaces)) {
            let key = typed[..<colon].trimmingCharacters(in: .whitespaces)
            var start = current.location + typed[...colon].utf16.count
            while start < caret, text.character(at: start) == 32 { start += 1 }
            if start < caret, text.character(at: start) == 34 { start += 1 }       // an opening "
            let value = text.substring(with: NSRange(location: start, length: caret - start))
            if let tag = TemplateSyntax.partialName(in: value, at: (value as NSString).length) {
                let range = NSRange(location: start + tag.range.location, length: tag.range.length)
                return OutlineCompletion(slot: .placeholder(block: tag.block), range: range,
                                         partial: text.substring(with: range), others: others)
            }
            // Free text runs on past spaces; what's offered for a key is a word.
            guard !value.contains("{{") else { return nil }
            return OutlineCompletion(slot: .value(key: key), range: NSRange(location: start, length: caret - start),
                                     partial: value, others: others)
        }
        let range = NSRange(location: current.location + lead, length: caret - current.location - lead)
        return OutlineCompletion(slot: .item, range: range, partial: text.substring(with: range), others: others)
    }

    /// The items of the bracket group the caret is in, as the outline splits
    /// them — on commas outside quotes — and the one it's in.
    private static func itemsAround(_ caret: Int, in text: NSString) -> ([NSRange], NSRange)? {
        var open: Int?
        var start = 0
        var items: [NSRange] = []
        var inQuotes = false
        var index = 0
        func found() -> ([NSRange], NSRange)? {
            guard let open, caret > open else { return nil }
            return items.first { $0.location <= caret && caret <= NSMaxRange($0) }.map { (items, $0) }
        }
        while index < text.length {
            let character = text.character(at: index)
            if open == nil {
                if character == 91 { open = index; start = index + 1; items = []; inQuotes = false }      // [
            } else if character == 92 {                                                                   // \
                index += 2
                continue
            } else if character == 34 {                                                                   // "
                inQuotes.toggle()
            } else if character == 44, !inQuotes {                                                        // ,
                items.append(NSRange(location: start, length: index - start))
                start = index + 1
            } else if character == 93, !inQuotes {                                                        // ]
                items.append(NSRange(location: start, length: index - start))
                if let result = found() { return result }
                open = nil
            }
            index += 1
        }
        guard open != nil else { return nil }
        items.append(NSRange(location: start, length: text.length - start))
        return found()
    }
}

/// What completion in the outline offers from: the language, and what's
/// in this tree and on this Mac.
public struct OutlineCompletionSources: Sendable {
    public var vocabulary: ActionVocabulary
    /// The type the node takes from above, if it names none itself.
    public var inheritedType: String?
    public var lists: [String]
    /// Files in the templates folder, by the names actions give them.
    public var templates: [String]
    public var apps: [String]
    /// Names nodes elsewhere give values: `when`, `area`.
    public var valueKeys: [String]
    /// The {{values}} for the key.
    public var values: ValueCatalog

    public init(vocabulary: ActionVocabulary, inheritedType: String? = nil, lists: [String] = [],
                templates: [String] = [], apps: [String] = [], valueKeys: [String] = [],
                values: ValueCatalog = ValueCatalog(modules: [])) {
        self.vocabulary = vocabulary
        self.inheritedType = inheritedType
        self.lists = lists
        self.templates = templates
        self.apps = apps
        self.valueKeys = valueKeys
        self.values = values
    }
}

extension OutlineCompletion {
    /// What could finish what's being typed, best first: a key is offered
    /// with its `: `, a list with its `@`.
    public func candidates(_ sources: OutlineCompletionSources) -> [String] {
        let vocabulary = sources.vocabulary
        // The node's own type: a keyword, an app, or `type:`.
        let own: String? = others.lazy.compactMap { annotation -> String? in
            switch annotation {
            case .word(let word): return vocabulary.type(forKeyword: word)
                ?? (sources.apps.contains(word) ? "app.open" : nil)
            case .pair("type", let value): return vocabulary.knownType(value)
            default: return nil
            }
        }.first
        let type = own ?? sources.inheritedType
        let fields = type.flatMap(vocabulary.describe)?.fields ?? []
        let present = Set(others.compactMap(\.key))

        var offered: [String]
        switch slot {
        case .placeholder(let block):
            return sources.values.completions(for: partial, block: block)
        case .value(let key):
            switch fields.first(where: { $0.key == key })?.kind {
            case .choice(let words)?: offered = words
            case .flag?: offered = ["true", "false"]
            case .action?: offered = vocabulary.types.compactMap { vocabulary.keyword(for: $0.type) }
            default:
                switch key {
                case "type": offered = vocabulary.types.map(\.type)
                case "instant": offered = ["true", "false"]
                case "template": offered = sources.templates
                case "app": offered = sources.apps
                default: offered = []
                }
            }
        case .item:
            if partial.hasPrefix("@") {
                offered = sources.lists.map { "@" + $0 }
                break
            }
            let keys = (fields.map(\.key) + ["colour", "instant"] + (own == nil ? ["type"] : []) + sources.valueKeys)
                .filter { !present.contains($0) }.map { $0 + ": " }
            // Each type's own word first, then the others it answers to.
            let keywords = own == nil ? vocabulary.types.compactMap(\.keywords.first)
                + vocabulary.types.flatMap { $0.keywords.dropFirst() } : []
            let templates = sources.templates.filter { $0.lowercased().hasSuffix(".md") }
            // Apps only once something's typed: there are hundreds.
            let apps = own == nil && !partial.isEmpty ? sources.apps : []
            offered = keywords + keys + sources.lists.map { "@" + $0 } + templates + apps
        }
        var seen = Set<String>()
        let typed = partial.lowercased()
        return offered.filter { $0.lowercased().hasPrefix(typed) && $0.lowercased() != typed && seen.insert($0.lowercased()).inserted }
    }
}

extension OutlineDocument {
    /// The names nodes give values — `when: tomorrow` — anywhere in the
    /// outline, in order of first use: not action fields, nor colours.
    public func valueKeys(vocabulary: ActionVocabulary) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        var pending: [OutlineNode] = []
        for keypad in 0..<keypadCount {
            for tree in TreeKind.allCases { pending += roots(tree, keypad: keypad).compactMap { $0 } }
        }
        pending += lists.flatMap { $0.nodes.compactMap { $0 } }
        pending.reverse()
        while let node = pending.popLast() {
            for case .pair(let key, _) in node.annotations
            where !vocabulary.isActionField(key) && key != "colour" && key != "color" && seen.insert(key).inserted {
                keys.append(key)
            }
            pending += (node.children.compactMap { $0 } + node.steps).reversed()
        }
        return keys
    }
}
