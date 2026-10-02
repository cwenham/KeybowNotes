import AppKit
import KeybowKit
import SwiftUI

/// One row: a node, or an empty key between nodes.
final class OutlineRow: NSObject {
    enum Kind: Hashable {
        case node(UUID)
        case empty(OutlineLocation)
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }

    var nodeID: UUID? {
        if case .node(let id) = kind { return id }
        return nil
    }
}

/// An outline view that hands keys to the editor before handling them itself.
final class KeyOutlineView: NSOutlineView {
    var onKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// A row's view: the key number, the text, and a problem marker.
final class OutlineCell: NSTableCellView {
    let badge = NSTextField(labelWithString: "")
    let problem = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let text = NSTextField()
        text.isBordered = false
        text.drawsBackground = false
        text.isEditable = true
        text.lineBreakMode = .byTruncatingTail
        text.cell?.usesSingleLineMode = true
        text.font = .systemFont(ofSize: 13)
        textField = text

        badge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4

        for view in [badge, text, problem] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(equalTo: problem.leadingAnchor, constant: -4),
            problem.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            problem.centerYAnchor.constraint(equalTo: centerYAnchor),
            problem.widthAnchor.constraint(equalToConstant: 14),
            problem.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

struct OutlinePane: NSViewRepresentable {
    let model: EditorModel
    let coordinator: OutlineCoordinator

    func makeNSView(context: Context) -> NSScrollView {
        let outline = KeyOutlineView()
        let column = NSTableColumn(identifier: .init("node"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 24
        outline.indentationPerLevel = 16
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.style = .inset
        outline.usesAutomaticRowHeights = false
        outline.floatsGroupRows = false
        coordinator.attach(outline)

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        // Reading these registers interest, so SwiftUI calls back on change.
        _ = model.revision
        _ = model.tab
        _ = model.keypad
        _ = model.selection
        coordinator.sync()
    }
}

/// Drives the outline view: its rows, editing, and the keys.
@MainActor
final class OutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    private enum AfterEdit {
        case newSibling, newChild, indent, outdent, cancel, selectPrevious, selectNext
    }

    let model: EditorModel
    private weak var outline: KeyOutlineView?
    private var rows: [OutlineRow.Kind: OutlineRow] = [:]
    private var lastRevision = -1
    private var lastContainer: OutlineContainer?
    private var collapsed = Set<UUID>()
    private var afterEdit: AfterEdit?
    private var editingRow: OutlineRow?
    /// A node just made with Return: left empty, it's removed again.
    private var justCreated: UUID?
    private var updatingSelection = false
    /// The placeholder row the outline was last built with, for an empty key
    /// that has no row of its own.
    private var shownPending: OutlineLocation?

    private var highlighter: Highlighter { Highlighter(model: model) }

    init(model: EditorModel) {
        self.model = model
    }

    func attach(_ outline: KeyOutlineView) {
        self.outline = outline
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.onKeyDown = { [weak self] event in self?.keyDown(event) ?? false }
        reload()
    }

    // MARK: - Keeping up with the model

    func sync() {
        if model.revision != lastRevision || model.container != lastContainer || pendingPlaceholder != shownPending {
            reload()
        }
        selectRowForModel()
    }

    /// An empty key that's selected but has no row of its own — past the last
    /// occupied key of its row, or under a node with no children yet — chosen
    /// on the keypad or to start a first child. It gets a placeholder row for
    /// as long as it's selected, so there's somewhere to type.
    private var pendingPlaceholder: OutlineLocation? {
        guard case .empty(let location)? = model.selection, location.container == model.container else { return nil }
        let level = model.document.level(location.container, parent: location.parentPath)
        let last = level.lastIndex(where: { $0 != nil }) ?? -1
        return location.slot > last ? location : nil
    }

    func reload() {
        guard let outline else { return }
        lastRevision = model.revision
        if lastContainer != model.container { collapsed = [] }
        lastContainer = model.container
        shownPending = pendingPlaceholder
        rows = rows.filter { key, _ in
            if case .node(let id) = key { return model.document.location(of: id) != nil }
            return false
        }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        for id in collapsed {
            if let row = rows[.node(id)] { outline.collapseItem(row) }
        }
        selectRowForModel()
    }

    private func row(_ kind: OutlineRow.Kind) -> OutlineRow {
        if let existing = rows[kind] { return existing }
        let row = OutlineRow(kind)
        rows[kind] = row
        return row
    }

    private func selectRowForModel() {
        guard let outline, let selection = model.selection else { return }
        let kind: OutlineRow.Kind
        switch selection {
        case .node(let id): kind = .node(id)
        case .empty(let location): kind = .empty(location)
        }
        // Make sure it's visible: expand whatever it's inside.
        let location: OutlineLocation?
        switch kind {
        case .node(let id): location = model.document.location(of: id)
        case .empty(let empty): location = empty
        }
        if let location {
            for depth in 1..<max(1, location.path.count) {
                let ancestor = OutlineLocation(location.container, Array(location.path.prefix(depth)))
                if let node = model.document.node(at: ancestor), let row = rows[.node(node.id)] {
                    outline.expandItem(row)
                }
            }
        }
        guard let target = rows[kind] else { return }
        let index = outline.row(forItem: target)
        guard index >= 0, outline.selectedRow != index else { return }
        updatingSelection = true
        outline.selectRowIndexes([index], byExtendingSelection: false)
        outline.scrollRowToVisible(index)
        updatingSelection = false
    }

    // MARK: - Rows

    /// The rows under an item: its occupied keys, with the empty keys between
    /// them shown as placeholders. An empty tree offers its first key.
    private func children(of item: Any?) -> [OutlineRow] {
        let container = model.container
        let level: [OutlineNode?]
        let path: [Int]
        if let row = item as? OutlineRow {
            guard case .node(let id) = row.kind, let location = model.document.location(of: id),
                  let node = model.document.node(at: location), node.listReference == nil else { return [] }
            level = node.children
            path = location.path
        } else {
            level = model.document.level(container, parent: [])
            path = []
        }
        var last = level.lastIndex(where: { $0 != nil })
        if let pending = pendingPlaceholder, pending.parentPath == path {
            last = max(last ?? pending.slot, pending.slot)
        }
        guard let last else {
            return item == nil ? [row(.empty(OutlineLocation(container, [0])))] : []
        }
        return (0...last).map { slot in
            if let node = level[slot] { return row(.node(node.id)) }
            return row(.empty(OutlineLocation(container, path + [slot])))
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let row = item as? OutlineRow, let id = row.nodeID, let node = model.node(id),
              node.listReference == nil else { return false }
        if node.hasChildren { return true }
        // A first child being started.
        guard let pending = pendingPlaceholder, let location = model.document.location(of: id) else { return false }
        return pending.parentPath == location.path
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? OutlineRow else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? OutlineCell ?? {
            let cell = OutlineCell()
            cell.identifier = identifier
            return cell
        }()
        configure(cell, for: row)
        return cell
    }

    private func configure(_ cell: OutlineCell, for row: OutlineRow) {
        guard let text = cell.textField else { return }
        text.delegate = self
        switch row.kind {
        case .node(let id):
            guard let location = model.document.location(of: id), let node = model.document.node(at: location) else { return }
            cell.badge.stringValue = "\(location.slot + 1)"
            cell.badge.textColor = .secondaryLabelColor
            cell.badge.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            text.placeholderString = "Label [annotations]"
            text.attributedStringValue = highlighter.attributed(
                node.text, inheritedType: model.inheritedType(above: location), roles: model.info(id)?.roles)
            let problems = model.info(id)?.diagnostics ?? []
            if let worst = problems.min(by: { rank($0.severity) < rank($1.severity) }) {
                let (symbol, colour) = marker(worst.severity)
                cell.problem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "problem")
                cell.problem.contentTintColor = colour
                cell.problem.toolTip = problems.map(\.message).joined(separator: "\n")
                cell.problem.isHidden = false
            } else {
                cell.problem.isHidden = true
            }
            if node.listReference != nil {
                cell.toolTip = "Its children come from the list @\(node.listReference!)"
            } else {
                cell.toolTip = nil
            }
        case .empty(let location):
            cell.badge.stringValue = "\(location.slot + 1)"
            cell.badge.textColor = .tertiaryLabelColor
            cell.badge.layer?.backgroundColor = NSColor.clear.cgColor
            text.stringValue = ""
            text.placeholderString = "key \(location.slot + 1) — empty"
            cell.problem.isHidden = true
            cell.toolTip = nil
        }
    }

    private func rank(_ severity: OutlineDiagnostic.Severity) -> Int {
        switch severity {
        case .error: return 0
        case .warning: return 1
        case .note: return 2
        }
    }

    private func marker(_ severity: OutlineDiagnostic.Severity) -> (String, NSColor) {
        switch severity {
        case .error: return ("exclamationmark.octagon.fill", .systemRed)
        case .warning: return ("exclamationmark.triangle.fill", .systemYellow)
        case .note: return ("info.circle", .systemBlue)
        }
    }

    // MARK: - Selection

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, let outline else { return }
        guard let row = outline.item(atRow: outline.selectedRow) as? OutlineRow else { return }
        switch row.kind {
        case .node(let id): model.selection = .node(id)
        case .empty(let location): model.selection = .empty(location)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let row = notification.userInfo?["NSObject"] as? OutlineRow, let id = row.nodeID { collapsed.insert(id) }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let row = notification.userInfo?["NSObject"] as? OutlineRow, let id = row.nodeID { collapsed.remove(id) }
    }

    private var selectedRow: OutlineRow? {
        guard let outline, outline.selectedRow >= 0 else { return nil }
        return outline.item(atRow: outline.selectedRow) as? OutlineRow
    }

    private func select(_ kind: OutlineRow.Kind) {
        switch kind {
        case .node(let id): model.selection = .node(id)
        case .empty(let location): model.selection = .empty(location)
        }
        selectRowForModel()
    }

    // MARK: - Keys at rest

    private func keyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76:                                            // Return, Enter
            if let row = selectedRow { beginEditing(row) }
            return true
        case 48:                                                // Tab
            if let id = selectedRow?.nodeID {
                flags.contains(.shift) ? outdent(id) : indent(id)
            }
            return true
        case 51, 117:                                           // Delete, forward delete
            if let id = selectedRow?.nodeID { delete(id) }
            return true
        case 125, 126:                                          // ⌃⌘↓, ⌃⌘↑; plain arrows select
            guard let offset = MoveKeys.offset(for: event) else { return false }
            move(by: offset)
            return true
        default:
            break
        }
        // Typing starts editing, replacing the row's text with what's typed.
        if flags.isDisjoint(with: [.command, .control]), let characters = event.characters,
           let first = characters.unicodeScalars.first, !CharacterSet.controlCharacters.contains(first),
           first.value < 0xF700, let row = selectedRow {
            beginEditing(row, replacingWith: characters)
            return true
        }
        return false
    }

    @objc private func doubleClicked() {
        guard let outline, outline.clickedRow >= 0, let row = outline.item(atRow: outline.clickedRow) as? OutlineRow else { return }
        beginEditing(row)
    }

    /// ⌃⌘↑ / ⌃⌘↓, delivered by the window whether or not a row is being edited.
    func move(by offset: Int) {
        endEditing()
        guard let id = selectedRow?.nodeID else { return }
        if model.edit("Move", { try $0.move(id, by: offset) }) {
            reload()
            select(.node(id))
        }
    }

    // MARK: - Structure

    private func indent(_ id: UUID) {
        if model.edit("Indent", { try $0.indent(id) }) {
            if let parent = parentID(of: id) { collapsed.remove(parent) }
            reload()
            select(.node(id))
        }
    }

    private func outdent(_ id: UUID) {
        if model.edit("Outdent", { try $0.outdent(id) }) {
            reload()
            select(.node(id))
        }
    }

    private func delete(_ id: UUID) {
        guard let outline else { return }
        let index = outline.selectedRow
        if model.edit("Delete", { try $0.delete(id) }) {
            reload()
            // Select what's now in its place, or the row above.
            let next = min(index, outline.numberOfRows - 1)
            if next >= 0, let row = outline.item(atRow: next) as? OutlineRow { select(row.kind) }
        }
    }

    private func parentID(of id: UUID) -> UUID? {
        guard let location = model.document.location(of: id), location.path.count > 1 else { return nil }
        return model.document.node(at: OutlineLocation(location.container, location.parentPath))?.id
    }

    /// ⌘Return: start a child of the selected node — or of the one being
    /// edited, once its edit is in.
    func addChild() {
        if editingRow != nil {
            afterEdit = .newChild
            endEditing()
        } else if let id = selectedRow?.nodeID {
            startChild(of: id)
        } else {
            model.flash("Select a node to add a child to.")
        }
    }

    /// Selects the node's first free child key, with a placeholder row to type
    /// into. Nothing is made until something's typed.
    @discardableResult
    private func startChild(of id: UUID) -> Bool {
        guard let location = model.document.location(of: id), let node = model.document.node(at: location) else {
            return false
        }
        if let list = node.listReference {
            model.flash("“\(node.label)” takes its children from @\(list).")
            return false
        }
        guard location.path.count < model.document.levels(location.container) else {
            model.flash(model.document.levels(location.container) == 2
                        ? "“\(node.label)” is a page's key: it runs an action, and can't have keys of its own."
                        : "“\(node.label)” is on this tree's last row, so it can't have children.")
            return false
        }
        guard let slot = model.document.level(location.container, parent: location.path).firstIndex(where: { $0 == nil }) else {
            model.flash("“\(node.label)” already has a node on every key below it.")
            return false
        }
        collapsed.remove(id)
        model.selection = .empty(OutlineLocation(location.container, location.path + [slot]))
        reload()
        guard let placeholder = rows[.empty(OutlineLocation(location.container, location.path + [slot]))] else {
            return false
        }
        beginEditing(placeholder)
        return true
    }

    // MARK: - Editing a row

    func beginEditing(_ row: OutlineRow, replacingWith initial: String? = nil) {
        guard let outline else { return }
        select(row.kind)
        let index = outline.row(forItem: row)
        guard index >= 0 else { return }
        editingRow = row
        outline.editColumn(0, row: index, with: nil, select: initial == nil)
        guard let editor = fieldEditor(row: index) else { return }
        if let initial {
            editor.string = initial
            editor.setSelectedRange(NSRange(location: (initial as NSString).length, length: 0))
        } else if case .node(let id) = row.kind, let node = model.node(id) {
            editor.string = node.text
            editor.selectAll(nil)
        }
        rehighlight(editor)
    }

    /// The field editor for a row being edited. In a view-based outline it
    /// belongs to the cell's text field; the outline's own `currentEditor()` is nil.
    private func fieldEditor(row index: Int) -> NSTextView? {
        if let editor = outline?.currentEditor() as? NSTextView { return editor }
        let cell = outline?.view(atColumn: 0, row: index, makeIfNecessary: false) as? NSTableCellView
        return cell?.textField?.currentEditor() as? NSTextView
    }

    private func endEditing() {
        guard let outline, editingRow != nil else { return }
        outline.window?.makeFirstResponder(outline)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
        rehighlight(editor)
    }

    private func rehighlight(_ editor: NSTextView) {
        guard let storage = editor.textStorage, let row = editingRow else { return }
        let location: OutlineLocation?
        switch row.kind {
        case .node(let id): location = model.document.location(of: id)
        case .empty(let empty): location = empty
        }
        let selected = editor.selectedRanges
        storage.beginEditing()
        highlighter.apply(to: storage, inheritedType: location.flatMap { model.inheritedType(above: $0) })
        storage.endEditing()
        editor.selectedRanges = selected
        editor.typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): afterEdit = .newSibling
        case #selector(NSResponder.insertTab(_:)): afterEdit = .indent
        case #selector(NSResponder.insertBacktab(_:)): afterEdit = .outdent
        case #selector(NSResponder.cancelOperation(_:)): afterEdit = .cancel
        case #selector(NSResponder.moveUp(_:)): afterEdit = .selectPrevious
        case #selector(NSResponder.moveDown(_:)): afterEdit = .selectNext
        default: return false
        }
        endEditing()
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let row = editingRow, let field = notification.object as? NSTextField else { return }
        editingRow = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        let action = afterEdit
        afterEdit = nil

        if action == .cancel {
            if let created = justCreated, row.nodeID == created { model.edit("New Node") { try $0.delete(created) } }
            justCreated = nil
            reload()
            return
        }

        // Commit what was typed.
        var current: UUID? = row.nodeID
        switch row.kind {
        case .node(let id):
            if text.isEmpty && id == justCreated {
                // Return on an empty new node takes it away again.
                model.edit("New Node") { try $0.delete(id) }
                justCreated = nil
                reload()
                return
            }
            if text != model.node(id)?.text {
                model.edit("Edit") { try $0.setText(id, text) }
            }
        case .empty(let location):
            guard !text.isEmpty else { reload(); return }
            var newID: UUID?
            model.edit("New Node") { document in
                newID = try document.insertNode(at: location)
                try document.setText(newID!, text)
            }
            current = newID
        }
        justCreated = nil
        reload()
        guard let id = current else { return }
        select(.node(id))

        switch action {
        case .newSibling?:
            // With every key on the row taken, the next node can only go
            // underneath: start a child instead of stopping at a warning.
            if let location = model.document.location(of: id),
               !model.document.level(location.container, parent: location.parentPath).contains(where: { $0 == nil }) {
                if startChild(of: id), let label = model.node(id)?.label {
                    model.flash("That row is full, so the next node goes under “\(label)”. Esc to leave it.")
                }
                return
            }
            var newID: UUID?
            if model.edit("New Node", { newID = try $0.insertNode(after: id, in: model.container) }), let newID {
                justCreated = newID
                reload()
                if let newRow = rows[.node(newID)] { beginEditing(newRow) }
            }
        case .newChild?:
            startChild(of: id)
        case .indent?:
            indent(id)
            if let moved = rows[.node(id)] { beginEditing(moved) }
        case .outdent?:
            outdent(id)
            if let moved = rows[.node(id)] { beginEditing(moved) }
        case .selectPrevious?, .selectNext?:
            guard let outline else { return }
            let index = outline.row(forItem: rows[.node(id)]) + (action == .selectPrevious ? -1 : 1)
            if index >= 0, index < outline.numberOfRows, let next = outline.item(atRow: index) as? OutlineRow {
                select(next.kind)
            }
        default:
            break
        }
    }
}

/// The keys that move a node up or down its row: ⌃⌘↑/↓, as in OmniOutliner,
/// and ⇧⌘↑/↓, since ⌃ and ⇧ are easily mistaken for each other and neither
/// does anything else here.
enum MoveKeys {
    static func offset(for event: NSEvent) -> Int? {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard flags == [.control, .command] || flags == [.shift, .command] else { return nil }
        switch event.keyCode {
        case 126: return -1
        case 125: return 1
        default: return nil
        }
    }
}
