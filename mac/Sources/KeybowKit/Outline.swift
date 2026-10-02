import Foundation

// The outline: the form a configuration is written in. See docs/CONFIG-LANGUAGE.md.
//
//     KeybowNotes template hierarchy            ← preamble, kept as written
//
//     1. Work
//        2. General Tasks
//           1. Meeting [Calendar, 5 min alert, duration: 1h]
//              1. Today
//
//     # row 2                                    ← a side tree
//     1. Quick note
//
//     # list when                                ← reusable nodes: [@when]
//     1. Today [when: today]
//
//     # contacts
//     - Rudy Rudolph [phone: +15550100, email: rudy@example.com]
//
//     # projects
//     - Project A [path: ~/Code/project-a]
//
//     # defaults
//     - commitDelayMs: 1000
//
// This file holds the document model, the parser and the writer. The parser
// keeps going past mistakes, reporting them, so an editor can open an imperfect
// file; the writer's output parses back to the same document.

/// One item inside a node's brackets.
public enum Annotation: Equatable, Hashable, Sendable {
    /// A keyword or name: `Calendar`, `append`, `worklog.md`, `Rider`, `@when`.
    case word(String)
    /// A setting: `duration: 1h`, `phone: +15550100`.
    case pair(key: String, value: String)

    public var key: String? {
        if case .pair(let key, _) = self { return key }
        return nil
    }

    /// As written in the outline.
    public var text: String {
        switch self {
        case .word(let word): return word
        case .pair(let key, let value): return value.isEmpty ? "\(key):" : "\(key): \(Self.quoted(value))"
        }
    }

    /// Reads one bracket item. A pair is `identifier: value`; anything else is
    /// a word — including a link like `https://example.com`, whose scheme
    /// would otherwise read as a key.
    public init(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let colon = trimmed.firstIndex(of: ":") {
            let key = String(trimmed[..<colon])
            if Self.isKey(key), !trimmed[trimmed.index(after: colon)...].hasPrefix("//") {
                var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = Self.unquoted(String(value.dropFirst().dropLast()))
                }
                self = .pair(key: key, value: value)
                return
            }
        }
        self = .word(trimmed)
    }

    /// Letters, digits, dots, underscores and hyphens, starting with a letter:
    /// `phone`, `find.byName`, `guards.maxBodyBytes`.
    static func isKey(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// Quotes a value that would otherwise be misread: commas and brackets end
    /// an item, and surrounding spaces would be trimmed.
    static func quoted(_ value: String) -> String {
        let needsQuotes = value.contains(",") || value.contains("[") || value.contains("]")
            || value.contains("\"") || value.contains("\n") || value != value.trimmingCharacters(in: .whitespaces)
        guard needsQuotes else { return value }
        // The outline is one node per line, so a newline is written \n.
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static func unquoted(_ value: String) -> String {
        var result = ""
        var escaping = false
        for character in value {
            if escaping {
                result.append(character == "n" ? "\n" : character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}

/// A node: a label, its bracketed annotations, and up to four children, each in
/// the key position it occupies.
public struct OutlineNode: Equatable, Identifiable, Sendable {
    /// Stable while the document is edited, so a selection can follow a node
    /// as it moves. Not written to the file.
    public var id = UUID()
    public var label: String
    public var annotations: [Annotation]
    /// Four slots — or under a page, one per key below it; nil where no node
    /// occupies that key.
    public var children: [OutlineNode?]
    /// Where it was read from, for messages; 0 for a node made in the editor.
    public var line: Int

    public init(label: String, annotations: [Annotation] = [], children: [OutlineNode?] = OutlineNode.emptyRow,
                line: Int = 0) {
        self.label = label
        self.annotations = annotations
        self.children = children
        self.line = line
    }

    public static let emptyRow: [OutlineNode?] = [nil, nil, nil, nil]

    public var hasChildren: Bool { children.contains { $0 != nil } }

    /// The list this node takes its children from, if it says `[@name]`.
    public var listReference: String? {
        for case .word(let word) in annotations where word.hasPrefix("@") && word.count > 1 {
            return String(word.dropFirst())
        }
        return nil
    }

    public var isLeaf: Bool { !hasChildren && listReference == nil }

    /// `Label [a, b: c]` — the node's own line, without its number.
    public var text: String {
        let label = OutlineNode.escape(self.label)
        guard !annotations.isEmpty else { return label }
        return label + " [" + annotations.map(\.text).joined(separator: ", ") + "]"
    }

    /// Splits `Label [a, b: c]` into its label and annotations. Only a final
    /// bracketed group is annotations; `\[` writes a literal bracket.
    public static func split(_ text: String) -> (label: String, annotations: [Annotation]) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("]"), let open = openingBracket(of: trimmed) else {
            return (unescape(trimmed), [])
        }
        let label = unescape(trimmed[..<open].trimmingCharacters(in: .whitespaces))
        let inside = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        let annotations = items(in: String(inside)).map(Annotation.init(parsing:)).filter {
            if case .word(let word) = $0 { return !word.isEmpty }
            return true
        }
        return (label, annotations)
    }

    /// The `[` that opens the final group: scanning back from the end, the
    /// first one that isn't escaped or inside quotes.
    static func openingBracket(of text: String) -> String.Index? {
        let characters = Array(text)
        var inQuotes = false
        var index = characters.count - 2
        while index >= 0 {
            let character = characters[index]
            let escaped = index > 0 && characters[index - 1] == "\\"
            if character == "\"" && !escaped {
                inQuotes.toggle()
            } else if character == "[" && !escaped && !inQuotes {
                return text.index(text.startIndex, offsetBy: index)
            }
            index -= 1
        }
        return nil
    }

    /// Splits bracket contents on commas outside quotes.
    private static func items(in text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var escaping = false
        for character in text {
            if escaping {
                current.append(character)
                escaping = false
            } else if character == "\\" {
                current.append(character)
                escaping = true
            } else if character == "\"" {
                current.append(character)
                inQuotes.toggle()
            } else if character == "," && !inQuotes {
                items.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        items.append(current)
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func escape(_ label: String) -> String {
        label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    static func unescape(_ label: String) -> String {
        Annotation.unquoted(label)
    }
}

/// A named set of nodes, used as children with `[@name]`.
public struct OutlineList: Equatable, Sendable {
    public var name: String
    public var nodes: [OutlineNode?]

    public init(name: String, nodes: [OutlineNode?] = OutlineNode.emptyRow) {
        self.name = name
        self.nodes = nodes
    }
}

/// A contact or project: a name and its fields.
public struct OutlineEntry: Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var fields: [Annotation]

    public init(name: String, fields: [Annotation] = []) {
        self.name = name
        self.fields = fields
    }

    public func value(_ key: String) -> String? {
        for case .pair(key, let value) in fields { return value }
        return nil
    }
}

/// A keypad with trees of its own: `# keypad RGB Keypad [RGB Keypad]`.
public struct OutlineKeypad: Equatable, Sendable {
    public var name: String
    /// The model it's for — `RGB Keypad`, `Keybow 2040` — and `id: …` for one
    /// board of a model there are two of.
    public var annotations: [Annotation]
    public var trees: [TreeKind: [OutlineNode?]] = [:]
    /// Its trees set as pages: `# row 2 [pages]` in its section.
    public var pages: Set<TreeKind> = []

    public init(name: String, annotations: [Annotation] = [], trees: [TreeKind: [OutlineNode?]] = [:]) {
        self.name = name
        self.annotations = annotations
        self.trees = trees
    }

    /// The heading's text after `# keypad `.
    public var text: String {
        let name = OutlineNode.escape(name)
        return annotations.isEmpty ? name : name + " [" + annotations.map(\.text).joined(separator: ", ") + "]"
    }

    public var model: KeypadDevice.Model? {
        for case .word(let word) in annotations { if let model = KeypadDevice.Model(words: word) { return model } }
        return nil
    }

    public var id: String? {
        for case .pair("id", let value) in annotations where !value.isEmpty { return value }
        return nil
    }
}

public struct OutlineDocument: Equatable, Sendable {
    /// Lines before anything else — a title, notes — kept as written.
    public var preamble: [String] = []
    /// The first keypad's trees: those before any `# keypad` heading.
    public var trees: [TreeKind: [OutlineNode?]] = [:]
    /// The first keypad's trees set as pages: `# row 2 [pages]`.
    public var pages: Set<TreeKind> = []
    /// Keypads with trees of their own, after the first.
    public var keypads: [OutlineKeypad] = []
    public var lists: [OutlineList] = []
    public var contacts: [OutlineEntry] = []
    public var projects: [OutlineEntry] = []
    /// `commitDelayMs: 1000`, `dates.defaultTime: 09:00`…
    public var defaults: [Annotation] = []
    /// Items that had an item under them skipped for a mistake. One with
    /// nothing left under it is still a branch, not a leaf with an action.
    public var lostChildren: Set<UUID> = []

    public init() {}

    /// A keypad's tree: 0 is the first keypad's, 1… those of `keypads`.
    public func roots(_ tree: TreeKind, keypad: Int = 0) -> [OutlineNode?] {
        if keypad == 0 { return trees[tree] ?? OutlineNode.emptyRow }
        guard keypad <= keypads.count else { return OutlineNode.emptyRow }
        return keypads[keypad - 1].trees[tree] ?? OutlineNode.emptyRow
    }

    public mutating func setRoots(_ roots: [OutlineNode?], _ tree: TreeKind, keypad: Int = 0) {
        if keypad == 0 {
            trees[tree] = roots
        } else if keypad <= keypads.count {
            keypads[keypad - 1].trees[tree] = roots
        }
    }

    /// How many keypads: the first, and one per section.
    public var keypadCount: Int { keypads.count + 1 }

    /// Whether a keypad's tree is pages: its first row picks one, and the
    /// items under each are its keys on the rows below.
    public func isPaged(_ tree: TreeKind, keypad: Int = 0) -> Bool {
        guard tree.canHavePages else { return false }
        if keypad == 0 { return pages.contains(tree) }
        return keypad <= keypads.count && keypads[keypad - 1].pages.contains(tree)
    }

    /// Sets the mark alone; `setPages` checks the tree suits it first.
    mutating func markPaged(_ tree: TreeKind, keypad: Int, _ paged: Bool) {
        if keypad == 0 {
            if paged { pages.insert(tree) } else { pages.remove(tree) }
        } else if keypad <= keypads.count {
            if paged { keypads[keypad - 1].pages.insert(tree) } else { keypads[keypad - 1].pages.remove(tree) }
        }
    }

    /// Every page's keys as a full set of slots — one per key on the rows
    /// below — so any of them can be filled.
    mutating func fillPageSlots() {
        for keypad in 0..<keypadCount {
            for tree in TreeKind.allCases where isPaged(tree, keypad: keypad) {
                let roots = self.roots(tree, keypad: keypad).map { page -> OutlineNode? in
                    guard var page, page.listReference == nil, page.children.count < tree.pageKeys else { return page }
                    page.children += Array(repeating: nil, count: tree.pageKeys - page.children.count)
                    return page
                }
                setRoots(roots, tree, keypad: keypad)
            }
        }
    }
}

public struct OutlineDiagnostic: Equatable, Sendable {
    public enum Severity: Sendable { case error, warning, note }

    public let severity: Severity
    public let line: Int
    public let message: String
    public var nodeID: UUID?

    public init(_ severity: Severity, line: Int, _ message: String, node: UUID? = nil) {
        self.severity = severity
        self.line = line
        self.message = message
        self.nodeID = node
    }
}

// MARK: - Reading

public enum OutlineParser {
    private enum Section {
        case tree(TreeKind, keypad: Int)
        case list(Int)
        case contacts, projects, defaults
    }

    public static func parse(_ text: String) -> (OutlineDocument, [OutlineDiagnostic]) {
        var document = OutlineDocument()
        var diagnostics: [OutlineDiagnostic] = []
        var section: Section?
        var started = false
        /// The keypad tree headings belong to: 0 until a `# keypad` heading.
        var keypad = 0
        // Open items, innermost last: their indent, and the slot path to them
        // within the section — or nil for an item being skipped with its subtree.
        var stack: [(indent: Int, path: [Int]?)] = []

        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#") {
                let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                // `# keypad RGB Keypad [RGB Keypad]`: its own trees follow.
                if title.lowercased().hasPrefix("keypad ") {
                    let (name, annotations) = OutlineNode.split(String(title.dropFirst(7)).trimmingCharacters(in: .whitespaces))
                    document.keypads.append(OutlineKeypad(name: name, annotations: annotations))
                    keypad = document.keypads.count
                    section = .tree(.main, keypad: keypad)
                    stack = []
                    started = true
                    continue
                }
                // `# row 2 [pages]`: what's in brackets says how the tree works.
                let (heading, marks) = OutlineNode.split(title)
                if let next = sectionNamed(heading, keypad: keypad, in: &document) {
                    section = next
                    stack = []
                    started = true
                    for mark in marks {
                        if case .tree(let kind, let keypad) = next, case .word(let word) = mark,
                           word.lowercased() == "pages" {
                            if kind.canHavePages {
                                document.markPaged(kind, keypad: keypad, true)
                            } else {
                                diagnostics.append(.init(.error, line: lineNumber,
                                                         "The bottom tree can't be pages: there are no rows below it."))
                            }
                        } else {
                            diagnostics.append(.init(.warning, line: lineNumber,
                                                     "“\(mark.text)” means nothing on this heading; ignored."))
                        }
                    }
                } else if !started {
                    document.preamble.append(rawLine)
                } else {
                    diagnostics.append(.init(.warning, line: lineNumber, "“\(title)” isn't a section I know; ignored."))
                }
                continue
            }

            // Bulleted entries: contacts, projects, defaults.
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                let body = String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                switch section {
                case .contacts?, .projects?:
                    started = true
                    guard !body.isEmpty else { continue }
                    let (name, fields) = OutlineNode.split(body)
                    let entry = OutlineEntry(name: name, fields: fields)
                    if case .contacts? = section { document.contacts.append(entry) } else { document.projects.append(entry) }
                    continue
                case .defaults?:
                    started = true
                    if case .pair = Annotation(parsing: body) {
                        document.defaults.append(Annotation(parsing: body))
                    } else if !body.isEmpty {
                        diagnostics.append(.init(.warning, line: lineNumber, "Defaults are written “- name: value”; ignored “\(body)”."))
                    }
                    continue
                default:
                    break
                }
            }

            // Numbered items: tree and list nodes.
            let indent = line.prefix { $0 == " " }.count
            let digits = trimmed.prefix { $0.isNumber }
            guard !digits.isEmpty, trimmed.dropFirst(digits.count).first == ".", let number = Int(digits) else {
                if !started && !trimmed.isEmpty { document.preamble.append(rawLine) }
                if !started && trimmed.isEmpty && !document.preamble.isEmpty { document.preamble.append(rawLine) }
                continue
            }
            started = true
            if section == nil { section = .tree(.main, keypad: 0) }
            guard case let container? = section, isNodeSection(container) else {
                diagnostics.append(.init(.warning, line: lineNumber, "Numbered items belong in a tree or a list; ignored."))
                continue
            }

            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            let body = trimmed.dropFirst(digits.count + 1).trimmingCharacters(in: .whitespaces)
            // "3." with nothing after it: an empty key, written for clarity.
            guard !body.isEmpty else { continue }

            let parentPath: [Int]?
            if let last = stack.last {
                parentPath = last.path          // nil when the parent is being skipped
            } else {
                parentPath = []
            }
            guard let parentPath else {
                stack.append((indent, nil))
                continue
            }

            func skipped() {
                stack.append((indent, nil))
                if !parentPath.isEmpty, let parent = node(at: parentPath, in: container, of: document) {
                    document.lostChildren.insert(parent.id)
                }
            }
            // A page's keys fill every row below it; anywhere else, one row.
            var paged: TreeKind?
            if case .tree(let kind, let keypad) = container, document.isPaged(kind, keypad: keypad) { paged = kind }
            if paged != nil, parentPath.count >= 2 {
                diagnostics.append(.init(.error, line: lineNumber,
                                         "Too deep: a page's keys run actions, and can't have keys under them."))
                skipped()
                continue
            }
            let keys = paged != nil && parentPath.count == 1 ? paged!.pageKeys : KeybowProtocol.columns
            guard (1...keys).contains(number) else {
                diagnostics.append(.init(.error, line: lineNumber, keys == KeybowProtocol.columns
                                         ? "Item \(number): keys are numbered 1 to 4."
                                         : "Item \(number): this page's keys are numbered 1 to \(keys)."))
                skipped()
                continue
            }
            let slot = number - 1
            let path = parentPath + [slot]

            if case .tree(let kind, _) = container, path.count > kind.levels {
                diagnostics.append(.init(.error, line: lineNumber,
                                         "Too deep: the \(kind.rawValue) tree has \(kind.levels) levels."))
                skipped()
                continue
            }
            if node(at: path, in: container, of: document) != nil {
                diagnostics.append(.init(.error, line: lineNumber, "A second item \(number) at the same level."))
                skipped()
                continue
            }
            let (label, annotations) = OutlineNode.split(body)
            place(OutlineNode(label: label, annotations: annotations, line: lineNumber),
                  at: path, in: container, of: &document)
            stack.append((indent, path))
        }

        // Trailing blank lines in the preamble are layout, not content.
        while let last = document.preamble.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            document.preamble.removeLast()
        }
        document.fillPageSlots()
        return (document, diagnostics)
    }

    private static func sectionNamed(_ title: String, keypad: Int, in document: inout OutlineDocument) -> Section? {
        let lower = title.lowercased()
        switch lower {
        case "contacts": return .contacts
        case "projects": return .projects
        case "defaults": return .defaults
        default: break
        }
        if lower.hasPrefix("list") {
            let name = title.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: " :"))
            guard !name.isEmpty else { return nil }
            if let index = document.lists.firstIndex(where: { $0.name == name }) { return .list(index) }
            document.lists.append(OutlineList(name: name))
            return .list(document.lists.count - 1)
        }
        let name = title.replacingOccurrences(of: "tree", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        return TreeKind(name: name).map { Section.tree($0, keypad: keypad) }
    }

    private static func isNodeSection(_ section: Section) -> Bool {
        switch section {
        case .tree, .list: return true
        default: return false
        }
    }

    private static func node(at path: [Int], in section: Section, of document: OutlineDocument) -> OutlineNode? {
        var level: [OutlineNode?]
        switch section {
        case .tree(let kind, let keypad): level = document.roots(kind, keypad: keypad)
        case .list(let index): level = document.lists[index].nodes
        default: return nil
        }
        var found: OutlineNode?
        for slot in path {
            guard slot < level.count, let next = level[slot] else { return nil }
            found = next
            level = next.children
        }
        return found
    }

    private static func place(_ node: OutlineNode, at path: [Int], in section: Section, of document: inout OutlineDocument) {
        func insert(_ node: OutlineNode, at path: [Int], into level: inout [OutlineNode?]) {
            if path.count == 1 {
                // A page's keys run on past the first four.
                if path[0] >= level.count { level += Array(repeating: nil, count: path[0] + 1 - level.count) }
                level[path[0]] = node
            } else if var parent = level[path[0]] {
                insert(node, at: Array(path.dropFirst()), into: &parent.children)
                level[path[0]] = parent
            }
        }
        switch section {
        case .tree(let kind, let keypad):
            var roots = document.roots(kind, keypad: keypad)
            insert(node, at: path, into: &roots)
            document.setRoots(roots, kind, keypad: keypad)
        case .list(let index):
            insert(node, at: path, into: &document.lists[index].nodes)
        default:
            break
        }
    }
}

// MARK: - Writing

public enum OutlineWriter {
    /// Three spaces per level, as the outline is usually written by hand.
    static let indentUnit = "   "

    public static func text(_ document: OutlineDocument) -> String {
        var blocks: [String] = []
        if !document.preamble.isEmpty { blocks.append(document.preamble.joined(separator: "\n")) }

        // The first keypad's trees, its main tree first and needing no heading;
        // then each keypad of its own, its main tree right under its heading.
        // A tree that's pages says so on a heading of its own, even empty.
        func trees(_ keypad: Int, under heading: String?) {
            let main = lines(document.roots(.main, keypad: keypad))
            if document.isPaged(.main, keypad: keypad) {
                if let heading { blocks.append(heading) }
                blocks.append((["# main [pages]"] + main).joined(separator: "\n"))
            } else if let heading {
                blocks.append(([heading] + main).joined(separator: "\n"))
            } else if !main.isEmpty {
                blocks.append(main.joined(separator: "\n"))
            }
            for tree in TreeKind.allCases where tree != .main {
                let body = lines(document.roots(tree, keypad: keypad))
                let paged = document.isPaged(tree, keypad: keypad)
                guard !body.isEmpty || paged else { continue }
                var heading: String
                switch tree {
                case .row2: heading = "# row 2"
                case .row3: heading = "# row 3"
                case .bottom: heading = "# bottom"
                case .main: heading = "# main"
                }
                if paged { heading += " [pages]" }
                blocks.append(([heading] + body).joined(separator: "\n"))
            }
        }
        trees(0, under: nil)
        for (index, keypad) in document.keypads.enumerated() {
            trees(index + 1, under: "# keypad " + keypad.text)
        }
        for list in document.lists {
            blocks.append((["# list \(list.name)"] + lines(list.nodes)).joined(separator: "\n"))
        }
        for (heading, entries) in [("# contacts", document.contacts), ("# projects", document.projects)] where !entries.isEmpty {
            let body = entries.map { entry -> String in
                let name = OutlineNode.escape(entry.name)
                return entry.fields.isEmpty ? "- \(name)" : "- \(name) [" + entry.fields.map(\.text).joined(separator: ", ") + "]"
            }
            blocks.append(([heading] + body).joined(separator: "\n"))
        }
        if !document.defaults.isEmpty {
            blocks.append((["# defaults"] + document.defaults.map { "- " + $0.text }).joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    static func lines(_ level: [OutlineNode?], depth: Int = 0) -> [String] {
        var result: [String] = []
        for (slot, node) in level.enumerated() {
            guard let node else { continue }
            result.append(String(repeating: indentUnit, count: depth) + "\(slot + 1). " + node.text)
            result.append(contentsOf: lines(node.children, depth: depth + 1))
        }
        return result
    }
}

// MARK: - Upgrading older outlines

public enum OutlineMigration {
    /// Version 2 outlines put annotations in parentheses. Rewrites a trailing
    /// `(…)` on each numbered item as `[…]`, leaving other parentheses alone.
    public static func bracketize(_ text: String) -> (text: String, changed: Int) {
        var changed = 0
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let digits = trimmed.prefix { $0.isNumber }
            guard !digits.isEmpty, trimmed.dropFirst(digits.count).first == ".",
                  trimmed.hasSuffix(")"), let open = line.lastIndex(of: "(") else { return line }
            let close = line.lastIndex(of: ")")!
            changed += 1
            return String(line[..<open]) + "[" + String(line[line.index(after: open)..<close]) + "]"
                + String(line[line.index(after: close)...])
        }
        return (lines.joined(separator: "\n"), changed)
    }

    /// Adds entries, with empty fields, for the people and projects a tree
    /// refers to but the outline doesn't define — so there is a place to fill
    /// them in.
    public static func addMissingEntries(to document: inout OutlineDocument, from compiled: OutlineCompilation) {
        guard let config = compiled.config else { return }
        for (name, fields) in config.contacts.sorted(by: { $0.key < $1.key })
        where !document.contacts.contains(where: { $0.name == name }) {
            let order = ["phone", "email"]
            let keys = fields.keys.sorted { (order.firstIndex(of: $0) ?? 9, $0) < (order.firstIndex(of: $1) ?? 9, $1) }
            document.contacts.append(OutlineEntry(name: name, fields: keys.map { .pair(key: $0, value: fields[$0] ?? "") }))
        }
        for (name, fields) in config.projects.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending })
        where !document.projects.contains(where: { $0.name == name }) {
            document.projects.append(OutlineEntry(name: name, fields: fields.keys.sorted().map { .pair(key: $0, value: fields[$0] ?? "") }))
        }
    }
}

// MARK: - Positions, for highlighting

/// Where the parts of a node's line are, in UTF-16 offsets (NSRange), so an
/// editor can colour them.
public struct OutlineTokens: Sendable {
    public struct Item: Sendable {
        public let range: NSRange
        public let annotation: Annotation
    }

    public let label: NSRange
    /// The brackets and everything between them, if there are any.
    public let brackets: NSRange?
    public let items: [Item]
}

public enum OutlineSyntax {
    public static func tokens(in text: String) -> OutlineTokens {
        let whole = text as NSString
        let trimmedEnd = text.trimmingCharacters(in: .whitespaces)
        guard trimmedEnd.hasSuffix("]"), let open = OutlineNode.openingBracket(of: text.trimmingTrailingSpaces) else {
            return OutlineTokens(label: NSRange(location: 0, length: whole.length), brackets: nil, items: [])
        }
        let openOffset = NSRange(open..<open, in: text).location
        let closeOffset = (text.trimmingTrailingSpaces as NSString).length - 1
        var labelEnd = openOffset
        while labelEnd > 0, whole.character(at: labelEnd - 1) == 32 { labelEnd -= 1 }

        // Items: split the inside on commas outside quotes, trimming spaces.
        var items: [OutlineTokens.Item] = []
        var start = openOffset + 1
        var inQuotes = false
        var index = start
        func finish(_ end: Int) {
            var from = start, to = end
            while from < to, whole.character(at: from) == 32 { from += 1 }
            while to > from, whole.character(at: to - 1) == 32 { to -= 1 }
            if to > from {
                let range = NSRange(location: from, length: to - from)
                items.append(.init(range: range, annotation: Annotation(parsing: whole.substring(with: range))))
            }
        }
        while index < closeOffset {
            let character = whole.character(at: index)
            if character == 92 { index += 2; continue }                 // backslash escapes the next
            if character == 34 { inQuotes.toggle() }                     // "
            if character == 44 && !inQuotes { finish(index); start = index + 1 }   // ,
            index += 1
        }
        finish(closeOffset)
        return OutlineTokens(label: NSRange(location: 0, length: labelEnd),
                             brackets: NSRange(location: openOffset, length: closeOffset - openOffset + 1),
                             items: items)
    }
}

private extension String {
    var trimmingTrailingSpaces: String {
        var result = self
        while result.last == " " { result.removeLast() }
        return result
    }
}
