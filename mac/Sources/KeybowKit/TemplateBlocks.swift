import Foundation

// Blocks: `{{#name attr="value"}} … {{/name}}`. The text between is filled in
// first — its placeholders, and any blocks inside it — and then handed to
// whatever handles the block (a module), whose reply takes the block's place.
// The reply is plain text: it is never read as a template itself.
//
//   {{#ai model="opus-5.5"}}Summarise in one line: {{selection}}{{/ai}}
//
// Blocks nest to any depth. Nothing here recurses: a template is parsed into a
// flat list of nodes, each block's contents always after it, so one pass from
// the end works everything out innermost first.

/// One block, ready to be worked out: its name, its attributes, and the text
/// between its tags with everything inside it filled in. Two blocks with the
/// same call get the same reply, so each is asked for once.
public struct TemplateBlockCall: Hashable, Sendable, CustomStringConvertible {
    public let name: String
    public let attributes: [String: String]
    public let body: String

    public init(name: String, attributes: [String: String] = [:], body: String) {
        self.name = name
        self.attributes = attributes
        self.body = body
    }

    public var description: String { "{{#\(name)}}" }
}

/// A template, parsed.
struct TemplateDocument {
    enum Kind {
        case root
        case text(Substring)
        /// What's between the braces: `contact.phone|none`.
        case placeholder(String)
        case block(name: String, attributes: [String: String])
        /// `{{#each clipboard}}`: its contents filled in once for each row.
        case list(TemplateList)
        /// `{{#header}}`, `{{#footer}}`, `{{#empty}}`: a part of the list it's in.
        case section(TemplateList.Section)
    }

    struct Node {
        var kind: Kind
        var children: [Int] = []
        /// Where its tag is in the text: a block's opening tag.
        var tag: Range<String.Index>?
        /// A block's closing tag.
        var closing: Range<String.Index>?
    }

    /// Node 0 is the whole template. A node's children always come after it.
    private(set) var nodes: [Node] = [Node(kind: .root)]
    /// Blocks never closed, closing tags that close nothing, unreadable
    /// attributes. Shown to the person; a template with any isn't run.
    private(set) var problems: [String] = []
    /// Where each of the problems is, in the same order.
    private(set) var problemPlaces: [Range<String.Index>] = []

    init(_ text: String) {
        var open = [0]                                  // blocks not yet closed, innermost last
        var rest = Substring(text)

        func add(_ kind: Kind, at tag: Range<String.Index>? = nil) -> Int {
            nodes.append(Node(kind: kind, tag: tag))
            let index = nodes.count - 1
            nodes[open[open.count - 1]].children.append(index)
            return index
        }
        func problem(_ message: String, at place: Range<String.Index>) {
            problems.append(message)
            problemPlaces.append(place)
        }

        /// The name of what's open: a block's, `each`, a section's.
        func openName(_ node: Node) -> String? {
            switch node.kind {
            case .block(let name, _): return name
            case .list: return TemplateList.tagName
            case .section(let section): return section.rawValue
            default: return nil
            }
        }

        while let start = rest.range(of: "{{") {
            let inside = rest[start.upperBound...]
            let opensBlock = inside.first == "#"
            let isOperator = !opensBlock && Self.isOperator(inside)
            guard let end = Self.tagEnd(in: inside, quoted: opensBlock || isOperator, nested: opensBlock || isOperator) else {
                // An unclosed brace is left as written — but a tag with
                // attributes that never ends is surely a mistake, like a stray quote.
                if opensBlock {
                    let name = inside.dropFirst().prefix { !$0.isWhitespace && $0 != "}" }
                    problem("“{{#\(name)” has no closing }} — check its quotes.", at: start.lowerBound..<rest.endIndex)
                } else if isOperator {
                    let name = inside.drop { $0 == " " }.prefix { !$0.isWhitespace }
                    problem("“{{\(name)” has no closing }} — check its quotes.", at: start.lowerBound..<rest.endIndex)
                }
                _ = add(.text(rest))
                rest = ""
                break
            }
            let tag = rest[start.lowerBound..<end.upperBound]
            let body = inside[..<end.lowerBound]
            var before = rest[..<start.lowerBound]
            rest = inside[end.upperBound...]
            // A list's tag alone on its line takes the line with it, so a
            // list written over several lines adds no lines of its own.
            if Self.isListTag(body), let line = Self.lineAlone(tag, in: text) {
                before = before[..<max(line.lowerBound, before.startIndex)]
                rest = text[line.upperBound...]
            }
            if !before.isEmpty { _ = add(.text(before)) }

            let place = tag.startIndex..<tag.endIndex
            if opensBlock {
                let name = body.dropFirst().drop { $0 == " " }.prefix { !$0.isWhitespace }
                if name == TemplateList.tagName {
                    switch TemplateList.opening(body.dropFirst()) {
                    case .success(let list):
                        open.append(add(.list(list), at: place))
                    case .failure(let failure):
                        // Still open, with nothing to go through, so its
                        // {{/each}} has something to close.
                        problem(failure.message, at: place)
                        open.append(add(.list(TemplateList(source: "", attributes: [:])), at: place))
                    }
                } else if let section = TemplateList.Section(rawValue: String(name)) {
                    let list = open[open.count - 1]
                    guard case .list = nodes[list].kind else {
                        problem("“{{#\(name)}}” goes inside {{#each}}…{{/each}}.", at: place)
                        _ = add(.text(tag))
                        continue
                    }
                    if nodes[list].children.contains(where: { child in
                        if case .section(section) = nodes[child].kind { return true }
                        return false
                    }) {
                        problem("“{{#each}}” has two {{#\(name)}}s.", at: place)
                    }
                    open.append(add(.section(section), at: place))
                } else {
                    switch Self.opening(body.dropFirst()) {
                    case .success(let (name, attributes)):
                        open.append(add(.block(name: name, attributes: attributes), at: place))
                    case .failure(let failure):
                        problem(failure.message, at: place)
                        _ = add(.text(tag))
                    }
                }
            } else if body.first == "/" {
                let name = body.dropFirst().trimmingCharacters(in: .whitespaces)
                if open.count > 1, openName(nodes[open[open.count - 1]]) == name {
                    nodes[open.removeLast()].closing = place
                } else {
                    if open.count > 1, let innermost = openName(nodes[open[open.count - 1]]) {
                        problem("“{{/\(name)}}” comes where “{{/\(innermost)}}” was expected.", at: place)
                    } else {
                        problem("“{{/\(name)}}” doesn't close anything.", at: place)
                    }
                    _ = add(.text(tag))
                }
            } else {
                _ = add(.placeholder(String(body)), at: place)
            }
        }
        if !rest.isEmpty { _ = add(.text(rest)) }
        for index in open.dropFirst() {
            if let name = openName(nodes[index]), let place = nodes[index].tag {
                problem("“{{#\(name)}}” is never closed with {{/\(name)}}.", at: place)
            }
        }
    }

    /// `#each …`, `/each`, `#header`, and the other sections' tags.
    private static func isListTag(_ body: Substring) -> Bool {
        guard let first = body.first, first == "#" || first == "/" else { return false }
        let name = String(body.dropFirst().drop { $0 == " " }.prefix { !$0.isWhitespace })
        return name == TemplateList.tagName || TemplateList.Section(rawValue: name) != nil
    }

    /// The line a tag is on, with its new line, when there's nothing else on
    /// it but spaces.
    private static func lineAlone(_ tag: Substring, in text: String) -> Range<String.Index>? {
        var start = tag.startIndex
        while start > text.startIndex {
            let previous = text.index(before: start)
            guard text[previous] == " " || text[previous] == "\t" else { break }
            start = previous
        }
        if start > text.startIndex {
            let previous = text[text.index(before: start)]
            guard previous == "\n" || previous == "\r\n" || previous == "\r" else { return nil }
        }
        var end = tag.endIndex
        while end < text.endIndex, text[end] == " " || text[end] == "\t" { end = text.index(after: end) }
        guard end < text.endIndex else { return start..<end }
        guard text[end] == "\n" || text[end] == "\r\n" || text[end] == "\r" else { return nil }
        return start..<text.index(after: end)
    }

    var hasBlocks: Bool {
        nodes.contains { if case .block = $0.kind { return true }; return false }
    }

    var blockNames: [String] {
        nodes.compactMap { if case .block(let name, _) = $0.kind { return name }; return nil }
    }

    /// What's between the braces of every placeholder — and what each list
    /// goes through, and the placeholders in its attributes.
    var placeholderBodies: [String] {
        nodes.flatMap { node -> [String] in
            switch node.kind {
            case .placeholder(let body): return [body]
            case .list(let list): return list.usedBodies
            default: return []
            }
        }
    }

    /// What the lists go through, at any depth: `clipboard`, `api.github`.
    var listSources: [String] {
        nodes.compactMap { if case .list(let list) = $0.kind, !list.source.isEmpty { return list.source }; return nil }
    }

    /// The placeholders inside blocks called `name`, at any depth — what's
    /// sent to whatever replies to them. One pass: a node's children always
    /// come after it.
    func placeholderBodies(insideBlocksNamed name: String) -> [String] {
        var inside = Set<Int>()
        var bodies: [String] = []
        for (index, node) in nodes.enumerated() {
            let within = inside.contains(index)
            switch node.kind {
            case .block(let block, _) where within || block == name:
                inside.formUnion(node.children)
            case .list(let list) where within:
                bodies += list.usedBodies
                inside.formUnion(node.children)
            case .section where within:
                inside.formUnion(node.children)
            case .placeholder(let body) where within:
                bodies.append(body)
            default:
                break
            }
        }
        return bodies
    }

    // MARK: - Filling in

    struct Rendering {
        /// Nil while a block in it has no reply yet.
        var text: String?
        /// Blocks whose contents are ready but which have no reply yet, in
        /// order of appearance, each once.
        var pending: [TemplateBlockCall] = []
        /// Placeholders with no value and no fallback, in order of appearance.
        var missing: [String] = []
        /// Lists whose rows couldn't be read, or chosen as asked.
        var problems: [String] = []
    }

    /// Fills everything in that can be. `value` gives a placeholder's text,
    /// noting a name it can't fill; `raw` gives a value as it's set, or nil,
    /// for a list to read rows from; `replies` are blocks already worked out;
    /// `standIn`, when given, stands in for any block without a reply — for
    /// previews. `encode` applies to what's placed outside blocks only, not
    /// to what goes inside one.
    func render(value: @escaping (String, inout [String]) -> String, raw: @escaping (String) -> String? = { _ in nil },
                replies: [TemplateBlockCall: String], standIn: ((TemplateBlockCall) -> String)? = nil,
                encode: ((String) -> String)? = nil) -> Rendering {
        let renderer = TemplateRenderer(document: self, value: value, raw: raw, replies: replies, standIn: standIn,
                                        encode: encode)
        let text = renderer.render()
        return Rendering(text: text, pending: renderer.pending, missing: renderer.missing, problems: renderer.problems)
    }

    // MARK: - Reading tags

    /// True for a placeholder with attributes — an operator a module works
    /// out: `quote file="quotes.md"`. A name, a space, then `key=`; plain
    /// placeholders never have a space before their fallback's `|`.
    static func isOperator(_ text: Substring) -> Bool {
        var rest = text.drop { $0 == " " }
        guard let first = rest.first, first.isLetter else { return false }
        rest = rest.drop { $0.isLetter || $0.isNumber || "_.-".contains($0) }
        guard let space = rest.first, space.isWhitespace else { return false }
        rest = rest.drop { $0.isWhitespace }
        guard let keyStart = rest.first, keyStart.isLetter else { return false }
        rest = rest.drop { $0.isLetter || $0.isNumber || "_-".contains($0) }
        return rest.drop { $0 == " " }.first == "="
    }

    /// The `}}` that ends a tag. In a tag with attributes, one inside quotes
    /// doesn't count: `{{#ai note="}}"}}`, `{{quote heading="{{leaf}}"}}`. In
    /// an operator's, nor does one closing a placeholder inside it:
    /// `{{api.wikipedia term={{selection}}}}`.
    private static func tagEnd(in text: Substring, quoted: Bool, nested: Bool = false) -> Range<Substring.Index>? {
        guard quoted else { return text.range(of: "}}") }
        var quote: Character?
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if nested, character == "{", text[index...].hasPrefix("{{") {
                depth += 1
                index = text.index(index, offsetBy: 2)
                continue
            } else if character == "}", text[index...].hasPrefix("}}") {
                if depth == 0 { return index..<text.index(index, offsetBy: 2) }
                depth -= 1
                index = text.index(index, offsetBy: 2)
                continue
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// How deep in `{{ }}` each point of `text` is, outside quotes: for
    /// finding a space or `|` that belongs to the tag, not a placeholder in it.
    static func outsideBraces(_ text: Substring, where test: (Character) -> Bool) -> Substring.Index? {
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("{{") {
                depth += 1
                index = text.index(index, offsetBy: 2)
                continue
            }
            if depth > 0, text[index...].hasPrefix("}}") {
                depth -= 1
                index = text.index(index, offsetBy: 2)
                continue
            }
            if depth == 0, test(text[index]) { return index }
            index = text.index(after: index)
        }
        return nil
    }

    struct TagProblem: Error { let message: String }

    /// `ai model="opus-5.5" effort=low` → ("ai", [model: opus-5.5, effort: low]).
    /// A bare word is an attribute with an empty value.
    static func opening(_ text: Substring) -> Result<(String, [String: String]), TagProblem> {
        var rest = text.drop { $0 == " " }
        let name = String(rest.prefix { !$0.isWhitespace })
        guard let first = name.first, first.isLetter,
              name.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else {
            return .failure(TagProblem(message: "“{{#\(text)}}” needs a name, like {{#ai}}."))
        }
        rest = rest.dropFirst(name.count)
        var attributes: [String: String] = [:]
        while true {
            rest = rest.drop { $0.isWhitespace }
            guard !rest.isEmpty else { break }
            let key = String(rest.prefix { !$0.isWhitespace && $0 != "=" })
            guard !key.isEmpty else { return .failure(TagProblem(message: "“{{#\(name)}}” has an attribute with no name.")) }
            rest = rest.dropFirst(key.count)
            guard rest.first == "=" else {
                attributes[key] = ""
                continue
            }
            rest = rest.dropFirst()
            if let quote = rest.first, quote == "\"" || quote == "'" {
                let value = rest.dropFirst().prefix { $0 != quote }
                guard rest.dropFirst(value.count + 1).first == quote else {
                    return .failure(TagProblem(message: "“{{#\(name)}}”: the quotes around \(key)= aren't closed."))
                }
                attributes[key] = String(value)
                rest = rest.dropFirst(value.count + 2)
            } else {
                // To the next space — but not one inside a placeholder:
                // `term={{contact.name|no one}}`.
                let end = outsideBraces(rest, where: \.isWhitespace) ?? rest.endIndex
                attributes[key] = String(rest[..<end])
                rest = rest[end...]
            }
        }
        return .success((name, attributes))
    }
}

// MARK: - Working blocks out

/// Works out every block in some templates before an action runs: innermost
/// first, in rounds, each round asking for all the blocks whose contents are
/// ready at once. Iterative, so depth costs rounds, not stack.
public enum TemplateBlocks {
    /// The most block replies one key press may ask for. Each can cost money.
    public static let maximumCalls = 24

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case problems([String])
        case tooMany(limit: Int)

        public var description: String {
            switch self {
            case .problems(let problems): return problems.joined(separator: " ")
            case .tooMany(let limit): return "That needs more than \(limit) block replies; one key can ask for \(limit) at most."
            }
        }
    }

    /// True if any of these templates has a block in it.
    public static func contains(_ text: String) -> Bool {
        text.contains("{{#") && TemplateDocument(text).hasBlocks
    }

    /// The block names a template uses: "ai".
    public static func names(in text: String) -> [String] {
        TemplateDocument(text).blockNames
    }

    /// The names used inside a template's `{{#name}}` blocks, at any depth,
    /// as `Template.names` gives them: "selection", "location.latitude".
    public static func names(insideBlocks name: String, in text: String) -> Set<String> {
        Set(TemplateDocument(text).placeholderBodies(insideBlocksNamed: name).map(Template.name(of:)))
    }

    /// Why a template can't run as written, if it can't.
    public static func problems(in text: String) -> [String] {
        TemplateDocument(text).problems
    }

    /// Asks `reply` for each block, innermost first, the blocks of each round
    /// together. Cancelling the task that calls this cancels every request.
    public static func resolve(
        _ texts: [String],
        params: [String: String],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
        limit: Int = maximumCalls,
        reply: @escaping @Sendable (TemplateBlockCall) async throws -> String
    ) async throws -> [TemplateBlockCall: String] {
        let documents = texts.map(TemplateDocument.init)
        let problems = documents.flatMap(\.problems)
        guard problems.isEmpty else { throw Failure.problems(problems) }

        var replies: [TemplateBlockCall: String] = [:]
        while true {
            try Task.checkCancellation()
            var round: [TemplateBlockCall] = []
            for document in documents {
                let rendering = document.render(
                    value: { body, missing in
                        Template.value(for: body, params: params, now: now, calendar: calendar, locale: locale,
                                       missing: &missing)
                    },
                    raw: { params[$0] },
                    replies: replies)
                for call in rendering.pending where !round.contains(call) { round.append(call) }
            }
            guard !round.isEmpty else { return replies }
            guard replies.count + round.count <= limit else { throw Failure.tooMany(limit: limit) }

            let answers = try await withThrowingTaskGroup(of: (TemplateBlockCall, String).self) { group in
                for call in round { group.addTask { (call, try await reply(call)) } }
                var answers: [(TemplateBlockCall, String)] = []
                for try await answer in group { answers.append(answer) }
                return answers
            }
            for (call, answer) in answers { replies[call] = answer }
        }
    }
}
