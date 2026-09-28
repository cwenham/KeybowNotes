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
    }

    struct Node {
        var kind: Kind
        var children: [Int] = []
    }

    /// Node 0 is the whole template. A node's children always come after it.
    private(set) var nodes: [Node] = [Node(kind: .root)]
    /// Blocks never closed, closing tags that close nothing, unreadable
    /// attributes. Shown to the person; a template with any isn't run.
    private(set) var problems: [String] = []

    init(_ text: String) {
        var open = [0]                                  // blocks not yet closed, innermost last
        var rest = Substring(text)

        func add(_ kind: Kind) -> Int {
            nodes.append(Node(kind: kind))
            let index = nodes.count - 1
            nodes[open[open.count - 1]].children.append(index)
            return index
        }

        while let start = rest.range(of: "{{") {
            if start.lowerBound > rest.startIndex { _ = add(.text(rest[..<start.lowerBound])) }
            let inside = rest[start.upperBound...]
            let opensBlock = inside.first == "#"
            guard let end = Self.tagEnd(in: inside, quoted: opensBlock) else {
                // An unclosed brace is left as written — but a block's opening
                // tag that never ends is surely a mistake, like a stray quote.
                if opensBlock {
                    let name = inside.dropFirst().prefix { !$0.isWhitespace && $0 != "}" }
                    problems.append("“{{#\(name)” has no closing }} — check its quotes.")
                }
                _ = add(.text(rest[start.lowerBound...]))
                rest = ""
                break
            }
            let tag = rest[start.lowerBound..<end.upperBound]
            let body = inside[..<end.lowerBound]
            rest = inside[end.upperBound...]

            if opensBlock {
                switch Self.opening(body.dropFirst()) {
                case .success(let (name, attributes)):
                    open.append(add(.block(name: name, attributes: attributes)))
                case .failure(let problem):
                    problems.append(problem.message)
                    _ = add(.text(tag))
                }
            } else if body.first == "/" {
                let name = body.dropFirst().trimmingCharacters(in: .whitespaces)
                if open.count > 1, case .block(let innermost, _) = nodes[open[open.count - 1]].kind, innermost == name {
                    open.removeLast()
                } else {
                    if open.count > 1, case .block(let innermost, _) = nodes[open[open.count - 1]].kind {
                        problems.append("“{{/\(name)}}” comes where “{{/\(innermost)}}” was expected.")
                    } else {
                        problems.append("“{{/\(name)}}” doesn't close anything.")
                    }
                    _ = add(.text(tag))
                }
            } else {
                _ = add(.placeholder(String(body)))
            }
        }
        if !rest.isEmpty { _ = add(.text(rest)) }
        for index in open.dropFirst() {
            if case .block(let name, _) = nodes[index].kind {
                problems.append("“{{#\(name)}}” is never closed with {{/\(name)}}.")
            }
        }
    }

    var hasBlocks: Bool {
        nodes.contains { if case .block = $0.kind { return true }; return false }
    }

    var blockNames: [String] {
        nodes.compactMap { if case .block(let name, _) = $0.kind { return name }; return nil }
    }

    var placeholderBodies: [String] {
        nodes.compactMap { if case .placeholder(let body) = $0.kind { return body }; return nil }
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
    }

    /// Fills everything in that can be. `value` gives a placeholder's text,
    /// noting a name it can't fill; `replies` are blocks already worked out;
    /// `standIn`, when given, stands in for any block without a reply — for
    /// previews. `encode` applies to what's placed at the top level only, not
    /// to what goes inside a block.
    func render(value: (String, inout [String]) -> String, replies: [TemplateBlockCall: String],
                standIn: ((TemplateBlockCall) -> String)? = nil,
                encode: ((String) -> String)? = nil) -> Rendering {
        var rendering = Rendering()
        var texts = [String?](repeating: "", count: nodes.count)

        // Placeholders first, front to back, so missing names come in order.
        for index in nodes.indices {
            switch nodes[index].kind {
            case .text(let text): texts[index] = String(text)
            case .placeholder(let body): texts[index] = value(body, &rendering.missing)
            default: break
            }
        }

        // Then from the end: a block's contents come after it, so by the time
        // a block is reached everything inside it has been worked out.
        for index in nodes.indices.reversed() {
            switch nodes[index].kind {
            case .block(let name, let attributes):
                var body = ""
                var ready = true
                for child in nodes[index].children {
                    guard let text = texts[child] else { ready = false; break }
                    body += text
                }
                guard ready else { texts[index] = nil; continue }
                let call = TemplateBlockCall(name: name, attributes: attributes, body: body)
                if let reply = replies[call] {
                    texts[index] = reply
                } else if let standIn {
                    texts[index] = standIn(call)
                } else {
                    if !rendering.pending.contains(call) { rendering.pending.append(call) }
                    texts[index] = nil
                }
            case .root:
                var output = ""
                var ready = true
                for child in nodes[index].children {
                    guard let text = texts[child] else { ready = false; continue }
                    switch nodes[child].kind {
                    case .placeholder, .block: output += encode.map { $0(text) } ?? text
                    default: output += text
                    }
                }
                texts[index] = ready ? output : nil
            default:
                break
            }
        }
        rendering.text = texts[0]
        return rendering
    }

    // MARK: - Reading tags

    /// The `}}` that ends a tag. In a block's opening tag, one inside quotes
    /// doesn't count: `{{#ai note="}}"}}`.
    private static func tagEnd(in text: Substring, quoted: Bool) -> Range<Substring.Index>? {
        guard quoted else { return text.range(of: "}}") }
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "}", text[index...].hasPrefix("}}") {
                return index..<text.index(index, offsetBy: 2)
            }
            index = text.index(after: index)
        }
        return nil
    }

    struct TagProblem: Error { let message: String }

    /// `ai model="opus-5.5" effort=low` → ("ai", [model: opus-5.5, effort: low]).
    /// A bare word is an attribute with an empty value.
    private static func opening(_ text: Substring) -> Result<(String, [String: String]), TagProblem> {
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
                let value = rest.prefix { !$0.isWhitespace }
                attributes[key] = String(value)
                rest = rest.dropFirst(value.count)
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
