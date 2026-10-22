import Foundation

// The edits the tree editor makes, with the rules the keypad imposes: four keys
// to a row, and a depth limit per tree. Each edit either changes the document
// or throws the reason it can't, leaving the document as it was.

/// A tree, or a named list.
public enum OutlineContainer: Hashable, Sendable {
    /// A keypad's tree: 0 is the first keypad's, 1… a `# keypad` section's.
    case tree(TreeKind, keypad: Int = 0)
    case list(String)

    /// How deep nodes may go. A list's depth depends on where it's used, so
    /// it's held to three levels, leaving room for at least one above it.
    public var levels: Int {
        switch self {
        case .tree(let kind, _): return kind.levels
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
    /// The bottom tree, with no rows below it for a page's keys.
    case noRoomForPages
    /// Turning pages on with keys under keys: a page's keys run actions.
    case tooDeepForPages
    /// Turning pages on where a key's keys come from a list.
    case pageUsesList
    /// Turning pages off with keys past the first row below.
    case pagesTooBig
    /// Pasting more nodes than there are free keys.
    case notEnoughRoom(free: Int, needed: Int)
    /// Pasting a node with keys past the room there is: a page's, off a page.
    case tooManyKeys(String, keys: Int)
    /// Steps on a key with keys under it, or one taking them from a list.
    case stepsNeedALeaf(String)
    /// Keys under a key that has steps.
    case keyHasSteps(String)
    /// Nesting a step under one that isn't an If, Else if or Else.
    case onlyAConditionTakesSteps
    /// Outdenting a step that's already among its key's own.
    case alreadyOutermost

    public var description: String {
        switch self {
        case .rowFull: return "Full: every key here is taken."
        case .tooDeep(let levels): return "Too deep: this tree has \(levels) levels."
        case .nothingAbove: return "There's no node above to indent under."
        case .aboveUsesList: return "The node above takes its children from a list."
        case .alreadyAtTop: return "Already on the top row."
        case .atEdge: return "No key beyond this one."
        case .notEmpty: return "That key is already taken."
        case .notFound: return "That node isn't there any more."
        case .noRoomForPages: return "The bottom tree can't be pages: there are no rows below it."
        case .tooDeepForPages:
            return "Can't be pages yet: a page's keys run actions, and some here have keys under them."
        case .pageUsesList: return "Can't be pages yet: a key here takes its keys from a list."
        case .pagesTooBig:
            return "Can't stop being pages yet: some pages have keys past the first row below, where a tree has none."
        case .notEnoughRoom(let free, let needed):
            return free == 0 ? "No free key here to paste onto."
                : "Not enough free keys here: \(needed) to paste, \(free) free."
        case .tooManyKeys(let label, let keys):
            return "“\(label)” has keys past \(keys), which only fit on a page."
        case .stepsNeedALeaf(let label):
            return "“\(label)” has keys under it: steps go on a key with nothing under it."
        case .keyHasSteps(let label):
            return "“\(label)” has steps, so it can't have keys under it too."
        case .onlyAConditionTakesSteps:
            return "Only an If, Else if or Else has steps under it: start the step above with “If …”."
        case .alreadyOutermost:
            return "Already one of the key's own steps."
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
        for keypad in 0..<keypadCount {
            for kind in TreeKind.allCases {
                if let path = search(roots(kind, keypad: keypad), []) { return OutlineLocation(.tree(kind, keypad: keypad), path) }
            }
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

    /// A key, or a step, by its ID.
    public func node(_ id: UUID) -> OutlineNode? {
        if let location = location(of: id) { return node(at: location) }
        guard let address = stepAddress(of: id) else { return nil }
        return node(at: address.key)?.step(at: address.path)
    }

    /// The slots under `parent` — the container's top row for `[]`: four, or
    /// under a page, one for every key on the rows below.
    public func level(_ container: OutlineContainer, parent: [Int]) -> [OutlineNode?] {
        var level: [OutlineNode?]
        switch container {
        case .tree(let kind, let keypad): level = roots(kind, keypad: keypad)
        case .list(let name): level = lists.first { $0.name == name }?.nodes ?? OutlineNode.emptyRow
        }
        for slot in parent {
            guard slot < level.count, let next = level[slot] else { return Array(repeating: nil, count: slots(container, parent: parent)) }
            level = next.children
        }
        let count = slots(container, parent: parent)
        if level.count < count { level += Array(repeating: nil, count: count - level.count) }
        return level
    }

    /// How many keys there are under `parent`.
    public func slots(_ container: OutlineContainer, parent: [Int]) -> Int {
        if case .tree(let kind, let keypad) = container, parent.count == 1, isPaged(kind, keypad: keypad) {
            return kind.pageKeys
        }
        return KeybowProtocol.columns
    }

    /// How deep a container's nodes may go: a tree that's pages has two
    /// levels — its pages, and their keys.
    public func levels(_ container: OutlineContainer) -> Int {
        if case .tree(let kind, let keypad) = container, isPaged(kind, keypad: keypad) { return 2 }
        return container.levels
    }

    /// Makes a keypad's tree pages, or a tree again. Refused where the tree
    /// doesn't fit: pages need their keys to be actions, and a tree has room
    /// for only one row of keys under each.
    public mutating func setPages(_ paged: Bool, for tree: TreeKind, keypad: Int = 0) throws {
        guard tree.canHavePages else { throw OutlineEditError.noRoomForPages }
        guard paged != isPaged(tree, keypad: keypad) else { return }
        var roots = self.roots(tree, keypad: keypad)
        if paged {
            let pages = roots.compactMap { $0 }
            guard pages.allSatisfy({ $0.listReference == nil }) else { throw OutlineEditError.pageUsesList }
            guard pages.allSatisfy({ Self.depth(of: $0) <= 2 }) else { throw OutlineEditError.tooDeepForPages }
            markPaged(tree, keypad: keypad, true)
            fillPageSlots()
        } else {
            for (column, page) in roots.enumerated() {
                guard var page else { continue }
                guard !page.children.dropFirst(KeybowProtocol.columns).contains(where: { $0 != nil }) else {
                    throw OutlineEditError.pagesTooBig
                }
                page.children = Array(page.children.prefix(KeybowProtocol.columns))
                roots[column] = page
            }
            setRoots(roots, tree, keypad: keypad)
            markPaged(tree, keypad: keypad, false)
        }
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
        case .tree(let kind, let keypad):
            var roots = self.roots(kind, keypad: keypad)
            replace(in: &roots, at: parent)
            setRoots(roots, kind, keypad: keypad)
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
        guard location.path.count <= levels(location.container) else {
            throw OutlineEditError.tooDeep(levels: levels(location.container))
        }
        if location.path.count > 1, let parent = node(at: OutlineLocation(location.container, location.parentPath)),
           !parent.steps.isEmpty {
            throw OutlineEditError.keyHasSteps(parent.label)
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
        guard above.steps.isEmpty else { throw OutlineEditError.keyHasSteps(above.label) }
        guard location.path.count + Self.depth(of: node) <= levels(location.container) else {
            throw OutlineEditError.tooDeep(levels: levels(location.container))
        }
        let keys = slots(location.container, parent: location.parentPath + [aboveSlot])
        if above.children.count < keys { above.children += Array(repeating: nil, count: keys - above.children.count) }
        guard let free = above.children.firstIndex(where: { $0 == nil }) else { throw OutlineEditError.rowFull }

        above.children[free] = node
        row[aboveSlot] = above
        row[location.slot] = nil
        setLevel(location.container, parent: location.parentPath, to: row)
    }

    /// Moves a node up to its parent's row, on the first free key after the
    /// parent — then any free key before it.
    public mutating func outdent(_ id: UUID) throws {
        let (location, moved) = try locate(id)
        guard location.path.count >= 2 else { throw OutlineEditError.alreadyAtTop }
        let parentPath = location.parentPath
        let parentSlot = parentPath.last!
        let grandparentPath = Array(parentPath.dropLast())
        var upperRow = level(location.container, parent: grandparentPath)
        // A page's key, out among the pages, is a page: with room for keys.
        var node = moved
        let keys = slots(location.container, parent: grandparentPath + [parentSlot])
        if grandparentPath.isEmpty, node.listReference == nil, node.children.count < keys {
            node.children += [OutlineNode?](repeating: nil, count: keys - node.children.count)
        }
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
        if location(of: id) == nil, let address = stepAddress(of: id) {
            try changeSteps(holding: address) { $0.remove(at: address.path.last!) }
            return
        }
        let (location, _) = try locate(id)
        var row = level(location.container, parent: location.parentPath)
        row[location.slot] = nil
        setLevel(location.container, parent: location.parentPath, to: row)
    }

    // MARK: - Content

    private mutating func update(_ id: UUID, _ change: (inout OutlineNode) -> Void) throws {
        if location(of: id) == nil, let address = stepAddress(of: id) {
            try changeSteps(holding: address) { change(&$0[address.path.last!]) }
            return
        }
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

    /// Sets this node's own action type, replacing any it named — or, with nil,
    /// removes it so the type is inherited.
    public mutating func setType(_ id: UUID, _ type: String?,
                                 vocabulary: ActionVocabulary = ModuleRegistry.shared.vocabulary) throws {
        let typeWords = vocabulary.keywords
        try update(id) { node in
            node.annotations.removeAll { annotation in
                switch annotation {
                case .word(let word): return typeWords.contains(word.lowercased())
                case .pair(let key, _): return key == "type"
                }
            }
            guard let type else { return }
            let annotation: Annotation = vocabulary.keyword(for: type).map(Annotation.word) ?? .pair(key: "type", value: type)
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

// MARK: - Keypads

extension OutlineNode {
    /// The same node and everything under it, with fresh IDs: a copy that can
    /// sit beside the original.
    public func copyWithNewIDs() -> OutlineNode {
        var copy = self
        copy.id = UUID()
        copy.line = 0
        copy.children = children.map { $0?.copyWithNewIDs() }
        copy.steps = steps.map { $0.copyWithNewIDs() }
        return copy
    }
}

extension OutlineDocument {
    /// Adds a keypad of its own, and says its number.
    @discardableResult
    public mutating func addKeypad(_ keypad: OutlineKeypad) -> Int {
        keypads.append(keypad)
        return keypads.count
    }

    /// Removes a keypad's section, and its trees with it. The first keypad's
    /// trees, 0, can't be.
    public mutating func removeKeypad(_ index: Int) {
        guard index > 0, index <= keypads.count else { return }
        keypads.remove(at: index - 1)
    }

    /// Fills a keypad's trees with copies of another's.
    public mutating func copyTrees(from source: Int, to target: Int) {
        guard source != target else { return }
        for kind in TreeKind.allCases {
            setRoots(roots(kind, keypad: source).map { $0?.copyWithNewIDs() }, kind, keypad: target)
            markPaged(kind, keypad: target, isPaged(kind, keypad: source))
        }
    }

    /// True when a keypad has no nodes in any tree.
    public func keypadIsEmpty(_ index: Int) -> Bool {
        TreeKind.allCases.allSatisfy { roots($0, keypad: index).allSatisfy { $0 == nil } }
    }
}

// MARK: - Copying and pasting

/// Nodes on the clipboard, as outline text: the lines a tree is written in, so
/// they paste into a text editor — or from one — as well as into a tree.
public enum OutlineClipboard {
    /// The nodes, each numbered by its order, with everything under it.
    public static func text(_ nodes: [OutlineNode]) -> String {
        var lines: [String] = []
        for (index, node) in nodes.enumerated() {
            lines.append("\(index + 1). " + node.text)
            lines += OutlineWriter.stepLines(node.steps, depth: 1)
            lines += OutlineWriter.lines(node.children, depth: 1)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Steps, bulleted, each with the steps under it.
    public static func text(steps: [OutlineNode]) -> String {
        OutlineWriter.stepLines(steps, depth: 0).joined(separator: "\n") + "\n"
    }

    /// Steps from outline text: its bulleted items, nested by indentation —
    /// or, with none, its numbered ones, as steps.
    public static func steps(from text: String) -> [OutlineNode] {
        func asSteps(_ node: OutlineNode) -> OutlineNode {
            .step(node.label, node.annotations, steps: (node.steps + node.children.compactMap { $0 }).map(asSteps))
        }
        return nodes(from: text).map(asSteps)
    }

    /// The most keys anything has: a page on row 1's.
    static let mostKeys = TreeKind.main.pageKeys

    /// New nodes from outline text: numbered or bulleted items, nested by
    /// indentation. Anything else — headings, notes, blank lines — is passed
    /// over. The top items' numbers don't matter, since they go wherever
    /// they're pasted; under them, a number is a key, and a number used twice
    /// or left out takes the next free one.
    public static func nodes(from text: String) -> [OutlineNode] {
        final class Draft {
            let node: OutlineNode
            /// A bullet under a numbered item, or under such a bullet: a step.
            let isStep: Bool
            let isNumbered: Bool
            var children: [(slot: Int?, draft: Draft)] = []
            var steps: [Draft] = []
            init(_ node: OutlineNode, isStep: Bool, isNumbered: Bool) {
                self.node = node
                self.isStep = isStep
                self.isNumbered = isNumbered
            }
        }
        var roots: [Draft] = []
        var open: [(indent: Int, draft: Draft)] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count
            let digits = trimmed.prefix { $0.isNumber }
            let number: Int?
            let body: Substring
            if !digits.isEmpty, trimmed.dropFirst(digits.count).first == "." {
                number = Int(digits)
                body = trimmed.dropFirst(digits.count + 1)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                number = nil
                body = trimmed.dropFirst(2)
            } else {
                continue
            }
            let item = body.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            let (label, annotations) = OutlineNode.split(item)
            while let last = open.last, last.indent >= indent { open.removeLast() }
            let parent = open.last?.draft
            let isStep = number == nil && parent.map { $0.isNumbered || $0.isStep } == true
            let draft = Draft(OutlineNode(label: label, annotations: annotations), isStep: isStep,
                              isNumbered: number != nil)
            if let parent, isStep {
                parent.steps.append(draft)
            } else if let parent {
                parent.children.append((number.map { $0 - 1 }, draft))
            } else {
                roots.append(draft)
            }
            open.append((indent, draft))
        }

        func buildStep(_ draft: Draft) -> OutlineNode {
            .step(draft.node.label, draft.node.annotations, steps: draft.steps.map(buildStep))
        }

        func build(_ draft: Draft) -> OutlineNode {
            var node = draft.node
            var slots = OutlineNode.emptyRow
            for (wanted, child) in draft.children {
                var slot = wanted.flatMap { (0..<mostKeys).contains($0) ? $0 : nil }
                if let taken = slot, taken < slots.count, slots[taken] != nil { slot = nil }
                let at = slot ?? slots.firstIndex(where: { $0 == nil }) ?? slots.count
                guard at < mostKeys else { continue }
                if at >= slots.count { slots += [OutlineNode?](repeating: nil, count: at + 1 - slots.count) }
                slots[at] = build(child)
            }
            node.children = slots
            node.steps = draft.steps.map(buildStep)
            return node
        }
        return roots.map(build)
    }
}

/// Where pasted nodes go.
public enum PastePlace: Equatable, Sendable {
    /// Beside a node: on the free keys after it on its row, then before it.
    case after(UUID)
    /// Under a node: on its free keys.
    case inside(UUID)
    /// On an empty key, then the free keys after it on its row, then before.
    case at(OutlineLocation)
}

extension OutlineDocument {
    /// Of `ids`, those not under another of them, in the order given: what
    /// copying, cutting or deleting them all acts on.
    public func topMost(_ ids: [UUID]) -> [UUID] {
        let chosen = Set(ids)
        func keyIsUnderChosen(_ location: OutlineLocation, including: Bool) -> Bool {
            let depths = including ? Array(1...location.path.count) : Array(1..<max(1, location.path.count))
            return depths.contains { depth in
                let above = OutlineLocation(location.container, Array(location.path.prefix(depth)))
                return node(at: above).map { chosen.contains($0.id) } ?? false
            }
        }
        return ids.filter { id in
            if let location = location(of: id) { return !keyIsUnderChosen(location, including: false) }
            // A step: not under a chosen key, nor a chosen step.
            guard let address = stepAddress(of: id), let key = node(at: address.key) else { return false }
            if keyIsUnderChosen(address.key, including: true) { return false }
            return !(1..<address.path.count).contains { depth in
                key.step(at: Array(address.path.prefix(depth))).map { chosen.contains($0.id) } ?? false
            }
        }
    }

    /// The outline text for copying nodes, each with everything under it —
    /// or steps, bulleted, when only steps are chosen.
    public func clipboardText(_ ids: [UUID]) -> String {
        let chosen = topMost(ids)
        let keys = chosen.filter { location(of: $0) != nil }
        if keys.isEmpty { return OutlineClipboard.text(steps: chosen.compactMap { node($0) }) }
        return OutlineClipboard.text(keys.compactMap { node($0) })
    }

    /// Deletes nodes, each with everything under it.
    public mutating func delete(_ ids: [UUID]) throws {
        for id in topMost(ids) { try delete(id) }
    }

    /// Puts copies of `nodes` on free keys at `place`, in order, and says
    /// which they became. Refused, changing nothing, when they don't fit:
    /// too few free keys, too deep for the tree, or more keys under one than
    /// there's room for.
    @discardableResult
    public mutating func paste(_ nodes: [OutlineNode], _ place: PastePlace) throws -> [UUID] {
        let container: OutlineContainer
        let parent: [Int]
        let order: [Int]
        switch place {
        case .after(let id):
            let (location, _) = try locate(id)
            container = location.container
            parent = location.parentPath
            let count = slots(container, parent: parent)
            order = Array((location.slot + 1)..<count) + Array(0..<location.slot)
        case .inside(let id):
            let (location, node) = try locate(id)
            guard node.listReference == nil else { throw OutlineEditError.aboveUsesList }
            guard node.steps.isEmpty else { throw OutlineEditError.keyHasSteps(node.label) }
            container = location.container
            parent = location.path
            order = Array(0..<slots(container, parent: parent))
        case .at(let location):
            container = location.container
            parent = location.parentPath
            let count = slots(container, parent: parent)
            order = Array(location.slot..<count) + Array(0..<min(location.slot, count))
        }
        guard parent.count < levels(container) else { throw OutlineEditError.tooDeep(levels: levels(container)) }
        var row = level(container, parent: parent)
        let free = order.filter { $0 < row.count && row[$0] == nil }
        guard free.count >= nodes.count else {
            throw OutlineEditError.notEnoughRoom(free: free.count, needed: nodes.count)
        }
        var placed: [UUID] = []
        for (node, slot) in zip(nodes, free) {
            let fitted = try fit(node.copyWithNewIDs(), at: parent + [slot], in: container)
            row[slot] = fitted
            placed.append(fitted.id)
        }
        setLevel(container, parent: parent, to: row)
        return placed
    }

    /// A node made to suit where it's going: refused if it's too deep there,
    /// or has keys past the room there is; else with a slot for every key.
    private func fit(_ node: OutlineNode, at path: [Int], in container: OutlineContainer) throws -> OutlineNode {
        guard path.count - 1 + Self.depth(of: node) <= levels(container) else {
            throw OutlineEditError.tooDeep(levels: levels(container))
        }
        guard node.hasChildren else {
            var leaf = node
            // A page's room for keys, even with none yet.
            leaf.children = [OutlineNode?](repeating: nil, count: slots(container, parent: path))
            return leaf
        }
        let count = slots(container, parent: path)
        guard !node.children.dropFirst(count).contains(where: { $0 != nil }) else {
            throw OutlineEditError.tooManyKeys(node.label, keys: count)
        }
        var fitted = node
        var children = Array(node.children.prefix(count))
        children += [OutlineNode?](repeating: nil, count: count - children.count)
        fitted.children = try children.enumerated().map { slot, child in
            try child.map { try fit($0, at: path + [slot], in: container) }
        }
        return fitted
    }
}

// MARK: - Steps

/// Where a step is: its key, and its place among the key's steps — and in
/// each condition's steps down to it.
public struct StepAddress: Hashable, Sendable {
    public let key: OutlineLocation
    public let path: [Int]

    public init(key: OutlineLocation, path: [Int]) {
        self.key = key
        self.path = path
    }
}

extension OutlineDocument {
    /// Every key in the document, with where it is.
    func everyKey() -> [(OutlineLocation, OutlineNode)] {
        var found: [(OutlineLocation, OutlineNode)] = []
        func walk(_ level: [OutlineNode?], _ container: OutlineContainer, _ prefix: [Int]) {
            for (slot, node) in level.enumerated() {
                guard let node else { continue }
                found.append((OutlineLocation(container, prefix + [slot]), node))
                walk(node.children, container, prefix + [slot])
            }
        }
        for keypad in 0..<keypadCount {
            for kind in TreeKind.allCases { walk(roots(kind, keypad: keypad), .tree(kind, keypad: keypad), []) }
        }
        for list in lists { walk(list.nodes, .list(list.name), []) }
        return found
    }

    /// Where a step is, by its ID; nil for a key, or anything not there.
    public func stepAddress(of id: UUID) -> StepAddress? {
        for (location, key) in everyKey() where !key.steps.isEmpty {
            if let path = key.stepPath(of: id) { return StepAddress(key: location, path: path) }
        }
        return nil
    }

    /// Whether it's one of a key's steps.
    public func isStep(_ id: UUID) -> Bool { stepAddress(of: id) != nil }

    /// Where a key is — or, for a step, its key.
    public func keyLocation(of id: UUID) -> OutlineLocation? {
        location(of: id) ?? stepAddress(of: id)?.key
    }

    /// Whether a key or a step with this ID is still there.
    public func contains(_ id: UUID) -> Bool { keyLocation(of: id) != nil }

    /// The steps from a key's first down to this one: the conditions it's
    /// under, then itself.
    public func stepChain(of id: UUID) -> [OutlineNode] {
        guard let address = stepAddress(of: id), let key = node(at: address.key) else { return [] }
        return (1...address.path.count).compactMap { key.step(at: Array(address.path.prefix($0))) }
    }

    /// Changes the list a step sits in: its key's own steps, or a condition's.
    mutating func changeSteps(holding address: StepAddress, _ change: (inout [OutlineNode]) throws -> Void) throws {
        guard var key = node(at: address.key) else { throw OutlineEditError.notFound }
        try key.changeSteps(holding: address.path, change)
        var row = level(address.key.container, parent: address.key.parentPath)
        row[address.key.slot] = key
        setLevel(address.key.container, parent: address.key.parentPath, to: row)
    }

    /// A new, empty step: at the end of a key's steps, or right after a step.
    /// Refused on a key with keys under it — steps are what a key does.
    @discardableResult
    public mutating func addStep(after id: UUID, label: String = "") throws -> UUID {
        let step = OutlineNode.step(label)
        if let location = location(of: id), let key = node(at: location) {
            guard !key.hasChildren, key.listReference == nil else { throw OutlineEditError.stepsNeedALeaf(key.label) }
            try changeSteps(holding: StepAddress(key: location, path: [key.steps.count])) { $0.append(step) }
            return step.id
        }
        guard let address = stepAddress(of: id) else { throw OutlineEditError.notFound }
        try changeSteps(holding: address) { $0.insert(step, at: address.path.last! + 1) }
        return step.id
    }

    /// Puts a step under the one above it — which must be an If, Else if or
    /// Else — at the end of its steps.
    public mutating func indentStep(_ id: UUID) throws {
        guard let address = stepAddress(of: id), let key = node(at: address.key) else { throw OutlineEditError.notFound }
        let index = address.path.last!
        guard index > 0 else { throw OutlineEditError.nothingAbove }
        let abovePath = Array(address.path.dropLast()) + [index - 1]
        guard let above = key.step(at: abovePath), let step = key.step(at: address.path) else {
            throw OutlineEditError.notFound
        }
        guard above.isCondition else { throw OutlineEditError.onlyAConditionTakesSteps }
        try changeSteps(holding: address) { steps in
            steps.remove(at: index)
            steps[index - 1].steps.append(step)
        }
    }

    /// Takes a step out of the condition it's under, to just after it.
    public mutating func outdentStep(_ id: UUID) throws {
        guard let address = stepAddress(of: id), let key = node(at: address.key),
              let step = key.step(at: address.path) else { throw OutlineEditError.notFound }
        guard address.path.count > 1 else { throw OutlineEditError.alreadyOutermost }
        let conditionPath = Array(address.path.dropLast())
        try changeSteps(holding: address) { $0.remove(at: address.path.last!) }
        try changeSteps(holding: StepAddress(key: address.key, path: conditionPath)) {
            $0.insert(step, at: conditionPath.last! + 1)
        }
    }

    /// Moves a step one place earlier (-1) or later (+1) among its neighbours.
    public mutating func moveStep(_ id: UUID, by offset: Int) throws {
        guard let address = stepAddress(of: id) else { throw OutlineEditError.notFound }
        let index = address.path.last!
        try changeSteps(holding: address) { steps in
            let target = index + offset
            guard steps.indices.contains(target) else { throw OutlineEditError.atEdge }
            steps.swapAt(index, target)
        }
    }

    /// Copies of steps, put after a step or at the end of a key's steps, in
    /// order; says which they became.
    @discardableResult
    public mutating func pasteSteps(_ steps: [OutlineNode], after id: UUID) throws -> [UUID] {
        let copies = steps.map { $0.copyWithNewIDs() }
        if let location = location(of: id), let key = node(at: location) {
            guard !key.hasChildren, key.listReference == nil else { throw OutlineEditError.stepsNeedALeaf(key.label) }
            try changeSteps(holding: StepAddress(key: location, path: [key.steps.count])) { $0 += copies }
        } else {
            guard let address = stepAddress(of: id) else { throw OutlineEditError.notFound }
            try changeSteps(holding: address) { $0.insert(contentsOf: copies, at: address.path.last! + 1) }
        }
        return copies.map(\.id)
    }
}
