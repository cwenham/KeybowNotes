import Foundation

/// How to find a value in an API's response: a JSONPath for JSON, an XPath
/// for XML or HTML, or a regular expression for anything. Written once, by
/// Claude or by hand, and then applied on the Mac to every response.
public struct ExtractionRule: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case jsonPath = "jsonpath"
        case xPath = "xpath"
        case regex

        public var title: String {
            switch self {
            case .jsonPath: return "JSONPath"
            case .xPath: return "XPath"
            case .regex: return "Regular expression"
            }
        }
    }

    public var kind: Kind
    public var expression: String

    public init(kind: Kind, expression: String) {
        self.kind = kind
        self.expression = expression
    }

    /// Everything the rule finds, as text.
    public func values(in body: Data, contentType: String? = nil) throws -> [String] {
        switch kind {
        case .jsonPath:
            let json: Any
            do {
                json = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
            } catch {
                throw ExtractionError("The response isn't JSON, so a JSONPath can't read it.")
            }
            return try JSONPath(expression).values(in: json).map(JSONPath.text)
        case .xPath:
            let html = (contentType ?? "").contains("html") || Self.looksLikeHTML(body)
            let document: XMLDocument
            do {
                // HTML is tidied from its text, not its bytes: tidying bytes
                // guesses their encoding, and without a charset it guesses wrong.
                document = html
                    ? try XMLDocument(xmlString: Self.text(of: body, contentType: contentType), options: [.documentTidyHTML])
                    : try XMLDocument(data: body, options: [])
            } catch {
                throw ExtractionError("The response isn't XML or HTML that can be read: \(error.localizedDescription)")
            }
            do {
                return try document.nodes(forXPath: expression).map { $0.stringValue ?? "" }
            } catch {
                throw ExtractionError("“\(expression)” isn't an XPath that works here: \(error.localizedDescription)")
            }
        case .regex:
            let text = String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
            let pattern: NSRegularExpression
            do {
                pattern = try NSRegularExpression(pattern: expression)
            } catch {
                throw ExtractionError("“\(expression)” isn't a regular expression that works.")
            }
            let whole = NSRange(text.startIndex..., in: text)
            return pattern.matches(in: text, range: whole).compactMap { match in
                // The first group, if there is one: the value inside its context.
                let range = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                return Range(range, in: text).map { String(text[$0]) }
            }
        }
    }

    /// The value: what the rule finds, several joined with commas. Empty if
    /// it finds nothing.
    public func value(in body: Data, contentType: String? = nil) throws -> String {
        try values(in: body, contentType: contentType)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// The body as text, in the charset its Content-Type names, else UTF-8.
    static func text(of body: Data, contentType: String?) -> String {
        if let charset = charset(in: contentType) {
            let encoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let text = String(data: body, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return text
            }
        }
        return String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
    }

    /// "text/html; charset=ISO-8859-1" → "ISO-8859-1".
    static func charset(in contentType: String?) -> String? {
        for part in (contentType ?? "").split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == "charset" {
                return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    static func looksLikeHTML(_ body: Data) -> Bool {
        let start = String(decoding: body.prefix(512), as: UTF8.self).lowercased()
        return start.contains("<!doctype html") || start.contains("<html")
    }
}

public struct ExtractionError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - JSONPath

/// The parts of JSONPath (RFC 9535) that rules use:
///
///   $                   the whole response
///   .name  ['name']     a member
///   [0]  [-1]           an element, from the start or the end
///   *  [*]              every member or element
///   ..name  ..*         at any depth
///   [?(@.city == 'London')]   the elements whose `city` is London;
///                             == != < <= > >=, && and ||, ! and @.a alone
///                             to mean "has a" — no functions, no slices
struct JSONPath {
    enum Selector {
        case name(String)
        case index(Int)
        case wildcard
        /// Any of the groups, each all true.
        case filter([[Term]])
    }

    struct Term {
        var negated = false
        let path: [Selector]           // from @: names and indexes only
        let comparison: (op: String, literal: Any)?
    }

    struct Segment {
        let descendant: Bool
        let selectors: [Selector]
    }

    let segments: [Segment]

    init(_ expression: String) throws {
        var rest = Substring(expression.trimmingCharacters(in: .whitespaces))
        guard rest.first == "$" else { throw ExtractionError("A JSONPath starts with $: “\(expression)”.") }
        rest = rest.dropFirst()
        var segments: [Segment] = []
        while !rest.isEmpty {
            var descendant = false
            if rest.hasPrefix("..") {
                descendant = true
                rest = rest.dropFirst(2)
            } else if rest.hasPrefix(".") {
                rest = rest.dropFirst()
            } else if !rest.hasPrefix("[") {
                throw ExtractionError("“\(expression)” can't be read at “\(rest)”.")
            }
            if rest.hasPrefix("[") {
                let (inside, after) = try Self.bracket(rest, in: expression)
                segments.append(Segment(descendant: descendant, selectors: try Self.selectors(inside, in: expression)))
                rest = after
            } else if rest.hasPrefix("*") {
                segments.append(Segment(descendant: descendant, selectors: [.wildcard]))
                rest = rest.dropFirst()
            } else {
                let name = rest.prefix { $0 != "." && $0 != "[" }
                guard !name.isEmpty else { throw ExtractionError("“\(expression)” has a dot with no name after it.") }
                segments.append(Segment(descendant: descendant, selectors: [.name(String(name))]))
                rest = rest.dropFirst(name.count)
            }
        }
        self.segments = segments
    }

    func values(in root: Any) -> [Any] {
        var nodes: [Any] = [root]
        for segment in segments {
            let bases = segment.descendant ? Self.selfAndDescendants(nodes) : nodes
            var next: [Any] = []
            for base in bases {
                for selector in segment.selectors { next += Self.select(selector, from: base) }
            }
            nodes = next
        }
        return nodes
    }

    // MARK: Selecting

    private static func children(_ node: Any) -> [Any] {
        if let array = node as? [Any] { return array }
        if let object = node as? [String: Any] { return object.keys.sorted().compactMap { object[$0] } }
        return []
    }

    /// Every node and all beneath it, in document order — without recursion.
    private static func selfAndDescendants(_ nodes: [Any]) -> [Any] {
        var result: [Any] = []
        var stack = Array(nodes.reversed())
        while let node = stack.popLast() {
            result.append(node)
            stack += children(node).reversed()
        }
        return result
    }

    private static func select(_ selector: Selector, from node: Any) -> [Any] {
        switch selector {
        case .name(let name):
            return ((node as? [String: Any])?[name]).map { [$0] } ?? []
        case .index(let index):
            guard let array = node as? [Any] else { return [] }
            let position = index < 0 ? array.count + index : index
            return array.indices.contains(position) ? [array[position]] : []
        case .wildcard:
            return children(node)
        case .filter(let groups):
            return children(node).filter { candidate in
                groups.contains { group in group.allSatisfy { holds($0, for: candidate) } }
            }
        }
    }

    private static func holds(_ term: Term, for candidate: Any) -> Bool {
        var found: Any? = candidate
        for selector in term.path {
            guard let current = found else { break }
            found = select(selector, from: current).first
        }
        let result: Bool
        if let (op, literal) = term.comparison {
            result = found.map { compare($0, op, literal) } ?? false
        } else {
            result = found != nil
        }
        return term.negated ? !result : result
    }

    private static func compare(_ value: Any, _ op: String, _ literal: Any) -> Bool {
        if let a = number(value), let b = number(literal) {
            switch op {
            case "==": return a == b
            case "!=": return a != b
            case "<": return a < b
            case "<=": return a <= b
            case ">": return a > b
            case ">=": return a >= b
            default: return false
            }
        }
        if let a = value as? String, let b = literal as? String {
            switch op {
            case "==": return a == b
            case "!=": return a != b
            case "<": return a < b
            case "<=": return a <= b
            case ">": return a > b
            case ">=": return a >= b
            default: return false
            }
        }
        // true, false and null are only ever equal or not.
        let equal: Bool
        if isBool(value), isBool(literal), let a = value as? NSNumber, let b = literal as? NSNumber {
            equal = a.boolValue == b.boolValue
        } else {
            equal = value is NSNull && literal is NSNull
        }
        switch op {
        case "==": return equal
        case "!=": return !equal
        default: return false
        }
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        return number.doubleValue
    }

    /// A found value as text: strings as they are, numbers without a
    /// needless ".0", anything bigger as compact JSON.
    static func text(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            if isBool(number) { return number.boolValue ? "true" : "false" }
            let double = number.doubleValue
            if double == double.rounded(), abs(double) < 1e15 { return String(Int64(double)) }
            return number.stringValue
        case is NSNull:
            return ""
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: Reading

    /// `[…]` at the start of `text`, without the brackets, and what follows.
    private static func bracket(_ text: Substring, in expression: String) throws -> (Substring, Substring) {
        var depth = 0
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "[" || character == "(" {
                depth += 1
            } else if character == "]" || character == ")" {
                depth -= 1
                if depth == 0 {
                    return (text[text.index(after: text.startIndex)..<index], text[text.index(after: index)...])
                }
            }
            index = text.index(after: index)
        }
        throw ExtractionError("“\(expression)” has a [ that isn't closed.")
    }

    /// Splits at `separator` where it isn't inside quotes or brackets.
    private static func split(_ text: Substring, on separator: String) -> [Substring] {
        var parts: [Substring] = []
        var depth = 0
        var quote: Character?
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "[" || character == "(" {
                depth += 1
            } else if character == "]" || character == ")" {
                depth -= 1
            } else if depth == 0, text[index...].hasPrefix(separator) {
                parts.append(text[start..<index])
                index = text.index(index, offsetBy: separator.count)
                start = index
                continue
            }
            index = text.index(after: index)
        }
        parts.append(text[start...])
        return parts
    }

    private static func selectors(_ inside: Substring, in expression: String) throws -> [Selector] {
        try split(inside, on: ",").map { part in
            let item = part.trimmingCharacters(in: .whitespaces)
            if item == "*" { return .wildcard }
            if let literal = quoted(item) { return .name(literal) }
            if let index = Int(item) { return .index(index) }
            if item.hasPrefix("?") { return .filter(try filter(Substring(item.dropFirst()), in: expression)) }
            if item.contains(":") { throw ExtractionError("“\(expression)”: slices like [\(item)] aren't supported.") }
            throw ExtractionError("“\(expression)”: [\(item)] isn't a name, an index, * or a filter.")
        }
    }

    private static func quoted(_ text: String) -> String? {
        guard text.count >= 2, let first = text.first, first == "'" || first == "\"", text.last == first else { return nil }
        return String(text.dropFirst().dropLast())
    }

    private static func filter(_ text: Substring, in expression: String) throws -> [[Term]] {
        var body = text.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("("), body.hasSuffix(")") { body = String(body.dropFirst().dropLast()) }
        return try split(Substring(body), on: "||").map { group in
            try split(group, on: "&&").map { try term($0.trimmingCharacters(in: .whitespaces), in: expression) }
        }
    }

    private static func term(_ text: String, in expression: String) throws -> Term {
        var body = Substring(text)
        var negated = false
        if body.hasPrefix("!") {
            negated = true
            body = body.dropFirst().drop { $0 == " " }
        }
        guard body.hasPrefix("@") else {
            throw ExtractionError("“\(expression)”: a filter compares @ — the item — with something: “\(text)”.")
        }
        for op in ["==", "!=", "<=", ">=", "<", ">"] {
            let parts = split(body, on: op)
            guard parts.count == 2 else { continue }
            let path = try relativePath(parts[0].trimmingCharacters(in: .whitespaces), in: expression)
            let literal = try self.literal(parts[1].trimmingCharacters(in: .whitespaces), in: expression)
            return Term(negated: negated, path: path, comparison: (op, literal))
        }
        return Term(negated: negated, path: try relativePath(String(body), in: expression), comparison: nil)
    }

    /// `@.a.b[0]['c']` → its selectors, names and indexes only.
    private static func relativePath(_ text: String, in expression: String) throws -> [Selector] {
        let path = try JSONPath("$" + text.dropFirst())
        return try path.segments.flatMap { segment -> [Selector] in
            guard !segment.descendant else { throw ExtractionError("“\(expression)”: .. isn't supported inside a filter.") }
            return try segment.selectors.map { selector in
                switch selector {
                case .name, .index: return selector
                default: throw ExtractionError("“\(expression)”: only names and indexes can follow @ in a filter.")
                }
            }
        }
    }

    private static func literal(_ text: String, in expression: String) throws -> Any {
        if let string = quoted(text) { return string }
        switch text {
        case "true": return NSNumber(value: true)
        case "false": return NSNumber(value: false)
        case "null": return NSNull()
        default:
            if let number = Double(text) { return NSNumber(value: number) }
            throw ExtractionError("“\(expression)”: “\(text)” isn't a string, number, true, false or null.")
        }
    }
}
