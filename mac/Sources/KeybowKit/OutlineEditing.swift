import Foundation

// The edits the tree editor makes, with the rules the keypad imposes: four keys
// to a row, and a depth limit per tree. Each edit either changes the document
// or throws the reason it can't, leaving the document as it was.

/// A tree, or a named list.
public enum OutlineContainer: Hashable, Sendable {
    case tree(TreeKind)
    case list(String)

    /// How deep nodes may go. A list's depth depends on where it's used, so
    /// it's held to three levels, leaving room for at least one above it.
    public var levels: Int {
        switch self {
        case .tree(let kind): return kind.levels
        case .list: return 3
        }
    }
}

/// Where a node sits: its container, and slot indices from the top.
public struct OutlineLocation: Hashable, Sendable {
    public let container: OutlineContainer
    public let path: [Int]

    public init(_ container: OutlineContainer, _ path: [Int]) {
        self.container = container
        self.path = path
    }

    public var parentPath: [Int] { Array(path.dropLast()) }
    public var slot: Int { path.last ?? 0 }
}

public enum OutlineEditError: Error, Equatable, CustomStringConvertible {
    case rowFull
    case tooDeep(levels: Int)
    case nothingAbove
    case aboveUsesList
    case alreadyAtTop
    case atEdge
    case notEmpty
    case notFound

    public var description: String {
        switch self {
        case .rowFull: return "Row full: all four keys are taken."
        case .tooDeep(let levels): return "Too deep: this tree has \(levels) levels."
        case .nothingAbove: return "There's no node above to indent under."
        case .aboveUsesList: return "The node above takes its children from a list."
        case .alreadyAtTop: return "Already on the top row."
        case .atEdge: return "No key beyond this one."
        case .notEmpty: return "That key is already taken."
        case .notFound: return "That node isn't there any more."
        }
    }
}

public enum OutlineEntryKind: Sendable {
    case contacts, projects
}

extension OutlineDocument {
    // MARK: - Finding

    public func location(of id: UUID) -> OutlineLocation? {
        func search(_ level: [OutlineNode?], _ prefix: [Int]) -> [Int]? {
            for (slot, node) in level.enumerated() {
                guard let node else { continue }
                if node.id == id { return prefix + [slot] }
                if let found = search(node.children, prefix + [slot]) { return found }
            }
            return nil
        }
        for kind in TreeKind.allCases {
            if let path = search(roots(kind), []) { return OutlineLocation(.tree(kind), path) }
        }
        for list in lists {
            if let path = search(list.nodes, []) { return OutlineLocation(.list(list.name), path) }
        }
        return nil
    }

    public func node(at location: OutlineLocation) -> OutlineNode? {
        var level = self.level(location.container, parent: [])
        var found: OutlineNode?
        for slot in location.path {
            guard slot >= 0, slot < level.count, let next = level[slot] else { return nil }
            found = next
            level = next.children
        }
        return found
    }

    public func node(_ id: UUID) -> OutlineNode? {
        location(of: id).flatMap { node(at: $0) }
    }

    /// The four slots under `parent` — the container's top row for `[]`.
    public func level(_ container: OutlineContainer, parent: [Int]) -> [OutlineNode?] {
        var level: [OutlineNode?]
        switch container {
        case .tree(let kind): level = roots(kind)
        case .list(let name): level = lists.first { $0.name == name }?.nodes ?? OutlineNode.emptyRow
        }
        for slot in parent {
            guard let next = level[slot] else { return OutlineNode.emptyRow }
            level = next.children
        }
        return level
    }

    private mutating func setLevel(_ container: OutlineContainer, parent: [Int], to newLevel: [OutlineNode?]) {
        func replace(in level: inout [OutlineNode?], at path: [Int]) {
            guard let first = path.first else {
                level = newLevel
                return
            }
            guard var node = level[first] else { return }
            replace(in: &node.children, at: Array(path.dropFirst()))
            level[first] = node
        }
        switch container {
        case .tree(let kind):
            var roots = self.roots(kind)
            replace(in: &roots, at: parent)
            trees[kind] = roots
        case .list(let name):
            if let index = lists.firstIndex(where: { $0.name == name }) {
                replace(in: &lists[index].nodes, at: parent)
            } else {
                var nodes = OutlineNode.emptyRow
                replace(in: &nodes, at: parent)
                lists.append(OutlineList(name: name, nodes: nodes))
            }
        }
    }

    /// Levels a node's subtree occupies: 1 for a leaf.
    static func depth(of node: OutlineNode) -> Int {
        1 + (node.children.compactMap { $0 }.map(depth(of:)).max() ?? 0)
    }

    private func locate(_ id: UUID) throws -> (OutlineLocation, OutlineNode) {
        guard let location = location(of: id), let node = node(at: location) else { throw OutlineEditError.notFound }
        return (location, node)
    }

    // MARK: - Structure

    /// A new, empty node on the first free key after `sibling` — then any free
    /// key before it. With no sibling, on the container's top row.
    @discardableResult
    public mutating func insertNode(after sibling: UUID?, in container: OutlineContainer,
                                    label: String = "") throws -> UUID {
        var parent: [Int] = []
        var start = 0
        if let sibling {
            let (location, _) = try locate(sibling)
            parent = location.parentPath
            start = location.slot + 1
        }
        let row = level(container, parent: parent)
        let order = Array(start..<row.count) + Array(0..<min(start, row.count))
        guard let free = order.first(where: { row[$0] == nil }) else { throw OutlineEditError.rowFull }
        return try insertNode(at: OutlineLocation(container, parent + [free]), label: label)
    }

    /// A new node on a particular empty key — typing into a placeholder.
    @discardableResult
    public mutating func insertNode(at location: OutlineLocation, label: String = "") throws -> UUID {
        guard location.path.count <= location.container.levels else {
            throw OutlineEditError.tooDeep(levels: location.container.levels)
        }
        var row = level(location.container, parent: location.parentPath)
        guard row[location.slot] == nil else { throw OutlineEditError.notEmpty }
        let node = OutlineNode(label: label)
        row[location.slot] = node
        setLevel(location.container, parent: location.parentPath, to: row)
        return node.id
    }

    /// Makes a node the child of the nearest node above it on the same row, on
    /// that node's first free key.
    public mutating func indent(_ id: UUID) throws {
        let (location, node) = try locate(id)
        var row = level(location.container, parent: location.parentPath)
        guard let aboveSlot = (0..<location.slot).last(where: { row[$0] != nil }), var above = row[aboveSlot] else {
            throw OutlineEditError.nothingAbove
        }
        guard above.listReference == nil else { throw OutlineEditError.aboveUsesList }
        guard location.path.count + Self.depth(of: node) <= location.container.levels else {
            throw OutlineEditError.tooDeep(levels: location.container.levels)
        }
        guard let free = above.children.firstIndex(where: { $0 == nil }) else { throw OutlineEditError.rowFull }

        above.children[free] = node
        row[aboveSlot] = above
        row[location.slot] = nil
        setLevel(location.container, parent: location.parentPath, to: row)
    }

    /// Moves a node up to its parent's row, on the first free key after the
    /// parent — then any free key before it.
    public mutating func outdent(_ id: UUID) throws {
        let (location, node) = try locate(id)
        guard location.path.count >= 2 else { throw OutlineEditError.alreadyAtTop }
        let parentPath = location.parentPath
        let parentSlot = parentPath.last!
        let grandparentPath = Array(parentPath.dropLast())
        var upperRow = level(location.container, parent: grandparentPath)
        let order = Array((parentSlot + 1)..<upperRow.count) + Array(0..<parentSlot)
        guard let free = order.first(where: { upperRow[$0] == nil }), var parent = upperRow[parentSlot] else {
            throw OutlineEditError.rowFull
        }

        parent.children[location.slot] = nil
        upperRow[parentSlot] = parent
        upperRow[free] = node
        setLevel(location.container, parent: grandparentPath, to: upperRow)
    }

    /// Moves a node one key left (-1) or right (+1), swapping with whatever is
    /// there, or into it if it's empty.
    public mutating func move(_ id: UUID, by offset: Int) throws {
        let (location, _) = try locate(id)
        var row = level(location.container, parent: location.parentPath)
        let target = location.slot + offset
        guard (0..<row.count).contains(target) else { throw OutlineEditError.atEdge }
        row.swapAt(location.slot, target)
        setLevel(location.container, parent: location.parentPath, to: row)
    }

    public mutating func delete(_ id: UUID) throws {
        let (location, _) = try locate(id)
        var row = level(location.container, parent: location.parentPath)
        row[location.slot] = nil
        setLevel(location.container, parent: location.parentPath, to: row)
    }

    // MARK: - Content

    private mutating func update(_ id: UUID, _ change: (inout OutlineNode) -> Void) throws {
        let (location, node) = try locate(id)
        var changed = node
        change(&changed)
        var row = level(location.container, parent: location.parentPath)
        row[location.slot] = changed
        setLevel(location.container, parent: location.parentPath, to: row)
    }

    /// Sets a node from its line: `Label [annotations]`.
    public mutating func setText(_ id: UUID, _ text: String) throws {
        let (label, annotations) = OutlineNode.split(text)
        try update(id) {
            $0.label = label
            $0.annotations = annotations
        }
    }

    public mutating func setLabel(_ id: UUID, _ label: String) throws {
        try update(id) { $0.label = label }
    }

    /// Sets a `key: value` pair — updating it where it stands, or adding it at
    /// the end. Nil removes it, so an inherited value shows through again.
    public mutating func setPair(_ id: UUID, key: String, value: String?) throws {
        try update(id) { node in
            if let index = node.annotations.firstIndex(where: { $0.key == key }) {
                if let value {
                    node.annotations[index] = .pair(key: key, value: value)
                } else {
                    node.annotations.remove(at: index)
                }
            } else if let value {
                node.annotations.append(.pair(key: key, value: value))
            }
        }
    }

    /// The keyword for each type that has one; the rest are written `type: …`.
    public static let typeKeywords: [String: String] = [
        "notes.create": "Notes",
        "notes.append": "append",
        "calendar.createEvent": "Calendar",
        "reminders.create": "Reminders",
        "messages.compose": "Messages",
        "mail.compose": "Mail",
        "phone.call": "Call",
    ]

    /// Sets this node's own action type, replacing any it named — or, with nil,
    /// removes it so the type is inherited.
    public mutating func setType(_ id: UUID, _ type: String?) throws {
        let typeWords: Set<String> = Set(OutlineCompiler.actionTypeWords.keys).union(["append", "new", "create"])
        try update(id) { node in
            node.annotations.removeAll { annotation in
                switch annotation {
                case .word(let word): return typeWords.contains(word.lowercased())
                case .pair(let key, _): return key == "type"
                }
            }
            guard let type else { return }
            let annotation: Annotation = Self.typeKeywords[type].map(Annotation.word) ?? .pair(key: "type", value: type)
            node.annotations.insert(annotation, at: 0)
        }
    }

    /// Sets a field on a contact or project, adding the entry if it's new.
    public mutating func setEntryField(_ kind: OutlineEntryKind, name: String, key: String, value: String) {
        var entries = kind == .contacts ? contacts : projects
        let index = entries.firstIndex { $0.name == name } ?? {
            entries.append(OutlineEntry(name: name))
            return entries.count - 1
        }()
        if let field = entries[index].fields.firstIndex(where: { $0.key == key }) {
            entries[index].fields[field] = .pair(key: key, value: value)
        } else {
            entries[index].fields.append(.pair(key: key, value: value))
        }
        if kind == .contacts { contacts = entries } else { projects = entries }
    }
}
