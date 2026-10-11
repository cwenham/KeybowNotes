import Foundation

/// Rows of values, and the names of their columns: what `{{#each}}` goes
/// through. Read from text — a CSV file, cells copied from a spreadsheet, an
/// API's JSON, a Markdown table, or plain lines — or given by a module.
///
///   Name,Phone          CSV, or tab-separated as spreadsheets copy it: the
///   Ann,0123            first row names the columns
///   [{"name": "Ann"}]   JSON: an array of objects, their keys the columns
///   | Name | Phone |    a Markdown table
///   - Ann               plain lines, one row each, bullets taken off
public struct DataTable: Equatable, Sendable {
    public enum Format: String, CaseIterable, Sendable {
        case csv, tsv, json, markdown, lines
    }

    /// Where the columns' names come from.
    public enum Columns: Equatable, Sendable {
        /// The first row, for data that can have one: CSV, tab-separated, a
        /// JSON array of arrays.
        case firstRow
        /// These, in order; every row is data. Columns beyond them are numbered.
        case named([String])
        /// None: every row is data, and its columns are 1, 2, 3.
        case numbered
    }

    public struct Row: Equatable, Sendable {
        /// One for each column, in order.
        public var cells: [String]
        /// Cells that hold lists of their own — a JSON array — by column, for
        /// an `{{#each}}` inside the row's.
        public var lists: [Int: DataTable]

        public init(cells: [String], lists: [Int: DataTable] = [:]) {
            self.cells = cells
            self.lists = lists
        }
    }

    public var columns: [String]
    public var rows: [Row]

    public init(columns: [String], rows: [Row]) {
        self.columns = columns
        self.rows = rows.map { row in
            var row = row
            if row.cells.count < columns.count { row.cells += Array(repeating: "", count: columns.count - row.cells.count) }
            return row
        }
    }

    public init(columns: [String], cells: [[String]]) {
        self.init(columns: columns, rows: cells.map { Row(cells: $0) })
    }

    public struct Problem: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    // MARK: - Looking up

    /// A column, by name — as written, else ignoring case and spacing — or
    /// by number, from 1.
    public func column(named name: String) -> Int? {
        if let index = columns.firstIndex(of: name) { return index }
        let wanted = Self.comparable(name)
        if let index = columns.firstIndex(where: { Self.comparable($0) == wanted }) { return index }
        if let number = Int(name), number >= 1, number <= columns.count { return number - 1 }
        return nil
    }

    public func cell(_ row: Int, _ name: String) -> String? {
        guard rows.indices.contains(row), let column = column(named: name), rows[row].cells.indices.contains(column) else {
            return nil
        }
        return rows[row].cells[column]
    }

    /// A cell's list, or its text read as a table of its own.
    public func list(_ row: Int, _ name: String) -> DataTable? {
        guard rows.indices.contains(row), let column = column(named: name) else { return nil }
        if let list = rows[row].lists[column] { return list }
        return try? Self.read(rows[row].cells[column])
    }

    private static func comparable(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Reading

    /// The rows in some text: in `format`, else whichever it looks like.
    public static func read(_ text: String, format: Format? = nil, columns: Columns = .firstRow) throws -> DataTable {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        switch format ?? guess(text) {
        case .json:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return DataTable(columns: [], cells: []) }
            guard let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]) else {
                throw Problem(message: "It isn't JSON that can be read.")
            }
            return fromJSON(json, columns: columns)
        case .csv:
            return fromCells(delimited(text, by: separator(of: text)), columns: columns)
        case .tsv:
            return fromCells(delimited(text, by: "\t"), columns: columns)
        case .markdown:
            return markdownTable(text, columns: columns)
        case .lines:
            return lines(text, columns: columns)
        }
    }

    /// What some text looks like: JSON; a Markdown table; cells separated by
    /// tabs, as a spreadsheet copies them; CSV, when every line has the same
    /// number of commas (or semicolons) outside quotes; else plain lines.
    public static func guess(_ text: String) -> Format {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, first == "[" || first == "{",
           (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil {
            return .json
        }
        let lines = trimmed.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count >= 2, lines[0].hasPrefix("|"), isMarkdownRule(lines[1]) { return .markdown }
        if trimmed.contains("\t") { return .tsv }
        for separator: Character in [",", ";"] where trimmed.contains(separator) {
            let rows = delimited(trimmed, by: separator)
            if rows.count >= 2, let count = rows.first?.count, count >= 2, rows.allSatisfy({ $0.count == count }) {
                return .csv
            }
        }
        return .lines
    }

    /// A comma, or the semicolon that CSV written with decimal commas uses.
    private static func separator(of text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" && $0 != "\r" }
        return firstLine.filter { $0 == ";" }.count > firstLine.filter { $0 == "," }.count ? ";" : ","
    }

    /// Rows of cells, read as CSV is: a cell in double quotes can hold the
    /// separator, a new line, or "" for a quote. Blank lines are skipped.
    static func delimited(_ text: String, by separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        var startOfCell = true
        var iterator = text.makeIterator()
        var pending: Character?
        func endRow() {
            row.append(cell)
            if !(row.count == 1 && row[0].trimmingCharacters(in: .whitespaces).isEmpty) { rows.append(row) }
            row = []
            cell = ""
            startOfCell = true
        }
        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { cell.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    cell.append(character)
                }
                continue
            }
            switch character {
            case "\"" where startOfCell:
                quoted = true
                startOfCell = false
            case separator:
                row.append(cell)
                cell = ""
                startOfCell = true
            case "\n", "\r\n", "\r":
                endRow()
            default:
                cell.append(character)
                startOfCell = false
            }
        }
        if !cell.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Rows of cells, named by the first row, or as `columns` says.
    static func fromCells(_ cells: [[String]], columns: Columns) -> DataTable {
        var data = cells
        var names: [String] = []
        switch columns {
        case .firstRow:
            names = data.isEmpty ? [] : data.removeFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        case .named(let given):
            names = given
        case .numbered:
            break
        }
        let width = max(names.count, data.map(\.count).max() ?? 0)
        for index in names.count..<max(width, names.count) { names.append(String(index + 1)) }
        names = names.enumerated().map { $1.isEmpty ? String($0 + 1) : $1 }
        return DataTable(columns: names, cells: data)
    }

    private static func isMarkdownRule(_ line: String) -> Bool {
        line.contains("-") && line.allSatisfy { "|-: ".contains($0) }
    }

    /// `| Name | Phone |`, a rule beneath, then a row a line.
    static func markdownTable(_ text: String, columns: Columns) -> DataTable {
        var rows: [[String]] = []
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|") || line.contains("|"), !isMarkdownRule(line) else { continue }
            var inner = Substring(line)
            if inner.hasPrefix("|") { inner = inner.dropFirst() }
            if inner.hasSuffix("|"), !inner.hasSuffix("\\|") { inner = inner.dropLast() }
            var cells: [String] = []
            var cell = ""
            var escaped = false
            for character in inner {
                if escaped {
                    cell.append(character == "|" ? "|" : "\\\(character)")
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "|" {
                    cells.append(cell.trimmingCharacters(in: .whitespaces))
                    cell = ""
                } else {
                    cell.append(character)
                }
            }
            if escaped { cell.append("\\") }
            cells.append(cell.trimmingCharacters(in: .whitespaces))
            rows.append(cells)
        }
        // A Markdown table always has a header row; `columns` can rename it.
        var table = fromCells(rows, columns: .firstRow)
        if case .named(let names) = columns {
            for (index, name) in names.enumerated() where index < table.columns.count { table.columns[index] = name }
        }
        return table
    }

    /// A row a line, blank lines skipped — and, when every line is a list
    /// item, without the bullets or numbers.
    static func lines(_ text: String, columns: Columns) -> DataTable {
        var lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let markers = lines.map(listMarker)
        if !lines.isEmpty, markers.allSatisfy({ $0 > 0 }) {
            lines = zip(lines, markers).map { String($0.dropFirst($1)) }
        }
        var name = "1"
        if case .named(let names) = columns, let first = names.first, !first.isEmpty { name = first }
        return DataTable(columns: [name], cells: lines.map { [$0] })
    }

    /// How long a line's list marker is — `- `, `* `, `• `, `1. `, `2) ` —
    /// or 0 when it hasn't one.
    private static func listMarker(_ line: String) -> Int {
        for bullet in ["- ", "* ", "• ", "+ "] where line.hasPrefix(bullet) { return bullet.count }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, let mark = line.dropFirst(digits.count).first, mark == "." || mark == ")",
           line.dropFirst(digits.count + 1).first == " " {
            return digits.count + 2
        }
        return 0
    }

    // MARK: - JSON

    /// An array is its rows; anything else, one row. Objects' keys are their
    /// columns — nested objects' as `author.name` — in alphabetical order;
    /// arrays of arrays are read as CSV is, and plain values make one column.
    static func fromJSON(_ json: Any, columns: Columns) -> DataTable {
        let items = json as? [Any] ?? [json]
        if !items.isEmpty, items.allSatisfy({ $0 is [String: Any] }) {
            var names: [String] = []
            var seen = Set<String>()
            var flattened: [[(String, Any)]] = []
            for item in items {
                let fields = flatten(item as? [String: Any] ?? [:])
                for (name, _) in fields where seen.insert(name).inserted { names.append(name) }
                flattened.append(fields)
            }
            let index = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
            let rows = flattened.map { fields in
                var row = Row(cells: Array(repeating: "", count: names.count))
                for (name, value) in fields {
                    guard let column = index[name] else { continue }
                    row.cells[column] = text(value)
                    if value is [Any] { row.lists[column] = fromJSON(value, columns: .firstRow) }
                }
                return row
            }
            return DataTable(columns: names, rows: rows)
        }
        if !items.isEmpty, items.allSatisfy({ $0 is [Any] }) {
            let table = fromCells(items.map { ($0 as? [Any] ?? []).map(text) }, columns: columns)
            // Lists inside, where a cell is one — the header row's taken off.
            let skip = columns == .firstRow ? 1 : 0
            var rows = table.rows
            for (index, item) in items.dropFirst(skip).enumerated() {
                for (column, value) in (item as? [Any] ?? []).enumerated() where value is [Any] {
                    rows[index].lists[column] = fromJSON(value, columns: .firstRow)
                }
            }
            return DataTable(columns: table.columns, rows: rows)
        }
        var name = "1"
        if case .named(let names) = columns, let first = names.first, !first.isEmpty { name = first }
        return DataTable(columns: [name], rows: items.map { item in
            Row(cells: [text(item)], lists: item is [Any] ? [0: fromJSON(item, columns: .firstRow)] : [:])
        })
    }

    private static func flatten(_ object: [String: Any], prefix: String = "") -> [(String, Any)] {
        var fields: [(String, Any)] = []
        for key in object.keys.sorted() {
            let value = object[key]!
            if let inner = value as? [String: Any], !inner.isEmpty {
                fields += flatten(inner, prefix: prefix + key + ".")
            } else {
                fields.append((prefix + key, value))
            }
        }
        return fields
    }

    /// A JSON value as a cell: strings as they are, numbers without a needless
    /// ".0", a list of plain values as "a, b, c", anything else as JSON.
    static func text(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let double = number.doubleValue
            if double == double.rounded(), abs(double) < 1e15 { return String(Int64(double)) }
            return number.stringValue
        case is NSNull:
            return ""
        case let array as [Any] where array.allSatisfy({ !($0 is [Any]) && !($0 is [String: Any]) }):
            return array.map(text).filter { !$0.isEmpty }.joined(separator: ", ")
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: - Numbers

    /// A cell read as a number, and how many decimal places it was written
    /// with: `1,200.50`, `£12`, `(3.00)` for -3, `1.200,5` with a decimal
    /// comma, `45%`. Nil for anything else — a date, a word.
    public static func number(_ text: String) -> (value: Double, decimals: Int)? {
        var text = text.trimmingCharacters(in: .whitespaces)
        var negative = false
        if text.hasPrefix("("), text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }
        text = text.filter { !$0.isWhitespace && !"£$€¥₹%".contains($0) }
        if let sign = text.first, sign == "-" || sign == "−" || sign == "+" {
            negative = negative || sign != "+"
            text.removeFirst()
        }
        guard !text.isEmpty, text.first!.isNumber || text.first == "." || text.first == ",",
              text.allSatisfy({ ("0"..."9").contains($0) || $0 == "." || $0 == "," }),
              text.contains(where: { ("0"..."9").contains($0) }) else { return nil }
        let lastDot = text.lastIndex(of: ".")
        let lastComma = text.lastIndex(of: ",")
        var decimal: Character?
        switch (lastDot, lastComma) {
        case let (dot?, comma?):
            decimal = dot > comma ? "." : ","
        case (_?, nil):
            decimal = text.filter { $0 == "." }.count == 1 ? "." : nil
        case (nil, let comma?):
            let after = text[text.index(after: comma)...]
            decimal = text.filter { $0 == "," }.count == 1 && after.count != 3 ? "," : nil
        case (nil, nil):
            break
        }
        var digits = ""
        var decimals = 0
        var afterPoint = false
        for character in text {
            if character == decimal {
                guard !afterPoint else { return nil }
                afterPoint = true
                digits.append(".")
            } else if character.isNumber {
                digits.append(character)
                if afterPoint { decimals += 1 }
            }
        }
        guard let value = Double(digits) else { return nil }
        return (negative ? -value : value, decimals)
    }

    /// Cells in order: as numbers when both are, else as Finder sorts names —
    /// so "item 2" comes before "item 10", and ISO dates in date order.
    public static func compare(_ first: String, _ second: String) -> ComparisonResult {
        if let a = number(first)?.value, let b = number(second)?.value {
            return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        }
        return first.localizedStandardCompare(second)
    }
}
