import Foundation

/// One tag in a template, and where it is: for an editor to colour, explain
/// and check. Ranges are NSRanges, as text views count.
public struct TemplateTag: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `{{contact.phone|none}}`, `{{date:EEEE}}`.
        case value
        /// A name with attributes: `{{quote file="quotes.md"}}`.
        case call
        /// `{{#ai model="sonnet-5"}}`.
        case blockOpening
        /// `{{/ai}}`.
        case blockClosing
    }

    public let kind: Kind
    /// As `Template.names` gives it — `date` without its format — or a
    /// call's or a block's own name: `quote`, `ai`.
    public let name: String
    public let attributes: [String: String]
    /// After the `|`: what's used when it's missing.
    public let fallback: String?
    /// After the `:` of a date or a time: `EEEE`.
    public let format: String?
    /// The whole tag, braces and all.
    public let range: NSRange
    /// Its name within it.
    public let nameRange: NSRange
}

/// Something wrong in a template or a field, and where.
public struct TemplateIssue: Equatable, Sendable {
    public enum Severity: Equatable, Sendable {
        /// It won't run as written.
        case error
        /// It will, but probably not as meant.
        case warning
    }

    public let message: String
    public let range: NSRange
    public let severity: Severity

    public init(_ message: String, at range: NSRange, _ severity: Severity) {
        self.message = message
        self.range = range
        self.severity = severity
    }
}

/// Where a template's text goes, which says what may be in it.
public enum TemplatePlace: Equatable, Sendable {
    /// An action's field, by key: `title`, `url`, `ok.text`.
    case field(String)
    /// A value set in the tree, for `{{name}}`: `topic: …`.
    case value
    /// A template file.
    case file
}

public enum TemplateSyntax {
    /// Every tag in the text, in order — those in a call's attributes too:
    /// `{{selection}}` in `{{api.wikipedia term={{selection}}}}`.
    public static func tags(in text: String) -> [TemplateTag] {
        tags(in: text, offset: 0)
    }

    private static func tags(in text: String, offset: Int) -> [TemplateTag] {
        let document = TemplateDocument(text)
        var tags: [TemplateTag] = []
        func range(_ place: Range<String.Index>) -> NSRange {
            let range = NSRange(place, in: text)
            return NSRange(location: range.location + offset, length: range.length)
        }
        /// The name's place: after the opening braces, any `#` or `/`, and spaces.
        func nameRange(of tag: NSRange, in place: Range<String.Index>, name: String, lead: Int) -> NSRange {
            let after = text[place].dropFirst(2 + lead)
            let spaces = after.prefix { $0 == " " }.utf16.count
            return NSRange(location: tag.location + 2 + lead + spaces, length: name.utf16.count)
        }
        for node in document.nodes {
            guard let place = node.tag else { continue }
            let whole = range(place)
            switch node.kind {
            case .placeholder(let body):
                let (head, fallback) = Template.split(body)
                if TemplateDocument.isOperator(Substring(body)), let call = Template.operatorCall(head) {
                    tags.append(TemplateTag(kind: .call, name: call.name, attributes: call.attributes, fallback: fallback,
                                            format: nil, range: whole,
                                            nameRange: nameRange(of: whole, in: place, name: call.name, lead: 0)))
                    // Tags in its attributes, where they are.
                    let inner = text[place].dropFirst(2).dropLast(2)
                    let start = NSRange(inner.startIndex..<inner.startIndex, in: text).location + offset
                    tags += Self.tags(in: String(inner), offset: start).filter { $0.range != whole }
                } else {
                    let name = Template.name(of: body)
                    let colon = head.firstIndex(of: ":")
                    tags.append(TemplateTag(kind: .value, name: name, attributes: [:], fallback: fallback,
                                            format: colon.map { String(head[head.index(after: $0)...]) }, range: whole,
                                            nameRange: nameRange(of: whole, in: place, name: name, lead: 0)))
                }
            case .block(let name, let attributes):
                tags.append(TemplateTag(kind: .blockOpening, name: name, attributes: attributes, fallback: nil, format: nil,
                                        range: whole, nameRange: nameRange(of: whole, in: place, name: name, lead: 1)))
                if let closing = node.closing {
                    let end = range(closing)
                    tags.append(TemplateTag(kind: .blockClosing, name: name, attributes: [:], fallback: nil, format: nil,
                                            range: end, nameRange: nameRange(of: end, in: closing, name: name, lead: 1)))
                }
            case .root, .text:
                continue
            }
        }
        return tags.sorted { $0.range.location < $1.range.location }
    }

    /// Why the text can't be read as a template, where: a block never closed,
    /// a closing tag that closes nothing, quotes left open.
    public static func problems(in text: String) -> [TemplateIssue] {
        let document = TemplateDocument(text)
        return zip(document.problems, document.problemPlaces).map { message, place in
            TemplateIssue(message, at: NSRange(place, in: text), .error)
        }
    }
}

// MARK: - Checking

extension ValueCatalog {
    /// What's wrong with a field's or a template's text, and where: what
    /// stops it running — a block where none may go, one nothing replies to,
    /// a call missing what it needs — and what's probably a mistake — a name
    /// nothing gives, a format on what isn't a date. Names are known from the
    /// catalogue, so check with the one for the key: `atKey`.
    public func check(_ text: String, in place: TemplatePlace) -> [TemplateIssue] {
        guard text.contains("{{") else { return [] }
        var issues = TemplateSyntax.problems(in: text)
        for tag in TemplateSyntax.tags(in: text) {
            switch tag.kind {
            case .blockClosing:
                continue
            case .blockOpening:
                guard let entry = entry(named: tag.name, block: true) else {
                    issues.append(TemplateIssue("Nothing here replies to {{#\(tag.name)}}.", at: tag.nameRange, .error))
                    continue
                }
                switch place {
                case .value:
                    issues.append(TemplateIssue("A block in a value doesn't run: it's kept as written.", at: tag.range, .warning))
                case .field(let key) where ActionPlanner.blockFreeFields.contains(key.split(separator: ".").last.map(String.init) ?? key):
                    issues.append(TemplateIssue("""
                        A block can't go in \(key): a reply mustn't choose a link, a number or an app.
                        """, at: tag.range, .error))
                default:
                    break
                }
                issues += Self.attributeIssues(tag, entry)
            case .value, .call:
                guard let entry = entry(named: tag.name), knows(tag.name, as: entry) else {
                    issues.append(TemplateIssue(tag.fallback == nil
                        ? "Nothing here gives {{\(tag.name)}}, so it'll be missing."
                        : "Nothing here gives {{\(tag.name)}}, so its fallback is always used.", at: tag.nameRange, .warning))
                    continue
                }
                if tag.format != nil, entry.formats.isEmpty {
                    issues.append(TemplateIssue("""
                        Only dates and times take a format: {{\(tag.name):…}} is read as a name of its own, and missing.
                        """, at: tag.range, .warning))
                }
                issues += Self.attributeIssues(tag, entry)
            }
        }
        return issues.sorted { $0.range.location < $1.range.location }
    }

    /// Whether a name an entry describes is one there is: for a family whose
    /// members are each listed by name — data sources — only theirs.
    private func knows(_ name: String, as entry: ValueEntry) -> Bool {
        guard entry.holes > 0, entry.membersListed else { return true }
        return entries.contains { listed in
            listed.holes == 0 && listed.group == entry.group && (name == listed.name || name.hasPrefix(listed.name + "."))
        }
    }

    private static func attributeIssues(_ tag: TemplateTag, _ entry: ValueEntry) -> [TemplateIssue] {
        let written = tag.kind == .blockOpening ? "{{#\(tag.name)}}" : "{{\(tag.name)}}"
        var issues: [TemplateIssue] = []
        let missing = entry.attributes.filter { $0.required && tag.attributes[$0.name] == nil }
        if !missing.isEmpty {
            issues.append(TemplateIssue("\(written) needs " + missing.map { "\($0.name)=…" }.joined(separator: " and ") + ".",
                                        at: tag.range, .error))
        }
        // Any name goes where the entry takes values of its own: a source's URL's.
        guard !entry.attributes.contains(where: { $0.name.hasPrefix("<") }) else { return issues }
        let known = entry.attributes.map(\.name)
        for name in tag.attributes.keys.sorted() where !known.contains(name) {
            let takes = known.isEmpty ? "nothing" : known.count == 1 ? known[0]
                : known.dropLast().joined(separator: ", ") + " and " + known.last!
            issues.append(TemplateIssue("\(written) doesn't take “\(name)”: it takes \(takes).", at: tag.range, .warning))
        }
        return issues
    }
}
