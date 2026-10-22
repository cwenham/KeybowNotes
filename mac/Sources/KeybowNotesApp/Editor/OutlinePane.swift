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

/// An outline view that hands keys to the editor before handling them itself,
/// and Cut, Copy and Paste from the Edit menu while no row is being edited.
final class KeyOutlineView: NSOutlineView, NSMenuItemValidation {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onCommand: ((Selector) -> Void)?
    var canPerform: ((Selector) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    @objc func cut(_ sender: Any?) { onCommand?(#selector(cut(_:))) }
    @objc func copy(_ sender: Any?) { onCommand?(#selector(copy(_:))) }
    @objc func paste(_ sender: Any?) { onCommand?(#selector(paste(_:))) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return false }
        if [#selector(cut(_:)), #selector(copy(_:)), #selector(paste(_:))].contains(action) {
            return canPerform?(action) ?? false
        }
        return responds(to: action)
    }
}

/// A menu item that runs a closure: the outline's right-click menu.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// A row's view: the key number, the text, and a problem marker.
final class OutlineCell: NSTableCellView {
    let badge = NSTextField(labelWithString: "")
    let problem = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let text = NSTextField()
        // Its own cell, for the outline's own field editor.
        let cell = OutlineTextCell(textCell: "")
        cell.isEditable = true
        cell.isScrollable = true
        text.cell = cell
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
        // ⇧ and ⌘ pick several nodes, to cut, copy or delete together.
        outline.allowsMultipleSelection = true
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
final class OutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate,
                                NSMenuDelegate {
    private enum AfterEdit {
        case newSibling, newChild, newStep, indent, outdent, cancel, selectPrevious, selectNext
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
    /// The step made with it: a key's own action, kept as its first step
    /// when it was given a second. Goes with it, if it goes.
    private var justKept: UUID?
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
        outline.onCommand = { [weak self] command in self?.run(command) }
        outline.canPerform = { [weak self] command in self?.canPerform(command) ?? false }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
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
            if case .node(let id) = key { return model.document.contains(id) }
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

    /// Selects the model's row. Left alone when it's one of several selected,
    /// unless `alone`: the model's selection moved, and the rest go.
    private func selectRowForModel(alone: Bool = false) {
        guard let outline, let selection = model.selection else { return }
        let kind: OutlineRow.Kind
        switch selection {
        case .node(let id): kind = .node(id)
        case .empty(let location): kind = .empty(location)
        }
        // Make sure it's visible: expand whatever it's inside.
        let ancestors: [UUID]
        switch kind {
        case .node(let id): ancestors = ancestorIDs(of: id)
        case .empty(let empty): ancestors = keyIDs(above: empty, including: false)
        }
        for ancestor in ancestors {
            if let row = rows[.node(ancestor)] { outline.expandItem(row) }
        }
        guard let target = rows[kind] else { return }
        let index = outline.row(forItem: target)
        guard index >= 0 else { return }
        if alone ? outline.selectedRowIndexes == [index] : outline.selectedRowIndexes.contains(index) { return }
        updatingSelection = true
        outline.selectRowIndexes([index], byExtendingSelection: false)
        outline.scrollRowToVisible(index)
        updatingSelection = false
        model.selectedIDs = target.nodeID.map { [$0] } ?? []
    }

    /// The keys above a place, top down — and the one there, `including` it.
    private func keyIDs(above location: OutlineLocation, including: Bool) -> [UUID] {
        let depths = including ? Array(1...max(1, location.path.count)) : Array(1..<max(1, location.path.count))
        return depths.compactMap { depth in
            model.document.node(at: OutlineLocation(location.container, Array(location.path.prefix(depth))))?.id
        }
    }

    /// What a key or a step is inside, top down: for a step, its key and
    /// the keys above it, then the Ifs it's under.
    private func ancestorIDs(of id: UUID) -> [UUID] {
        if let location = model.document.location(of: id) { return keyIDs(above: location, including: false) }
        guard let address = model.document.stepAddress(of: id) else { return [] }
        return keyIDs(above: address.key, including: true) + model.document.stepChain(of: id).dropLast().map(\.id)
    }

    /// Several nodes selected at once — those just pasted.
    private func selectNodes(_ ids: [UUID]) {
        guard let outline, let first = ids.first else { return }
        let indexes = IndexSet(ids.compactMap { id in rows[.node(id)].map { outline.row(forItem: $0) } }.filter { $0 >= 0 })
        updatingSelection = true
        outline.selectRowIndexes(indexes, byExtendingSelection: false)
        if let top = indexes.first { outline.scrollRowToVisible(top) }
        updatingSelection = false
        model.selection = .node(first)
        model.selectedIDs = ids
    }

    /// The nodes selected, in the outline's order.
    private var selectedNodeIDs: [UUID] {
        guard let outline else { return [] }
        return outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? OutlineRow)?.nodeID }
    }

    // MARK: - Rows

    /// The rows under an item: a key's steps, then its occupied keys, with
    /// the empty keys between them shown as placeholders; or the steps under
    /// an If. An empty tree offers its first key.
    private func children(of item: Any?) -> [OutlineRow] {
        let container = model.container
        let level: [OutlineNode?]
        let path: [Int]
        var steps: [OutlineRow] = []
        if let row = item as? OutlineRow {
            guard case .node(let id) = row.kind else { return [] }
            guard let location = model.document.location(of: id), let node = model.document.node(at: location) else {
                // A step: the steps under it.
                return (model.node(id)?.steps ?? []).map { self.row(.node($0.id)) }
            }
            steps = node.steps.map { self.row(.node($0.id)) }
            guard node.listReference == nil else { return steps }
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
            return item == nil ? [row(.empty(OutlineLocation(container, [0])))] : steps
        }
        return steps + (0...last).map { slot in
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
        guard let row = item as? OutlineRow, let id = row.nodeID, let node = model.node(id) else { return false }
        if !node.steps.isEmpty { return true }
        guard node.listReference == nil else { return false }
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
        (text.cell as? OutlineTextCell)?.fieldEditorProvider = { [weak self] in self?.fieldEditor }
        switch row.kind {
        case .node(let id) where model.document.isStep(id):
            guard let step = model.node(id) else { return }
            cell.badge.stringValue = "•"
            cell.badge.textColor = .secondaryLabelColor
            cell.badge.layer?.backgroundColor = NSColor.clear.cgColor
            text.placeholderString = "[action] — or If {{value}} is …"
            text.attributedStringValue = highlighter.attributed(
                step.text, inheritedType: model.inheritedType(of: id), roles: model.info(id)?.roles, step: true)
            showProblems(of: id, in: cell)
            cell.toolTip = step.isCondition
                ? "A condition: the steps under it run when it holds; an Else's when nothing before it did."
                : "A step: runs once the one above it has finished."
        case .node(let id):
            guard let location = model.document.location(of: id), let node = model.document.node(at: location) else { return }
            cell.badge.stringValue = "\(location.slot + 1)"
            cell.badge.textColor = .secondaryLabelColor
            cell.badge.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            text.placeholderString = "Label [annotations]"
            text.attributedStringValue = highlighter.attributed(
                node.text, inheritedType: model.inheritedType(above: location), roles: model.info(id)?.roles)
            showProblems(of: id, in: cell)
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

    private func showProblems(of id: UUID, in cell: OutlineCell) {
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
        model.selectedIDs = selectedNodeIDs
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
        selectRowForModel(alone: true)
    }

    // MARK: - Keys at rest

    private func keyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76:                                            // Return, Enter; ⇧ for a step
            if flags.contains(.shift) {
                addStep()
            } else if let row = selectedRow {
                beginEditing(row)
            }
            return true
        case 48:                                                // Tab
            if let id = selectedRow?.nodeID {
                flags.contains(.shift) ? outdent(id) : indent(id)
            }
            return true
        case 51, 117:                                           // Delete, forward delete
            delete(selectedNodeIDs)
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
        let isStep = model.document.isStep(id)
        if model.edit(isStep ? "Move Step" : "Move", { try isStep ? $0.moveStep(id, by: offset) : $0.move(id, by: offset) }) {
            reload()
            select(.node(id))
        }
    }

    // MARK: - Structure

    private func indent(_ id: UUID) {
        let isStep = model.document.isStep(id)
        if model.edit("Indent", { try isStep ? $0.indentStep(id) : $0.indent(id) }) {
            if let parent = ancestorIDs(of: id).last { collapsed.remove(parent) }
            reload()
            select(.node(id))
        }
    }

    private func outdent(_ id: UUID) {
        let isStep = model.document.isStep(id)
        if model.edit("Outdent", { try isStep ? $0.outdentStep(id) : $0.outdent(id) }) {
            reload()
            select(.node(id))
        }
    }

    private func delete(_ ids: [UUID], name: String = "Delete") {
        guard let outline, !ids.isEmpty else { return }
        let index = outline.selectedRowIndexes.first ?? outline.selectedRow
        let count = model.document.topMost(ids).count
        if model.edit(count == 1 ? name : "\(name) \(count) Nodes", { try $0.delete(ids) }) {
            reload()
            // Select what's now in its place, or the row above.
            let next = min(index, outline.numberOfRows - 1)
            if next >= 0, let row = outline.item(atRow: next) as? OutlineRow { select(row.kind) }
        }
    }

    // MARK: - Cut, copy and paste

    /// Nodes go on the clipboard as outline text, each with everything under
    /// it, so they paste into another tree, a keypad's own, a list — or a
    /// text editor.
    private func copy(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(model.document.clipboardText(ids), forType: .string)
    }

    private func cut(_ ids: [UUID]) {
        endEditing()
        copy(ids)
        delete(ids, name: "Cut")
    }

    /// Pastes onto free keys at `place`, selecting what was pasted.
    private func paste(_ place: PastePlace) {
        endEditing()
        guard let text = pasteboard.string(forType: .string) else {
            model.flash("There's nothing on the clipboard to paste.")
            return
        }
        // After a step: steps.
        if case .after(let id) = place, model.document.isStep(id) {
            pasteSteps(text, after: id)
            return
        }
        let nodes = OutlineClipboard.nodes(from: text)
        guard !nodes.isEmpty else {
            model.flash("Nothing to paste: the clipboard has no items like “1. Label [annotations]”.")
            return
        }
        if case .inside(let id) = place { collapsed.remove(id) }
        var placed: [UUID] = []
        if model.edit(nodes.count == 1 ? "Paste" : "Paste \(nodes.count) Nodes", { placed = try $0.paste(nodes, place) }) {
            reload()
            selectNodes(placed)
        }
    }

    /// Pastes outline text as steps: after a step, or at the end of a key's.
    private func pasteSteps(_ text: String, after id: UUID) {
        endEditing()
        let steps = OutlineClipboard.steps(from: text)
        guard !steps.isEmpty else {
            model.flash("Nothing to paste: the clipboard has no items like “- Label [annotations]”.")
            return
        }
        var placed: [UUID] = []
        if model.edit(steps.count == 1 ? "Paste Step" : "Paste \(steps.count) Steps", {
            placed = try $0.pasteSteps(steps, after: id)
        }) {
            collapsed.remove(id)
            reload()
            selectNodes(placed)
        }
    }

    /// Where ⌘V pastes: after the selected node, on the selected empty key,
    /// or on the tree's top row.
    private var pastePlace: PastePlace {
        switch model.selection {
        case .node(let id)?: return .after(id)
        case .empty(let location)?: return .at(location)
        case nil: return .at(OutlineLocation(model.container, [0]))
        }
    }

    private var clipboardHasText: Bool {
        pasteboard.availableType(from: [.string]) != nil
    }

    /// The clipboard — or, in a development build trying the editor out with
    /// KEYBOW_DEBUG_PASTEBOARD, a pasteboard of that name, so the person's
    /// own clipboard is left alone.
    private var pasteboard: NSPasteboard {
        if Bundle.main.bundleIdentifier == nil, let name = ProcessInfo.processInfo.environment["KEYBOW_DEBUG_PASTEBOARD"] {
            return NSPasteboard(name: NSPasteboard.Name(name))
        }
        return .general
    }

    private func run(_ command: Selector) {
        switch command {
        case #selector(KeyOutlineView.cut(_:)): cut(selectedNodeIDs)
        case #selector(KeyOutlineView.copy(_:)): copy(selectedNodeIDs)
        case #selector(KeyOutlineView.paste(_:)): paste(pastePlace)
        default: break
        }
    }

    private func canPerform(_ command: Selector) -> Bool {
        command == #selector(KeyOutlineView.paste(_:)) ? clipboardHasText : !selectedNodeIDs.isEmpty
    }

    /// The right-click menu: for the selection when the click was on it, else
    /// for the row clicked.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        guard let outline else { return }
        for item in menuItems(clickedRow: outline.clickedRow) { menu.addItem(item) }
    }

    /// The right-click menu's items for a row, or -1 for none.
    func menuItems(clickedRow clicked: Int) -> [NSMenuItem] {
        guard let outline else { return [] }
        let menu = NSMenu()
        let row = clicked >= 0 ? outline.item(atRow: clicked) as? OutlineRow : nil
        let targets = clicked >= 0 && outline.selectedRowIndexes.contains(clicked)
            ? selectedNodeIDs : (row?.nodeID.map { [$0] } ?? [])
        let count = model.document.topMost(targets).count
        let many = count > 1 ? " \(count) Nodes" : ""
        let canPaste = clipboardHasText

        if !targets.isEmpty {
            menu.addItem(ActionMenuItem("Cut" + many, key: "x") { [weak self] in self?.cut(targets) })
            menu.addItem(ActionMenuItem("Copy" + many, key: "c") { [weak self] in self?.copy(targets) })
        }
        switch row?.kind {
        case .node(let id)? where model.document.isStep(id):
            menu.addItem(ActionMenuItem("Paste After", key: "v", enabled: canPaste) { [weak self] in self?.paste(.after(id)) })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Add Step") { [weak self] in self?.startStep(after: id) })
        case .node(let id)?:
            menu.addItem(ActionMenuItem("Paste After", key: "v", enabled: canPaste) { [weak self] in self?.paste(.after(id)) })
            menu.addItem(ActionMenuItem("Paste Under", enabled: canPaste && canHaveChildren(id)) { [weak self] in
                self?.paste(.inside(id))
            })
            let leaf = model.node(id).map { !$0.hasChildren && $0.listReference == nil } ?? false
            menu.addItem(ActionMenuItem("Paste as Steps", enabled: canPaste && leaf) { [weak self] in
                guard let self, let text = pasteboard.string(forType: .string) else { return }
                pasteSteps(text, after: id)
            })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Add Step", enabled: leaf) { [weak self] in self?.startStep(after: id) })
        case .empty(let location)?:
            menu.addItem(ActionMenuItem("Paste Here", key: "v", enabled: canPaste) { [weak self] in self?.paste(.at(location)) })
        case nil:
            let top = OutlineLocation(model.container, [0])
            menu.addItem(ActionMenuItem("Paste", key: "v", enabled: canPaste) { [weak self] in self?.paste(.at(top)) })
        }
        if !targets.isEmpty {
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Delete" + many) { [weak self] in self?.delete(targets) })
        }
        let items = menu.items
        menu.removeAllItems()
        return items
    }

    /// Whether a node can take children here: not on its tree's last level,
    /// nor taking them from a list.
    private func canHaveChildren(_ id: UUID) -> Bool {
        guard let location = model.document.location(of: id), let node = model.node(id) else { return false }
        return node.listReference == nil && node.steps.isEmpty && location.path.count < model.document.levels(location.container)
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

    /// ⇧Return: a step for the selected key — or after the selected step —
    /// once a row being edited is in.
    func addStep() {
        if editingRow != nil {
            afterEdit = .newStep
            endEditing()
        } else if let id = selectedRow?.nodeID {
            startStep(after: id)
        } else {
            model.flash("Select a key to give it a step.")
        }
    }

    /// A new, empty step to type into: at the end of a key's steps, or after
    /// a step. Left empty, it's taken away again. A key's first: what it did
    /// until now is kept as a step before it — with steps, only they run —
    /// named for what it does, and inheriting all of it.
    private func startStep(after id: UUID) {
        var kept: String?
        if model.document.location(of: id) != nil, let key = model.node(id), key.steps.isEmpty,
           !key.hasChildren, key.listReference == nil {
            if let config = model.keypadConfig, let selection = model.resolved(id) {
                kept = ActionSummary(selection: selection, config: config).verb
            } else {
                kept = "Its own action"
            }
        }
        var newID: UUID?
        var keptID: UUID?
        guard model.edit("New Step", { document in
            if let kept { keptID = try document.addStep(after: id, label: kept) }
            newID = try document.addStep(after: id)
        }), let newID else { return }
        justCreated = newID
        justKept = keptID
        for ancestor in ancestorIDs(of: newID) { collapsed.remove(ancestor) }
        reload()
        if let row = rows[.node(newID)] { beginEditing(row) }
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
        if !node.steps.isEmpty {
            model.flash("“\(node.label)” has steps, so it can't have keys under it too. ⇧↩ adds another step.")
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

    /// The rows' field editor, which offers what can go in the brackets.
    private lazy var fieldEditor: OutlineFieldEditor = {
        let editor = OutlineFieldEditor()
        editor.completer = { [weak self] text, caret in self?.completion(in: text, at: caret) }
        return editor
    }()

    /// What completion offers from, for the row being edited: gathered once
    /// an edit, since the tree doesn't change during one.
    private var completionSources: OutlineCompletionSources?

    private func completion(in text: String, at caret: Int) -> (OutlineCompletion, [String])? {
        guard let completion = OutlineCompletion.at(caret, in: text) else { return nil }
        let sources = completionSources ?? makeCompletionSources()
        completionSources = sources
        return (completion, completion.candidates(sources))
    }

    private func makeCompletionSources() -> OutlineCompletionSources {
        let vocabulary = ModuleRegistry.shared.vocabulary
        var inherited: String?
        switch editingRow?.kind {
        case .node(let id)?: inherited = model.inheritedType(of: id)
        case .empty(let empty)?: inherited = model.inheritedType(above: empty)
        case nil: inherited = nil
        }
        // The {{values}} for its key — or step — when it has one in the tree as it stands.
        var values = ValueCatalog(registry: .shared)
        if case .node(let id)? = editingRow?.kind, let config = model.keypadConfig, let selection = model.resolved(id) {
            values = values.atKey(selection, config: config)
        }
        return OutlineCompletionSources(
            vocabulary: vocabulary, inheritedType: inherited,
            lists: model.document.lists.map(\.name), templates: model.templateFiles(), apps: AppCatalog.all.map(\.name),
            valueKeys: model.document.valueKeys(vocabulary: vocabulary), values: values)
    }

    func beginEditing(_ row: OutlineRow, replacingWith initial: String? = nil) {
        guard let outline else { return }
        completionSources = nil
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
        let inherited: String?
        var step = false
        switch row.kind {
        case .node(let id):
            inherited = model.inheritedType(of: id)
            step = model.document.isStep(id)
        case .empty(let empty):
            inherited = model.inheritedType(above: empty)
        }
        let selected = editor.selectedRanges
        storage.beginEditing()
        highlighter.apply(to: storage, inheritedType: inherited, step: step)
        storage.endEditing()
        editor.selectedRanges = selected
        editor.typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // While completion's list is showing, the keys are its.
        if (textView as? OutlineFieldEditor)?.isCompleting == true { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            afterEdit = NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? .newStep : .newSibling
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
        completionSources = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        let action = afterEdit
        afterEdit = nil

        if action == .cancel {
            if let created = justCreated, row.nodeID == created {
                let kept = justKept
                model.edit(model.document.isStep(created) ? "New Step" : "New Node") {
                    try $0.delete([created] + (kept.map { [$0] } ?? []))
                }
            }
            justKept = nil
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
                let kept = justKept
                justKept = nil
                model.edit(model.document.isStep(id) ? "New Step" : "New Node") {
                    try $0.delete([id] + (kept.map { [$0] } ?? []))
                }
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
        justKept = nil
        reload()
        guard let id = current else { return }
        select(.node(id))

        let isStep = model.document.isStep(id)
        switch action {
        case .newSibling? where isStep, .newStep?:
            startStep(after: id)
        case .newChild? where isStep:
            model.flash("A step has no keys under it. ⇧↩ adds a step after it; Tab puts one under an If.")
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
