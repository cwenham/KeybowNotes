import Foundation

/// The tree as other apps and AI agents change it: entries named the way a
/// person would — a keypad, a tree, and the labels down to the entry,
/// `Window Management/Left Screen` — and written as the outline has them,
/// `Desk lamp [Home, entity: light.desk_lamp]`. The edits are the tree
/// editor's, with its rules: four keys to a row, and a depth per tree.
public enum TreeControl {
    public struct Problem: Error, Equatable, CustomStringConvertible {
        public let description: String

        public init(_ description: String) {
            self.description = description
        }
    }

    // MARK: Naming

    /// What each keypad's trees are called: "Default", then each section's name.
    public static func keypadNames(_ document: OutlineDocument) -> [String] {
        ["Default"] + document.keypads.map(\.name)
    }

    /// The keypad's trees a name means: "Default" for those before any
    /// section; else a section by its name, its board's ID or its model.
    /// Nothing named: `fallback`.
    public static func keypad(_ name: String?, in document: OutlineDocument, otherwise fallback: Int = 0) throws -> Int {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return min(max(fallback, 0), document.keypads.count)
        }
        if name.caseInsensitiveCompare("Default") == .orderedSame { return 0 }
        let keypads = document.keypads
        if let index = keypads.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            ?? keypads.firstIndex(where: { $0.id?.caseInsensitiveCompare(name) == .orderedSame })
            ?? KeypadDevice.Model(words: name).flatMap({ model in keypads.firstIndex { $0.model == model } }) {
            return index + 1
        }
        throw Problem("There's no keypad “\(name)”. There's " + keypadNames(document).map { "“\($0)”" }.joinedAsList + ".")
    }

    /// "main", "row 2", "row3", "bottom"; nothing named is the main tree.
    public static func tree(_ name: String?) throws -> TreeKind {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return .main }
        if let kind = TreeKind(name: name) { return kind }
        switch name {
        case "1": return .main
        case "2": return .row2
        case "3": return .row3
        case "4": return .bottom
        default: throw Problem("“\(name)” isn't a tree: main, row 2, row 3 or bottom.")
        }
    }

    /// "main", "row 2", "row 3", "bottom".
    public static func treeName(_ tree: TreeKind) -> String {
        switch tree {
        case .main: return "main"
        case .row2: return "row 2"
        case .row3: return "row 3"
        case .bottom: return "bottom"
        }
    }

    /// "Window Management/Left Screen" → its labels.
    public static func path(_ text: String) -> [String] {
        text.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Where the entry is: each label matched without regard to case — a
    /// label with a / in it, too — or a key's number on its row, 1 to 4.
    public static func locate(_ path: [String], in document: OutlineDocument,
                              container: OutlineContainer) throws -> OutlineLocation {
        guard !path.isEmpty else { throw Problem("Name an entry: its labels, like Projects/Fiction.") }
        var slots: [Int] = []
        var rest = path[...]
        while !rest.isEmpty {
            let row = document.level(container, parent: slots)
            var found: (slot: Int, used: Int)?
            // The longest run of parts that's a label: "Notes/Ideas" as one.
            for used in stride(from: rest.count, through: 1, by: -1) {
                let label = rest.prefix(used).joined(separator: "/")
                if let slot = row.firstIndex(where: { $0?.label.caseInsensitiveCompare(label) == .orderedSame }) {
                    found = (slot, used)
                    break
                }
            }
            if found == nil, let number = Int(rest.first!.trimmingCharacters(in: CharacterSet(charactersIn: "#"))),
               (1...row.count).contains(number), row[number - 1] != nil {
                found = (number - 1, 1)
            }
            guard let found else {
                let here = slots.isEmpty ? "at the top" : "under “\(path.prefix(path.count - rest.count).joined(separator: "/"))”"
                let labels = row.compactMap { $0?.label }.map { "“\($0)”" }
                throw Problem("There's no “\(rest.first!)” \(here)."
                              + (labels.isEmpty ? " Nothing's there." : " There's " + labels.joinedAsList + "."))
            }
            slots.append(found.slot)
            rest = rest.dropFirst(found.used)
            if !rest.isEmpty, let list = document.node(at: OutlineLocation(container, slots))?.listReference {
                throw Problem("What's under “\(path.prefix(path.count - rest.count).joined(separator: "/"))” comes "
                              + "from the list @\(list): change it there.")
            }
        }
        return OutlineLocation(container, slots)
    }

    /// The keys down to an entry as the keypad has it — lists filled in —
    /// by labels or key numbers.
    public static func keys(_ path: [String], in config: KeybowConfig, tree: TreeKind) throws -> [Int] {
        guard !path.isEmpty else { throw Problem("Name an entry: its labels, like Projects/Fiction.") }
        var keys: [Int] = []
        var rest = path[...]
        while !rest.isEmpty {
            let row = config.options(in: tree, after: keys)
            var found: (slot: Int, used: Int)?
            for used in stride(from: rest.count, through: 1, by: -1) {
                let label = rest.prefix(used).joined(separator: "/")
                if let slot = row.firstIndex(where: { $0?.label.caseInsensitiveCompare(label) == .orderedSame }) {
                    found = (slot, used)
                    break
                }
            }
            if found == nil, let number = Int(rest.first!.trimmingCharacters(in: CharacterSet(charactersIn: "#"))),
               (1...max(row.count, 1)).contains(number), number <= row.count, row[number - 1] != nil {
                found = (number - 1, 1)
            }
            guard let found else {
                let here = keys.isEmpty ? "at the top of the \(treeName(tree)) tree"
                    : "under “\(path.prefix(path.count - rest.count).joined(separator: "/"))”"
                let labels = row.compactMap { $0?.label }.map { "“\($0)”" }
                throw Problem("There's no “\(rest.first!)” \(here)."
                              + (labels.isEmpty ? " Nothing's there." : " There's " + labels.joinedAsList + "."))
            }
            keys.append(found.slot)
            rest = rest.dropFirst(found.used)
        }
        return keys
    }

    // MARK: Reading

    /// A tree as outline text, each entry numbered by its key.
    public static func outline(_ document: OutlineDocument, keypad: Int, tree: TreeKind) -> String {
        OutlineWriter.lines(document.roots(tree, keypad: keypad), depth: 0).joined(separator: "\n")
    }

    /// Every leaf, with its path: what can be run.
    public static func leaves(_ document: OutlineDocument, keypad: Int, tree: TreeKind) -> [[String]] {
        var found: [[String]] = []
        func walk(_ row: [OutlineNode?], _ above: [String]) {
            for case let node? in row {
                let path = above + [node.label]
                if node.hasChildren || node.listReference != nil { walk(node.children, path) } else { found.append(path) }
            }
        }
        walk(document.roots(tree, keypad: keypad), [])
        return found
    }

    // MARK: Changing

    /// Adds entries — outline text, indented for keys under keys — on the
    /// free keys under `parent`, or on the tree's top row. Says what they
    /// were called.
    @discardableResult
    public static func add(_ text: String, under parent: [String], keypad: Int, tree: TreeKind,
                           to document: inout OutlineDocument) throws -> [String] {
        var nodes = OutlineClipboard.nodes(from: text)
        if nodes.isEmpty {
            // A bare line, without its number: "Desk lamp [Home, …]".
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.contains("\n") else {
                throw Problem("There's nothing to add: write entries as outline lines, like “1. Desk lamp [Home, entity: light.desk_lamp]”.")
            }
            let (label, annotations) = OutlineNode.split(line)
            nodes = [OutlineNode(label: label, annotations: annotations)]
        }
        let container = OutlineContainer.tree(tree, keypad: keypad)
        let place: PastePlace
        if parent.isEmpty {
            place = .at(OutlineLocation(container, [0]))
        } else {
            let location = try locate(parent, in: document, container: container)
            guard let node = document.node(at: location) else { throw Problem("That entry isn't there.") }
            place = .inside(node.id)
        }
        do {
            try document.paste(nodes, place)
        } catch let error as OutlineEditError {
            throw Problem(Self.words(error))
        }
        return nodes.map(\.label)
    }

    /// Removes an entry, with everything under it. Says what it was.
    @discardableResult
    public static func remove(_ path: [String], keypad: Int, tree: TreeKind,
                              from document: inout OutlineDocument) throws -> String {
        let location = try locate(path, in: document, container: .tree(tree, keypad: keypad))
        guard let node = document.node(at: location) else { throw Problem("That entry isn't there.") }
        try document.delete(node.id)
        return node.label
    }

    /// Rewrites an entry's line — `Label [annotations]` — keeping what's
    /// under it.
    public static func change(_ path: [String], to text: String, keypad: Int, tree: TreeKind,
                              in document: inout OutlineDocument) throws {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { throw Problem("An entry needs a label.") }
        let location = try locate(path, in: document, container: .tree(tree, keypad: keypad))
        guard let node = document.node(at: location) else { throw Problem("That entry isn't there.") }
        // Its number, if the line was copied with one.
        let digits = line.prefix { $0.isNumber }
        let body = !digits.isEmpty && line.dropFirst(digits.count).first == "." ? String(line.dropFirst(digits.count + 1)) : line
        try document.setText(node.id, body.trimmingCharacters(in: .whitespaces))
    }

    /// Replaces a whole tree with outline text.
    public static func replace(_ tree: TreeKind, keypad: Int, with text: String, in document: inout OutlineDocument) throws {
        let nodes = OutlineClipboard.nodes(from: text)
        var changed = document
        changed.setRoots(OutlineNode.emptyRow, tree, keypad: keypad)
        // By the numbers written, where they're free: a tree's keys are where they are.
        var placed = OutlineNode.emptyRow
        var unplaced: [OutlineNode] = []
        let numbers = text.components(separatedBy: .newlines).filter { line in
            guard let first = line.first, first.isNumber else { return false }
            return line.drop { $0.isNumber }.first == "."
        }.map { line in Int(line.prefix { $0.isNumber }) ?? 0 }
        for (index, node) in nodes.enumerated() {
            let slot = index < numbers.count ? numbers[index] - 1 : -1
            if (0..<placed.count).contains(slot), placed[slot] == nil { placed[slot] = node } else { unplaced.append(node) }
        }
        guard unplaced.count <= placed.filter({ $0 == nil }).count else {
            throw Problem("A tree's top row has four keys, and this has \(nodes.count) entries.")
        }
        do {
            for (slot, node) in placed.enumerated() {
                guard let node else { continue }
                try changed.paste([node], .at(OutlineLocation(.tree(tree, keypad: keypad), [slot])))
            }
            if !unplaced.isEmpty { try changed.paste(unplaced, .at(OutlineLocation(.tree(tree, keypad: keypad), [0]))) }
        } catch let error as OutlineEditError {
            throw Problem(Self.words(error))
        }
        document = changed
    }

    static func words(_ error: OutlineEditError) -> String {
        let text = error.description
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // MARK: Checking

    /// What compiling an outline would say: mistakes by line, and what was
    /// guessed — for text that hasn't been saved yet.
    public static func check(_ text: String, locateApp: ((String) -> OutlineConverter.AppMatch?)? = nil) -> String {
        let (document, problems) = OutlineParser.parse(text)
        let compiled = OutlineCompiler.compile(document, locateApp: locateApp ?? { _ in nil })
        var lines: [String] = []
        for problem in problems { lines.append("line \(problem.line): couldn't be read — \(problem.message)") }
        for diagnostic in compiled.diagnostics {
            lines.append("line \(diagnostic.line): \(diagnostic.severity == .error ? "mistake" : "note") — \(diagnostic.message)")
        }
        if let error = compiled.configError { lines.append("doesn't compile: \(error)") }
        for left in compiled.leftOut { lines.append("left out: \(left)") }
        for missing in compiled.todo { lines.append("to fill in: \(missing)") }
        for warning in compiled.warnings { lines.append("warning: \(warning)") }
        return lines.isEmpty ? "OK: it compiles, with nothing to say." : lines.joined(separator: "\n")
    }
}
