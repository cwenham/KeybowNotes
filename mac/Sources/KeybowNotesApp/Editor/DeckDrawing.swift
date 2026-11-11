import KeybowKit
import KeybowStreamDeck
import SwiftUI

/// The tab's trees as a Stream Deck shows them, with the selected node chosen:
/// the same folders layout and the same pictures as on the device. Clicking a
/// key selects what's on it.
struct DeckDrawing: View {
    let model: EditorModel
    /// The background's tint while its slider is dragged, before it's written.
    var tint: Double? = nil

    static let columns = 5
    static let rows = 3

    /// What clicking a key does.
    enum Target: Equatable {
        case select(EditorSelection)
        /// A node in another tree: its tab, then the node.
        case elsewhere(OutlineLocation)
        /// Back to the tab's trees at rest.
        case clear
        case tab(TreeKind)
    }

    struct Key {
        var face: KeyFace?
        var target: Target?
        var selected = false
        /// A place with nothing on it yet, that can be clicked to add something.
        var empty = false
    }

    var body: some View {
        let keys = layout()
        let folder = model.outlineURL.deletingLastPathComponent()
        let renderer = KeyRenderer(size: 144, iconFolder: folder)
        let backdrop = model.keypadConfig?.deckBackground.flatMap { background -> DeckBackdrop? in
            var background = background
            if let tint { background.tint = tint }
            return DeckBackdrop.cached(background, model: StreamDeckModel.all[0], folder: folder)
        }
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(0..<Self.rows, id: \.self) { row in
                GridRow {
                    ForEach(0..<Self.columns, id: \.self) { column in
                        let index = row * Self.columns + column
                        keyView(keys[index], renderer: renderer, behind: backdrop?.slice(index),
                                tint: backdrop?.tint ?? 1)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
    }

    private func keyView(_ key: Key, renderer: KeyRenderer, behind: CGImage?, tint: Double) -> some View {
        let side: CGFloat = 52
        return Button { go(key.target) } label: {
            ZStack {
                if key.face != nil || behind != nil, let image = renderer.image(key.face, behind: behind, tint: tint) {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                } else {
                    Color.black
                }
                if key.empty {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(key.selected ? Color.accentColor : .clear, lineWidth: 3)
                .padding(-3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(key.target == nil)
        .help(help(key))
    }

    private func help(_ key: Key) -> String {
        let caption = key.face?.caption ?? ""
        switch key.target {
        case .clear?: return caption.isEmpty ? "Clear the selection" : "\(caption): clears the selection"
        case .tab(let tree)?: return "Show the \(tree.name) tree"
        case .elsewhere(let location)?:
            if case .tree(let tree, _) = location.container, tree.isPinned { return "\(caption): a pinned key" }
            return "\(caption), in the main tree"
        default: return key.empty ? "An empty key: click to add one here" : caption
        }
    }

    private func go(_ target: Target?) {
        switch target {
        case .select(let selection)?:
            model.selection = selection
        case .elsewhere(let location)?:
            guard case .tree(let tree, _) = location.container else { return }
            model.tab = tree
            // After the tab's change has cleared the selection, not before.
            DispatchQueue.main.async { [model] in
                if let node = model.document.node(at: location) { model.selection = .node(node.id) }
            }
        case .clear?:
            model.selection = nil
        case .tab(let tree)?:
            model.tab = tree
        case nil:
            break
        }
    }

    // MARK: - Laying it out

    private func layout() -> [Key] {
        var keys = trees()
        // The pinned keys, over whatever's there, along the bottom row from the right.
        let keypad = min(model.keypad, model.document.keypads.count)
        let container = OutlineContainer.tree(.pinned, keypad: keypad)
        var selectedSlot: Int?
        switch model.selection {
        case .node(let id)?:
            if let location = model.document.keyLocation(of: id), location.container == container {
                selectedSlot = location.path.first
            }
        case .empty(let location)?:
            if location.container == container { selectedSlot = location.path.first }
        case nil:
            break
        }
        let onPinnedTab = model.tab.isPinned
        for slot in 0..<4 {
            let index = (Self.rows - 1) * Self.columns + Self.columns - 1 - slot
            let location = OutlineLocation(container, [slot])
            if let node = model.document.node(at: location) {
                keys[index].target = onPinnedTab ? .select(.node(node.id)) : .elsewhere(location)
                keys[index].empty = false
            } else if onPinnedTab {
                // Places for more, dashed — over what the trees put there.
                keys[index] = Key(face: keys[index].face, target: .select(.empty(location)), empty: true)
            }
            keys[index].selected = slot == selectedSlot
        }
        return keys
    }

    private func trees() -> [Key] {
        var keys = [Key](repeating: Key(), count: Self.columns * Self.rows)
        guard let config = model.keypadConfig else { return keys }
        let tree = model.tab
        let container = model.container
        let keypad = min(model.keypad, model.document.keypads.count)
        let paged = model.isPaged(tree)
        let now = Date()

        // Where the selection is, in this tab.
        var path: [Int] = []
        var isNode = false
        switch model.selection {
        case .node(let id)?:
            if let location = model.document.keyLocation(of: id), location.container == container {
                path = location.path
                isNode = true
            }
        case .empty(let location)?:
            if location.container == container { path = location.path }
        case nil:
            break
        }

        func node(_ location: OutlineLocation) -> OutlineNode? { model.document.node(at: location) }
        func target(_ location: OutlineLocation, emptyAllowed: Bool) -> (Target?, Bool) {
            if let found = node(location) {
                return (location.container == container ? .select(.node(found.id)) : .elsewhere(location), false)
            }
            return emptyAllowed ? (.select(.empty(location)), true) : (nil, false)
        }

        // The navigator, walked to what the deck would show.
        var navigator = Navigator(config: config, now: now)
        func press(_ key: Int) -> Bool {
            let events = navigator.keyDown(key, at: now)
            _ = navigator.keyUp(key, at: now)
            return !events.contains { if case .invalidPress = $0 { return true } else { return false } }
        }
        var shown: [FolderLayout.Slot] = []
        // Live keys show a made-up reading here: the real ones are on the device.
        var readings: [LiveKeySpec: LiveKeyReading] = [:]
        for key in config.liveKeys() {
            readings[key] = ModuleRegistry.shared.module(handling: key.type)?.standInReading(for: key)
        }
        func lay(showingBottom: Bool = false) {
            let view = KeypadView(config: config, tree: navigator.tree, path: navigator.path, page: navigator.page,
                                  currentRow: navigator.currentRow, pending: false,
                                  colours: Lighting().colours(for: navigator, config: config, now: now),
                                  readings: readings)
            shown = FolderLayout(columns: Self.columns, rows: Self.rows).slots(for: view, showingBottomTree: showingBottom)
            for (index, slot) in shown.enumerated() { keys[index].face = slot.face }
        }

        /// At rest: the trees' first rows, the bottom's in place of the main's
        /// when that's the tab.
        func atRest(selectedRoot: Int?) {
            let hasBottom = config.roots(.bottom).contains { $0 != nil }
            let shift = tree == .bottom && hasBottom ? 1 : 0
            lay(showingBottom: shift == 1)
            for row in 0..<3 {
                guard let kind = TreeKind.starting(at: row + shift) else { continue }
                for column in 0..<4 {
                    let location = OutlineLocation(.tree(kind, keypad: keypad), [column])
                    let (found, empty) = target(location, emptyAllowed: kind == tree)
                    keys[row * Self.columns + column].target = found
                    keys[row * Self.columns + column].empty = empty
                    if kind == tree, column == selectedRoot { keys[row * Self.columns + column].selected = true }
                }
            }
            if hasBottom {
                keys[(shift == 1 ? 0 : 2) * Self.columns + 4].target = .tab(shift == 1 ? .main : .bottom)
            }
        }

        // A page: its keys, with its own on the right.
        if paged, let page = path.first, node(OutlineLocation(container, [page])) != nil,
           press(KeybowProtocol.key(row: tree.startRow, column: page)) {
            lay()
            for slot in 0..<min(tree.pageKeys, 12) {
                let index = (slot / 4) * Self.columns + slot % 4
                let (found, empty) = target(OutlineLocation(container, [page, slot]), emptyAllowed: true)
                keys[index].target = found
                keys[index].empty = empty
                keys[index].selected = path.count == 2 && path[1] == slot
            }
            keys[4].target = target(OutlineLocation(container, [page]), emptyAllowed: false).0
            keys[4].selected = path.count == 1
            keys[9].target = .clear
            return keys
        }
        guard !paged, !path.isEmpty, !tree.isPinned else {
            atRest(selectedRoot: path.first)
            return keys
        }

        // In a tree: a branch selected is chosen, its children on offer; a
        // key with nothing under it is on offer beside its siblings.
        let selectedNode = isNode ? node(OutlineLocation(container, path)) : nil
        let isBranch = selectedNode.map { $0.hasChildren && $0.listReference == nil } ?? false
        let base = isBranch && path.count < tree.levels ? path : Array(path.dropLast())
        for (depth, column) in base.enumerated() where !press(KeybowProtocol.key(row: tree.rows[depth], column: column)) {
            // Not compiled yet, or a mistake on the way: show it at rest.
            navigator = Navigator(config: config, now: now)
            atRest(selectedRoot: path.first)
            return keys
        }
        guard !base.isEmpty else {
            atRest(selectedRoot: path.first)
            return keys
        }
        lay()
        for depth in 0..<base.count {                                  // the path
            keys[depth].target = target(OutlineLocation(container, Array(base.prefix(depth + 1))), emptyAllowed: false).0
        }
        let parent = node(OutlineLocation(container, base))
        if base.count < tree.levels, parent?.listReference == nil {      // on offer
            for column in 0..<4 {
                let (found, empty) = target(OutlineLocation(container, base + [column]), emptyAllowed: true)
                keys[Self.columns + column].target = found
                keys[Self.columns + column].empty = empty
            }
        }
        if tree != .main {                                                // the way out
            for column in 0..<4 where shown[2 * Self.columns + column].face != nil {
                keys[2 * Self.columns + column].target =
                    target(OutlineLocation(.tree(.main, keypad: keypad), [column]), emptyAllowed: false).0
            }
        }
        keys[4].target = .clear                                           // Cancel
        if base.count > 1 {                                               // Back: the level above
            keys[9].target = target(OutlineLocation(container, Array(base.dropLast())), emptyAllowed: false).0
        } else {
            keys[9].target = .clear
        }
        if base == path {
            keys[path.count - 1].selected = true
        } else if let last = path.last {
            keys[Self.columns + last].selected = true
        }
        return keys
    }
}
