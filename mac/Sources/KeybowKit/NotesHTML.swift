import Foundation

/// Markdown to the small subset of HTML that Notes accepts from a script:
/// headings, paragraphs, bold, italic, links and lists. Checklists and tables
/// cannot be created this way, so there is no syntax for them in a note —
/// but what's pasted, or shown, can have tables.
///
///   # Heading / ## Heading / ### Heading
///   - bullet  (or *)
///   1. numbered
///   **bold**, *italic* or _italic_, [text](https://…) — shown as "text (https://…)",
///   because Notes drops links set by a script
///   a blank line leaves a blank line
public enum NotesHTML {
    /// `links`: `[text](url)` as a link, where it can be followed — a
    /// display — rather than kept as "text (url)" for Notes, which drops links.
    /// `tables`: a Markdown table as a table, for what's pasted or shown;
    /// Notes is given its lines as they are.
    public static func from(markdown: String, links: Bool = false, tables: Bool = false) -> String {
        var html = ""
        var openList: String?

        func closeList() {
            if let tag = openList {
                html += "</\(tag)>"
                openList = nil
            }
        }
        func beginList(_ tag: String) {
            if openList != tag {
                closeList()
                html += "<\(tag)>"
                openList = tag
            }
        }

        let trimmed = markdown.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return "" }

        let lines = trimmed.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1

            if tables, let rows = table(at: index - 1, in: lines) {
                closeList()
                html += table(lines[(index - 1)..<(index - 1 + rows)].map { $0 }, links: links)
                index += rows - 1
            } else if let (level, text) = heading(line) {
                closeList()
                html += "<div><h\(level)>\(inline(text, links: links))</h\(level)></div>"
            } else if let item = bullet(line) {
                beginList("ul")
                html += "<li>\(item.isEmpty ? "<br>" : inline(item, links: links))</li>"
            } else if let item = numbered(line) {
                beginList("ol")
                html += "<li>\(item.isEmpty ? "<br>" : inline(item, links: links))</li>"
            } else {
                closeList()
                html += line.isEmpty ? "<div><br></div>" : "<div>\(inline(line, links: links))</div>"
            }
        }
        closeList()
        return html
    }

    /// A note's title line.
    public static func title(_ text: String) -> String {
        "<div><h1>\(escape(text))</h1></div>"
    }

    /// Text that's an HTML document rather than Markdown: it opens with
    /// `<!DOCTYPE html>`, `<html>`, an XML declaration or a `<meta>` naming
    /// its encoding.
    public static func isDocument(_ text: String) -> Bool {
        let start = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64).lowercased()
        return ["<!doctype html", "<html", "<?xml", "<meta"].contains { start.hasPrefix($0) }
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Tables

    /// How many lines the table starting here takes: a row of cells between
    /// `|`s, a rule of dashes under it, then rows. Nil if none starts here.
    private static func table(at start: Int, in lines: [String]) -> Int? {
        guard start + 1 < lines.count else { return nil }
        let first = lines[start].trimmingCharacters(in: .whitespaces)
        let rule = lines[start + 1].trimmingCharacters(in: .whitespaces)
        guard first.contains("|"), isRule(rule) else { return nil }
        var end = start + 2
        while end < lines.count, lines[end].contains("|"), !lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
        return end - start
    }

    private static func isRule(_ line: String) -> Bool {
        line.contains("-") && line.contains("|") && line.allSatisfy { "|-: ".contains($0) }
            && cells(line).allSatisfy { $0.contains("-") }
    }

    private static func cells(_ line: String) -> [String] {
        var inner = Substring(line.trimmingCharacters(in: .whitespaces))
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
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// The table's lines as HTML, its columns aligned as the rule says, with
    /// borders that hold when it's pasted.
    private static func table(_ lines: [String], links: Bool) -> String {
        let header = cells(lines[0])
        let alignments = cells(lines[1]).map { rule -> String in
            switch (rule.hasPrefix(":"), rule.hasSuffix(":")) {
            case (true, true): return "center"
            case (false, true): return "right"
            default: return "left"
            }
        }
        let width = header.count
        func row(_ cells: [String], tag: String) -> String {
            let padded = cells.prefix(width) + Array(repeating: "", count: max(0, width - cells.count))
            return "<tr>" + padded.enumerated().map { index, cell in
                let align = index < alignments.count ? alignments[index] : "left"
                return "<\(tag) style=\"border: 1px solid #b8b8b8; padding: 3px 8px; text-align: \(align)\">"
                    + inline(cell, links: links) + "</\(tag)>"
            }.joined() + "</tr>"
        }
        return "<table style=\"border-collapse: collapse\"><thead>" + row(header, tag: "th") + "</thead><tbody>"
            + lines.dropFirst(2).map { row(cells($0), tag: "td") }.joined() + "</tbody></table>"
    }

    // MARK: - Lines

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...3).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func bullet(_ line: String) -> String? {
        // A bare "-" is an empty bullet: a template's slot to fill in.
        if line == "-" || line == "*" { return "" }
        guard line.count > 2, line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
        return String(line.dropFirst(2))
    }

    private static func numbered(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return String(line.dropFirst(digits.count + 2))
    }

    // MARK: - Inline

    private static let rules: [(NSRegularExpression, String)] = [
        // Notes strips <a href> set by a script, leaving only underlined text,
        // so keep the address visible instead of losing it.
        (try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)\)"#), "$1 ($2)"),
        (try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#), "<b>$1</b>"),
        (try! NSRegularExpression(pattern: #"(?<![\*\w])\*(?!\s)(.+?)(?<!\s)\*(?![\*\w])"#), "<i>$1</i>"),
        (try! NSRegularExpression(pattern: #"(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)"#), "<i>$1</i>"),
    ]

    private static let link = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)\)"#)

    private static func inline(_ text: String, links: Bool) -> String {
        var result = escape(text)
        if links {
            result = link.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                   withTemplate: "<a href=\"$2\">$1</a>")
        }
        for (pattern, template) in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}
