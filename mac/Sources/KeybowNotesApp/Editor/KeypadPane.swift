import KeybowKit
import SwiftUI

/// The keypad as it would light with the selected node chosen: its ancestors
/// on their rows, its own row with every sibling, its children dimmed below.
/// Clicking a key selects what's on it.
struct KeypadPane: View {
    let model: EditorModel

    private struct Key {
        var colour: KeyColour?
        var level: Double = 0
        var label = ""
        var selected = false
        var target: EditorSelection?
    }

    var body: some View {
        let keys = layout()
        VStack(alignment: .leading, spacing: 8) {
            Text("Keypad").font(.subheadline.weight(.semibold))
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(0..<KeybowProtocol.rows, id: \.self) { row in
                    GridRow {
                        ForEach(0..<KeybowProtocol.columns, id: \.self) { column in
                            keyView(keys[KeybowProtocol.key(row: row, column: column)])
                        }
                    }
                }
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private var caption: String {
        let tree = model.tab
        if model.isPaged(tree) {
            let rows = tree.levels == 2 ? "row 4" : "rows \(tree.startRow + 2)–4"
            return "Row \(tree.startRow + 1) pages: each key picks a page, whose \(tree.pageKeys) keys fill \(rows) "
                + "and run at once. Click a key to select it."
        }
        let direction = tree == .bottom ? "climbs from row 4" : "runs down from row \(tree.startRow + 1)"
        return "\(tree.title) tree: \(direction), \(tree.levels) levels. Click a key to select it."
    }

    private func keyView(_ key: Key) -> some View {
        let fill: Color = key.colour.map { colour in
            Color(red: Double(colour.red) / 255, green: Double(colour.green) / 255, blue: Double(colour.blue) / 255)
        } ?? .clear
        return Button {
            if let target = key.target { model.selection = target }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(fill.opacity(key.colour == nil ? 0 : max(0.18, key.level)))
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(key.selected ? Color.primary : Color.secondary.opacity(key.colour == nil ? 0.35 : 0.15),
                                  style: StrokeStyle(lineWidth: key.selected ? 2 : 1, dash: key.colour == nil ? [3, 3] : []))
                Text(key.label)
                    .font(.system(size: LabelFit.size(for: key.label, base: 9, weight: key.selected ? .bold : .regular,
                                                      width: 56, smallest: 6.5),
                                  weight: key.selected ? .bold : .regular))
                    .foregroundStyle(key.level > 0.6 ? Color.white : Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(3)
            }
            .frame(width: 64, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(key.target == nil)
        .help(key.label)
    }

    // MARK: - Working out the lights

    private func layout() -> [Key] {
        var keys = [Key](repeating: Key(), count: KeybowProtocol.keyCount)
        let tree = model.tab
        let container = model.container
        let config = model.keypadConfig

        func colour(_ path: [Int]) -> KeyColour {
            config?.node(in: tree, at: path)?.colour ?? config?.defaultColour ?? KeyColour(red: 90, green: 90, blue: 90)
        }
        let paged = model.isPaged(tree)
        func put(_ path: [Int], level: Double, selected: Bool = false) {
            let depth = path.count - 1
            guard depth < (paged ? 2 : tree.levels) else { return }
            // A page's keys fill the rows below it, numbered across then down.
            let index = paged && depth == 1
                ? tree.key(onPage: path[1])
                : KeybowProtocol.key(row: tree.rows[depth], column: path[depth])
            let location = OutlineLocation(container, path)
            if let node = model.document.node(at: location) {
                keys[index] = Key(colour: colour(path), level: level, label: node.label, selected: selected,
                                  target: .node(node.id))
            } else {
                keys[index] = Key(colour: nil, label: "", selected: selected, target: .empty(location))
            }
        }

        // Where the selection is, in this tab.
        var path: [Int]?
        var isNode = false
        switch model.selection {
        case .node(let id)?:
            if let location = model.document.location(of: id), location.container == container {
                path = location.path
                isNode = true
            }
        case .empty(let location)?:
            if location.container == container { path = location.path }
        case nil:
            break
        }

        guard let path else {
            // Nothing chosen: the tree's first row, as the keypad shows it idle.
            for column in 0..<KeybowProtocol.columns { put([column], level: 0.35) }
            return keys
        }

        if paged {
            let page = path[0]
            for column in 0..<KeybowProtocol.columns {             // the pages
                put([column], level: column == page ? 1 : 0.35, selected: path.count == 1 && column == page)
            }
            guard path.count == 2 || isNode else { return keys }
            for slot in 0..<tree.pageKeys {                        // its keys
                let chosen = path.count == 2 && slot == path[1]
                put([page, slot], level: chosen ? 1 : 0.35, selected: chosen)
            }
            return keys
        }

        let depth = path.count - 1
        for level in 0..<depth {                                   // ancestors
            put(Array(path.prefix(level + 1)), level: 1)
        }
        for column in 0..<KeybowProtocol.columns {                 // this row
            let sibling = Array(path.dropLast()) + [column]
            put(sibling, level: column == path.last ? 1 : 0.35, selected: column == path.last)
        }
        if isNode, depth + 1 < tree.levels,                        // children
           let node = model.document.node(at: OutlineLocation(container, path)), node.listReference == nil {
            for column in 0..<KeybowProtocol.columns { put(path + [column], level: 0.3) }
        }
        return keys
    }
}
