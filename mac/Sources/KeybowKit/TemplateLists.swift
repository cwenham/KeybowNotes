import Foundation

// Lists: `{{#each source}} … {{/each}}`. The text between is filled in once
// for each row of the source — a CSV file, cells copied from a spreadsheet, an
// API's results — with the row's columns as values, and the rows joined.
//
//   {{#each clipboard where="Paid = no" sort="Due" limit=10}}
//   {{#header}}
//   | Invoice | Due | Amount |
//   |---|---|---|
//   {{/header}}
//   | {{Invoice}} | {{Due}} | {{Amount}} |
//   {{#footer}}
//   {{@count}} unpaid, {{@sum.Amount}} in all.
//   {{/footer}}
//   {{#empty}}Nothing unpaid.{{/empty}}
//   {{/each}}
//
// A tag alone on its line takes the line with it, so a list written over
// several lines leaves no blank lines of its own.

/// A list's opening tag, read.
struct TemplateList: Equatable {
    static let tagName = "each"

    /// Parts of a list, written inside it.
    enum Section: String, CaseIterable {
        /// Before the rows, once — when there are any.
        case header
        /// After them, once.
        case footer
        /// In their place, when there are none.
        case empty
    }

    /// Its own attributes. Any others belong to what it goes through: a data
    /// source's values, `term={{selection}}`.
    static let attributeNames: Set<String> = ["file", "where", "sort", "limit", "separator", "columns", "format"]

    /// What it goes through, as a placeholder names a value: `clipboard`,
    /// `api.github`, `api.wikipedia term={{selection}}`, `file name='team.csv'`.
    var source: String
    /// Where the source's name is in the template: nil for `file=`.
    var sourceRange: Range<String.Index>? = nil
    var attributes: [String: String]

    /// The placeholders it uses itself: what it goes through, and any in its
    /// attributes.
    var usedBodies: [String] {
        (source.isEmpty ? [] : [source]) + attributes.keys.sorted().flatMap { TemplateDocument(attributes[$0]!).placeholderBodies }
    }

    /// `each clipboard where="Paid = no"`, after the `#`. The first bare word
    /// is what it goes through; `file=` names a file instead.
    static func opening(_ text: Substring) -> Result<TemplateList, TemplateDocument.TagProblem> {
        func problem(_ message: String) -> Result<TemplateList, TemplateDocument.TagProblem> {
            .failure(TemplateDocument.TagProblem(message: message))
        }
        var rest = text.drop { $0 == " " }.dropFirst(tagName.count)
        var word: Substring?
        var extras: [Substring] = []
        var attributes: [String: String] = [:]
        while true {
            rest = rest.drop { $0.isWhitespace }
            guard !rest.isEmpty else { break }
            let start = rest.startIndex
            let key = rest.prefix { !$0.isWhitespace && $0 != "=" }
            guard !key.isEmpty else { return problem("“{{#each}}” has an attribute with no name.") }
            rest = rest.dropFirst(key.count)
            guard rest.first == "=" else {
                if let word { return problem("“{{#each}}” goes through one thing: “\(word)” or “\(key)”?") }
                word = key
                continue
            }
            rest = rest.dropFirst()
            let value: String
            if let quote = rest.first, quote == "\"" || quote == "'" {
                let inner = rest.dropFirst().prefix { $0 != quote }
                guard rest.dropFirst(inner.count + 1).first == quote else {
                    return problem("“{{#each}}”: the quotes around \(key)= aren't closed.")
                }
                value = String(inner)
                rest = rest.dropFirst(inner.count + 2)
            } else {
                let end = TemplateDocument.outsideBraces(rest, where: \.isWhitespace) ?? rest.endIndex
                value = String(rest[..<end])
                rest = rest[end...]
            }
            let name = String(key)
            // `file=` names a file to go through — unless it's given to the
            // thing gone through: `{{#each quote file=…}}`.
            if attributeNames.contains(name), !(name == "file" && word != nil) {
                attributes[name] = value
            } else {
                extras.append(text[start..<rest.startIndex])
            }
        }
        for (key, value) in attributes where value.contains("{{#") {
            return problem("“{{#each}}”'s \(key)= can't hold a block.")
        }
        if let format = attributes["format"], !format.contains("{{"),
           DataTable.Format(rawValue: format.lowercased()) == nil {
            return problem("“{{#each}}”'s format is "
                           + DataTable.Format.allCases.map(\.rawValue).joined(separator: ", ") + ", not “\(format)”.")
        }
        if let limit = attributes["limit"], !limit.contains("{{"), Int(limit.trimmingCharacters(in: .whitespaces)) == nil {
            return problem("“{{#each}}”'s limit is a number of rows, not “\(limit)”.")
        }
        if let word {
            let source = ([word] + extras).joined(separator: " ")
            return .success(TemplateList(source: source, sourceRange: word.startIndex..<word.endIndex,
                                         attributes: attributes))
        }
        guard extras.isEmpty else {
            return problem("“{{#each}}” needs what it goes through first: {{#each api.wikipedia term=…}}.")
        }
        guard let file = attributes["file"] else {
            return problem("“{{#each}}” needs something to go through: {{#each clipboard}}, or {{#each file='rows.csv'}}.")
        }
        let quote = file.contains("'") ? "\"" : "'"
        return .success(TemplateList(source: "file name=\(quote)\(file)\(quote)", sourceRange: nil, attributes: attributes))
    }

    /// True when a source's text is a preview's stand-in — `‹clipboard›` —
    /// rather than rows.
    static func isStandIn(_ text: String) -> Bool {
        text.hasPrefix("‹") && text.hasSuffix("›") && !text.contains("\n")
    }
}

// MARK: - Choosing and ordering rows

/// One test of `where="Paid = no and Amount > 100"`.
struct RowCondition: Equatable {
    enum Test: String, CaseIterable {
        case notEqual = "!=", lessOrEqual = "<=", greaterOrEqual = ">=", lacks = "!~", equal = "="
        case less = "<", greater = ">", contains = "~"
    }

    let column: String
    /// Nil: the column has something in it — or, `negated`, nothing.
    let test: Test?
    let value: String
    var negated = false

    /// `Paid = no and Amount > 100`: tests joined with `and`, outside quotes.
    static func parse(_ text: String) -> [RowCondition] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace,
                      let and = text[index...].range(of: #"^\s+and\s+"#, options: [.regularExpression, .caseInsensitive]) {
                parts.append(current)
                current = ""
                index = and.upperBound
                continue
            }
            current.append(character)
            index = text.index(after: index)
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map(condition)
    }

    private static func condition(_ text: String) -> RowCondition {
        var index = text.startIndex
        while index < text.endIndex {
            let rest = text[index...]
            if let test = Test.allCases.first(where: { rest.hasPrefix($0.rawValue) }) {
                var width = test.rawValue.count
                if test == .equal, rest.hasPrefix("==") { width = 2 }
                return RowCondition(column: unquoted(String(text[..<index])), test: test,
                                    value: unquoted(String(rest.dropFirst(width))))
            }
            index = text.index(after: index)
        }
        if text.hasPrefix("!") { return RowCondition(column: unquoted(String(text.dropFirst())), test: nil, value: "", negated: true) }
        return RowCondition(column: unquoted(text), test: nil, value: "")
    }

    private static func unquoted(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    func holds(for cell: String) -> Bool {
        guard let test else { return cell.trimmingCharacters(in: .whitespaces).isEmpty == negated }
        let cell = cell.trimmingCharacters(in: .whitespaces)
        switch test {
        case .equal: return Self.same(cell, value)
        case .notEqual: return !Self.same(cell, value)
        case .less: return DataTable.compare(cell, value) == .orderedAscending
        case .lessOrEqual: return DataTable.compare(cell, value) != .orderedDescending
        case .greater: return DataTable.compare(cell, value) == .orderedDescending
        case .greaterOrEqual: return DataTable.compare(cell, value) != .orderedAscending
        case .contains: return value.isEmpty || cell.range(of: value, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .lacks: return !value.isEmpty && cell.range(of: value, options: [.caseInsensitive, .diacriticInsensitive]) == nil
        }
    }

    /// Equal as numbers when both are — `5` and `5.00` — else ignoring case.
    private static func same(_ first: String, _ second: String) -> Bool {
        if let a = DataTable.number(first)?.value, let b = DataTable.number(second)?.value { return a == b }
        return first.compare(second, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

/// `sort="Status, Due desc"`: columns to order by, each `asc` (the default)
/// or `desc`.
struct RowOrder: Equatable {
    let column: String
    let descending: Bool

    static func parse(_ text: String) -> [RowOrder] {
        text.split(separator: ",").compactMap { part in
            var words = part.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { return nil }
            var descending = false
            if let last = words.last?.lowercased(), words.count > 1, last == "desc" || last == "asc" {
                descending = last == "desc"
                words.removeLast()
            }
            return RowOrder(column: words.joined(separator: " "), descending: descending)
        }
    }
}

// MARK: - Inside a list

/// What a list's placeholders are filled from: the row's columns, the
/// list's own `@` values, then whatever's outside it.
final class RowScope {
    /// Where each name a row asks for is among the columns, found once for
    /// all the list's rows.
    final class Columns {
        let table: DataTable
        private var found: [String: Int?] = [:]

        init(_ table: DataTable) { self.table = table }

        func index(_ name: String) -> Int? {
            if let known = found[name] { return known }
            let index = table.column(named: name)
            found[name] = index
            return index
        }
    }

    let parent: RowScope?
    let table: DataTable
    let columns: Columns
    /// The rows shown, in order, by their place in the table.
    let rows: [Int]
    /// Which of them this is: nil in a header, a footer or `{{#empty}}`.
    let position: Int?
    /// Rows not known yet, in a preview: names stand in for themselves.
    let preview: Bool

    init(parent: RowScope?, table: DataTable, rows: [Int], position: Int?, preview: Bool, columns: Columns? = nil) {
        self.parent = parent
        self.table = table
        self.columns = columns ?? Columns(table)
        self.rows = rows
        self.position = position
        self.preview = preview
    }

    var row: Int? { position.map { rows[$0] } }
    var inPreview: Bool { preview || (parent?.inPreview ?? false) }

    func at(_ position: Int?) -> RowScope {
        RowScope(parent: parent, table: table, rows: rows, position: position, preview: preview, columns: columns)
    }

    /// A column of the row — this list's, or one it's inside — or one of
    /// this list's `@` values. Nil when it's none of those.
    func value(_ name: String) -> String? {
        if name.hasPrefix("@") { return special(name) }
        if let row, let column = columns.index(name) { return table.rows[row].cells[column] }
        return parent?.value(name)
    }

    /// A column's list, for an `{{#each}}` inside the row's.
    func list(_ name: String) -> DataTable? {
        if let row, columns.index(name) != nil { return table.list(row, name) }
        return parent?.list(name)
    }

    private func special(_ name: String) -> String? {
        switch name {
        case "@number": return position.map { String($0 + 1) } ?? ""
        case "@count": return preview ? "‹count›" : String(rows.count)
        case "@row":
            guard let row else { return "" }
            return preview ? "‹row›" : table.rows[row].cells.joined(separator: "\t")
        case "@columns": return preview ? "‹columns›" : table.columns.joined(separator: "\t")
        default: break
        }
        for kind in ["sum", "average", "min", "max"] where name.hasPrefix("@\(kind).") {
            let column = String(name.dropFirst(kind.count + 2))
            if preview { return "‹\(kind == "sum" ? "total" : kind) of \(column)›" }
            guard table.column(named: column) != nil else { return nil }
            return aggregate(kind, rows.compactMap { table.cell($0, column) })
        }
        return nil
    }

    private func aggregate(_ kind: String, _ cells: [String]) -> String {
        let cells = cells.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        switch kind {
        case "min": return cells.min { DataTable.compare($0, $1) == .orderedAscending } ?? ""
        case "max": return cells.max { DataTable.compare($0, $1) == .orderedAscending } ?? ""
        default:
            let numbers = cells.compactMap(DataTable.number)
            let total = numbers.reduce(0) { $0 + $1.value }
            let places = numbers.map(\.decimals).max() ?? 0
            if kind == "sum" { return String(format: "%.\(places)f", total) }
            guard !numbers.isEmpty else { return "" }
            var average = String(format: "%.\(places + 2)f", total / Double(numbers.count))
            while average.contains("."), average.hasSuffix("0") { average.removeLast() }
            if average.hasSuffix(".") { average.removeLast() }
            return average
        }
    }
}

// MARK: - Filling in

/// Fills a parsed template in: placeholders, lists row by row, and blocks,
/// innermost first. Blocks are worked out without recursing, however deep;
/// only lists inside lists recurse, and they go only so deep.
final class TemplateRenderer {
    /// How deep lists may go inside lists.
    static let deepestList = 16

    let document: TemplateDocument
    let value: (String, inout [String]) -> String
    let raw: (String) -> String?
    let replies: [TemplateBlockCall: String]
    let standIn: ((TemplateBlockCall) -> String)?
    let encode: ((String) -> String)?

    private(set) var pending: [TemplateBlockCall] = []
    var missing: [String] = []
    private(set) var problems: [String] = []

    /// Where each node's contents end: everything inside a node comes
    /// straight after it.
    private let ends: [Int]
    /// The list each node is in, or -1.
    private let owners: [Int]
    private var listDepth = 0

    init(document: TemplateDocument, value: @escaping (String, inout [String]) -> String,
         raw: @escaping (String) -> String?, replies: [TemplateBlockCall: String],
         standIn: ((TemplateBlockCall) -> String)?, encode: ((String) -> String)?) {
        self.document = document
        self.value = value
        self.raw = raw
        self.replies = replies
        self.standIn = standIn
        self.encode = encode
        let nodes = document.nodes
        var ends = Array(nodes.indices).map { $0 + 1 }
        for index in nodes.indices.reversed() {
            for child in nodes[index].children { ends[index] = max(ends[index], ends[child]) }
        }
        var owners = Array(repeating: -1, count: nodes.count)
        for index in nodes.indices {
            let owner: Int
            if case .list = nodes[index].kind { owner = index } else { owner = owners[index] }
            for child in nodes[index].children { owners[child] = owner }
        }
        self.ends = ends
        self.owners = owners
    }

    /// The whole template: nil while a block in it has no reply.
    func render() -> String? {
        sequence(document.nodes[0].children, scope: nil, encoding: true)
    }

    /// Nodes side by side. `encoding`: what's placed among them goes into a
    /// link — not so for a block's contents.
    private func sequence(_ children: [Int], scope: RowScope?, encoding: Bool) -> String? {
        var output = ""
        var ready = true
        for child in children {
            guard let text = node(child, scope: scope, encoding: encoding) else {
                ready = false
                continue
            }
            switch document.nodes[child].kind {
            case .placeholder, .block: output += encoding ? encode.map { $0(text) } ?? text : text
            default: output += text
            }
        }
        return ready ? output : nil
    }

    private func node(_ index: Int, scope: RowScope?, encoding: Bool) -> String? {
        switch document.nodes[index].kind {
        case .text(let text): return String(text)
        case .placeholder(let body): return lookup(body, scope: scope)
        case .block: return block(index, scope: scope)
        case .list: return list(index, scope: scope, encoding: encoding)
        case .section, .root: return sequence(document.nodes[index].children, scope: scope, encoding: encoding)
        }
    }

    /// A placeholder's text: from the row, if it's in a list, else as ever.
    func lookup(_ body: String, scope: RowScope?) -> String {
        guard let scope else { return value(body, &missing) }
        let (name, fallback) = Template.split(body)
        if let found = scope.value(name) {
            if found.isEmpty, let fallback { return Template.fallbackText(fallback) }
            return found
        }
        if scope.inPreview, raw(name) == nil, !Template.isBuiltIn(name), !name.hasPrefix("@") { return "‹\(name)›" }
        return value(body, &missing)
    }

    /// A block and everything in it, in two passes: placeholders and lists
    /// front to back, then blocks from the end, so each block's contents are
    /// ready by the time it's reached.
    private func block(_ start: Int, scope: RowScope?) -> String? {
        let nodes = document.nodes
        let end = ends[start]
        let owner = owners[start]
        var texts = [String?](repeating: "", count: end - start)
        var index = start + 1
        while index < end {
            switch nodes[index].kind {
            case .text(let text): texts[index - start] = String(text)
            case .placeholder(let body): texts[index - start] = lookup(body, scope: scope)
            case .list:
                texts[index - start] = list(index, scope: scope, encoding: false)
                index = ends[index]
                continue
            default: break
            }
            index += 1
        }
        for index in stride(from: end - 1, through: start, by: -1) where owners[index] == owner {
            guard case .block(let name, let attributes) = nodes[index].kind else { continue }
            var body = ""
            var ready = true
            for child in nodes[index].children {
                guard let text = texts[child - start] else { ready = false; break }
                body += text
            }
            guard ready else { texts[index - start] = nil; continue }
            let call = TemplateBlockCall(name: name, attributes: attributes, body: body)
            if let reply = replies[call] {
                texts[index - start] = reply
            } else if let standIn {
                texts[index - start] = standIn(call)
            } else {
                if !pending.contains(call) { pending.append(call) }
                texts[index - start] = nil
            }
        }
        return texts[0]
    }

    /// An attribute's text, its placeholders filled in.
    private func fill(_ text: String, scope: RowScope?) -> String {
        guard text.contains("{{") else { return text }
        let inner = TemplateRenderer(document: TemplateDocument(text), value: value, raw: raw, replies: [:],
                                     standIn: { _ in "" }, encode: nil)
        let filled = inner.sequence(inner.document.nodes[0].children, scope: scope, encoding: false) ?? ""
        for name in inner.missing where !missing.contains(name) { missing.append(name) }
        return filled
    }

    /// A list: its header, its body once for each row, and its footer — or
    /// `{{#empty}}`, with no rows.
    private func list(_ index: Int, scope: RowScope?, encoding: Bool) -> String? {
        guard case .list(let spec) = document.nodes[index].kind, !spec.source.isEmpty else { return "" }
        guard listDepth < Self.deepestList else {
            note("Lists go \(Self.deepestList) deep inside each other at most.")
            return ""
        }
        listDepth += 1
        defer { listDepth -= 1 }

        var sections: [TemplateList.Section: Int] = [:]
        var body: [Int] = []
        for child in document.nodes[index].children {
            if case .section(let section) = document.nodes[child].kind { sections[section] = child } else { body.append(child) }
        }
        func attribute(_ key: String, trimmed: Bool = true) -> String? {
            spec.attributes[key].map { text in
                let filled = fill(text, scope: scope)
                return trimmed ? filled.trimmingCharacters(in: .whitespaces) : filled
            }
        }

        // Missing, it's nothing at all — not {{#empty}}, which says there are no rows.
        guard let (table, preview) = rows(of: spec, scope: scope, format: attribute("format"), columns: attribute("columns"))
        else { return "" }
        var shown = Array(table.rows.indices)
        if !preview {
            if let text = attribute("where"), !text.isEmpty {
                for condition in RowCondition.parse(text) {
                    guard table.column(named: condition.column) != nil else {
                        note("The rows of {{\(spec.source)}} have no column “\(condition.column)” to choose by"
                             + (table.columns.isEmpty ? "." : ": they have " + table.columns.joined(separator: ", ") + "."))
                        shown = []
                        break
                    }
                    shown = shown.filter { condition.holds(for: table.cell($0, condition.column) ?? "") }
                }
            }
            if let text = attribute("sort"), !text.isEmpty {
                let orders = RowOrder.parse(text)
                for order in orders where table.column(named: order.column) == nil {
                    note("The rows of {{\(spec.source)}} have no column “\(order.column)” to sort by.")
                }
                shown = shown.enumerated().sorted { first, second in
                    for order in orders {
                        let result = DataTable.compare(table.cell(first.element, order.column) ?? "",
                                                       table.cell(second.element, order.column) ?? "")
                        if result != .orderedSame { return order.descending ? result == .orderedDescending : result == .orderedAscending }
                    }
                    return first.offset < second.offset
                }.map(\.element)
            }
            if let text = attribute("limit"), let limit = Int(text), limit >= 0 { shown = Array(shown.prefix(limit)) }
        }

        let list = RowScope(parent: scope, table: table, rows: shown, position: nil, preview: preview)
        func section(_ name: TemplateList.Section) -> String? {
            guard let section = sections[name] else { return "" }
            return sequence(document.nodes[section].children, scope: list, encoding: encoding)
        }
        guard !shown.isEmpty else { return section(.empty) }

        // Spaces and all: `separator=', '`. `\n` and `\t` as written in a file.
        let separator = attribute("separator", trimmed: false).map {
            $0.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
        } ?? ""
        var parts: [String?] = [section(.header)]
        for position in shown.indices {
            if position > 0, !separator.isEmpty { parts.append(separator) }
            parts.append(sequence(body, scope: list.at(position), encoding: encoding))
        }
        parts.append(section(.footer))
        return parts.contains { $0 == nil } ? nil : parts.compactMap { $0 }.joined()
    }

    /// The rows a list goes through, and whether they're a preview's stand-in
    /// — or nil, noted as missing, when there's no such value.
    private func rows(of spec: TemplateList, scope: RowScope?, format: String?,
                      columns: String?) -> (DataTable, preview: Bool)? {
        let empty = DataTable(columns: [], cells: [])
        let format = format.flatMap { DataTable.Format(rawValue: $0.lowercased()) }
        let naming: DataTable.Columns
        switch columns {
        case nil, "": naming = .firstRow
        case let text? where text.lowercased() == "none": naming = .numbered
        case let text?: naming = .named(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        if let nested = scope?.list(spec.source) { return (nested, false) }
        if let rows = raw(Template.rowsKey(for: spec.source)) {
            return ((try? DataTable.read(rows, format: .json, columns: naming)) ?? empty, false)
        }
        guard let text = raw(spec.source) else {
            if scope?.inPreview == true { return (DataTable(columns: [], cells: [[]]), true) }
            if !missing.contains(spec.source) { missing.append(spec.source) }
            return nil
        }
        if TemplateList.isStandIn(text) || text.isEmpty && scope?.inPreview == true {
            return (DataTable(columns: [], cells: [[]]), true)
        }
        do {
            return (try DataTable.read(MediaToken.describe(text), format: format, columns: naming), false)
        } catch {
            note("{{\(spec.source)}} can't be read as \(format?.rawValue ?? "rows"): \(error)")
            return (empty, false)
        }
    }

    private func note(_ problem: String) {
        if !problems.contains(problem) { problems.append(problem) }
    }
}
