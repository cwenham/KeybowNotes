import Foundation

/// The portions of a file a `{{quote}}` picks from:
///
/// - **Plain text:** each paragraph, between blank lines — or, in a file
///   without any, each line. A `fortune` file, whose entries are separated by
///   lines holding only `%`, is read that way.
/// - **Markdown:** each item of a bulleted or numbered list, with whatever is
///   indented under it. Code blocks are skipped.
/// - **HTML:** each item of a `<ul>` or `<ol>`, with any lists inside it.
///
/// In Markdown and HTML, a heading narrows it to the items under that
/// heading, down to the next heading of the same level or higher, so a
/// heading takes in its subheadings.
public enum TextPortions {
    public enum Format: Equatable, Sendable {
        case plain, markdown, html

        public init(fileExtension: String) {
            switch fileExtension.lowercased() {
            case "md", "markdown", "mdown", "mkd": self = .markdown
            case "html", "htm", "xhtml": self = .html
            default: self = .plain
            }
        }
    }

    public enum Problem: Error, Equatable {
        /// Plain text has no headings to narrow it by.
        case headingsNeedStructure
        /// No heading matches; the ones there are, with items under them.
        case noHeading(String, available: [String])
        case unreadableHTML(String)
    }

    enum Event: Equatable {
        case heading(level: Int, text: String)
        case item(String)
    }

    public static func portions(of text: String, format: Format, heading: String? = nil) throws -> [String] {
        let wanted = heading.map(normalised).flatMap { $0.isEmpty ? nil : $0 }
        switch format {
        case .plain:
            guard wanted == nil else { throw Problem.headingsNeedStructure }
            return paragraphs(text)
        case .markdown:
            return try select(markdownEvents(text), heading: wanted, asked: heading)
        case .html:
            return try select(htmlEvents(text), heading: wanted, asked: heading)
        }
    }

    // MARK: - Plain text

    static func paragraphs(_ text: String) -> [String] {
        let lines = lines(of: text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !lines.isEmpty, lines != [""] else { return [] }
        func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

        let separator: (String) -> Bool
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "%" }) {
            separator = { $0.trimmingCharacters(in: .whitespaces) == "%" }
        } else if lines.contains(where: isBlank) {
            separator = isBlank
        } else {
            return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        var portions: [String] = []
        var current: [String] = []
        func flush() {
            let portion = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !portion.isEmpty { portions.append(portion) }
            current = []
        }
        for line in lines {
            if separator(line) { flush() } else { current.append(line) }
        }
        flush()
        return portions
    }

    static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    // MARK: - Markdown

    struct Marker {
        let indent: Int
        /// Where the item's text starts; lines indented this far belong to it.
        let contentIndent: Int
        let content: String
    }

    static func markdownEvents(_ text: String) -> [Event] {
        var events: [Event] = []
        var fence: String?
        var item: (marker: Marker, lines: [String])?
        var blankSinceItem = false
        /// A paragraph's line outside any list, which `===` or `---` can make a heading.
        var paragraphLine: String?

        func flush() {
            if let item {
                let text = item.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { events.append(.item(text)) }
            }
            item = nil
            blankSinceItem = false
        }
        func appendToItem(_ line: String) {
            guard let current = item else { return }
            let under = line.prefix { $0 == " " }.count >= current.marker.contentIndent
                ? String(line.dropFirst(current.marker.contentIndent)) : line.trimmingCharacters(in: .whitespaces)
            item?.lines.append(under)
        }

        for raw in lines(of: text) {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count

            // Code: kept inside an item it's indented under, skipped otherwise.
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                if item != nil { appendToItem(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                if let current = item, indent >= current.marker.contentIndent { appendToItem(line) } else { flush() }
                paragraphLine = nil
                continue
            }
            if trimmed.isEmpty {
                if item != nil { blankSinceItem = true }
                paragraphLine = nil
                continue
            }
            if indent < 4, let heading = atxHeading(trimmed) {
                flush()
                events.append(heading)
                paragraphLine = nil
                continue
            }
            if indent < 4, item == nil, let text = paragraphLine, isSetextUnderline(trimmed) {
                events.append(.heading(level: trimmed.hasPrefix("=") ? 1 : 2, text: text))
                paragraphLine = nil
                continue
            }
            if let marker = listMarker(line) {
                if let current = item, marker.indent >= current.marker.contentIndent {
                    if blankSinceItem { item?.lines.append("") }
                    appendToItem(line)                 // an item inside this one
                } else {
                    flush()
                    item = (marker, [marker.content])
                }
                blankSinceItem = false
                paragraphLine = nil
                continue
            }
            if let current = item {
                if indent >= current.marker.contentIndent {
                    if blankSinceItem { item?.lines.append("") }
                    appendToItem(line)
                    blankSinceItem = false
                    continue
                }
                if !blankSinceItem, !isThematicBreak(trimmed) {
                    appendToItem(line)                 // a lazy continuation of its text
                    continue
                }
                flush()
            }
            paragraphLine = isThematicBreak(trimmed) ? nil : trimmed
        }
        flush()
        return events
    }

    /// `## Stoics ##` → a level 2 heading, "Stoics".
    static func atxHeading(_ line: String) -> Event? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing run of #s, after a space, isn't part of it.
        if let closing = text.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
            text = String(text[..<closing.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return .heading(level: hashes, text: text)
    }

    static func isSetextUnderline(_ line: String) -> Bool {
        guard let first = line.first, first == "=" || first == "-" else { return false }
        return line.allSatisfy { $0 == first }
    }

    /// `---`, `* * *`, `___`.
    static func isThematicBreak(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// `- text`, `* text`, `+ text`, `1. text`, `1) text`.
    static func listMarker(_ line: String) -> Marker? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        guard !isThematicBreak(String(rest)) else { return nil }
        let markerLength: Int
        if let first = rest.first, "-*+".contains(first) {
            markerLength = 1
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }.count
            guard (1...9).contains(digits), let after = rest.dropFirst(digits).first, after == "." || after == ")" else {
                return nil
            }
            markerLength = digits + 1
        }
        let afterMarker = rest.dropFirst(markerLength)
        guard afterMarker.isEmpty || afterMarker.first == " " else { return nil }
        let spaces = afterMarker.prefix { $0 == " " }.count
        // Five or more spaces start indented code: the text starts after one.
        let gap = spaces == 0 || spaces > 4 ? 1 : spaces
        return Marker(indent: indent, contentIndent: indent + markerLength + gap,
                      content: String(afterMarker.drop { $0 == " " }))
    }

    // MARK: - HTML

    static func htmlEvents(_ text: String) throws -> [Event] {
        let document: XMLDocument
        do {
            // From the text, not its bytes: tidying bytes guesses their
            // encoding, and without a charset it guesses wrong.
            document = try XMLDocument(xmlString: text, options: [.documentTidyHTML])
        } catch {
            throw Problem.unreadableHTML(error.localizedDescription)
        }
        let headingsAndItems = "//*[self::h1 or self::h2 or self::h3 or self::h4 or self::h5 or self::h6"
            + " or (self::li and not(ancestor::li))]"
        let nodes = (try? document.nodes(forXPath: headingsAndItems)) ?? []
        return nodes.compactMap { node in
            let name = node.name?.lowercased() ?? ""
            if name.count == 2, name.first == "h", let level = Int(name.dropFirst()) {
                return .heading(level: level, text: collapsed(node.stringValue ?? ""))
            }
            let text = tidied(itemText(of: node, depth: 0))
            return text.isEmpty ? nil : .item(text)
        }
    }

    /// An item's text: lists inside it as lines of their own, `<br>` and
    /// paragraphs as line breaks, the rest as it reads.
    static func itemText(of node: XMLNode, depth: Int) -> String {
        guard depth < 32 else { return "" }
        var output = ""
        for child in node.children ?? [] {
            switch child.kind {
            case .text:
                output += collapsed(child.stringValue ?? "", trimming: false)
            case .element:
                let name = child.name?.lowercased() ?? ""
                if name == "br" {
                    output += "\n"
                } else if name == "ul" || name == "ol" {
                    for item in child.children ?? [] where item.name?.lowercased() == "li" {
                        output += "\n- " + tidied(itemText(of: item, depth: depth + 1))
                    }
                    output += "\n"
                } else if ["p", "div", "blockquote", "pre"].contains(name) {
                    output += "\n" + itemText(of: child, depth: depth + 1) + "\n"
                } else {
                    output += itemText(of: child, depth: depth + 1)
                }
            default:
                break
            }
        }
        return output
    }

    /// Runs of spaces and line breaks as one space.
    static func collapsed(_ text: String, trimming: Bool = true) -> String {
        let one = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return trimming ? one.trimmingCharacters(in: .whitespaces) : one
    }

    /// Each line trimmed, the empty ones gone.
    static func tidied(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - Headings

    /// Lowercased, spacing collapsed, emphasis marks and a closing colon
    /// dropped: `**Stoics:**` and `stoics` are the same heading.
    static func normalised(_ heading: String) -> String {
        var text = heading.filter { !"*_`".contains($0) }.lowercased()
        text = collapsed(text)
        while text.hasSuffix(":") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func select(_ events: [Event], heading wanted: String?, asked: String?) throws -> [String] {
        guard let wanted else {
            return events.compactMap { if case .item(let text) = $0 { return text }; return nil }
        }
        var portions: [String] = []
        var found = false
        var under: Int?                 // the level of the heading matched, while under it
        var available: [String] = []
        var lastHeading: String?
        for event in events {
            switch event {
            case .heading(let level, let text):
                if let open = under, level <= open { under = nil }
                if under == nil, normalised(text) == wanted {
                    under = level
                    found = true
                }
                lastHeading = text
            case .item(let text):
                if under != nil { portions.append(text) }
                if let heading = lastHeading, !available.contains(heading) { available.append(heading) }
            }
        }
        guard found else { throw Problem.noHeading(asked ?? wanted, available: available) }
        return portions
    }
}
