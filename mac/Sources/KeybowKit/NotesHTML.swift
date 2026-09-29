import Foundation

/// Markdown to the small subset of HTML that Notes accepts from a script:
/// headings, paragraphs, bold, italic, links and lists. Checklists and tables
/// cannot be created this way, so there is no syntax for them.
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
    public static func from(markdown: String, links: Bool = false) -> String {
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

        for rawLine in trimmed.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if let (level, text) = heading(line) {
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
