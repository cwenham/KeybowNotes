import Foundation

/// Turns the navigator's state into the 16 colours the firmware wants.
///
/// - idle: every tree's first row is on offer, each in its own colours
/// - chosen keys stay lit at full strength, so the path is readable at a glance
/// - the row in play shows its options dimmed
/// - in a side tree, the main tree's top row glows faintly: pressing it escapes
/// - rows that cannot be used yet stay dark
public struct Lighting {
    public var chosenLevel: Double = 1.0
    public var optionLevel: Double = 0.35
    public var escapeLevel: Double = 0.1
    public var invalidColour = KeyColour(red: 255, green: 0, blue: 0)

    public init() {}

    public func colours(for navigator: Navigator, config: KeybowConfig, flashing key: Int? = nil) -> [KeyColour] {
        var colours = [KeyColour](repeating: .off, count: KeybowProtocol.keyCount)

        func paint(row: Int, nodes: [TreeNode?], level: Double) {
            for (column, node) in nodes.enumerated() {
                guard let node else { continue }
                colours[KeybowProtocol.key(row: row, column: column)] =
                    scale(node.colour ?? config.defaultColour, by: level)
            }
        }

        if let tree = navigator.tree {
            // Rows already decided.
            var level = config.roots(tree)
            var usedRows: Set<Int> = []
            for (depth, column) in navigator.path.enumerated() {
                guard column < level.count, let node = level[column] else { break }
                let row = tree.rows[depth]
                usedRows.insert(row)
                colours[KeybowProtocol.key(row: row, column: column)] =
                    scale(node.colour ?? config.defaultColour, by: chosenLevel)
                level = node.children
            }

            // The row on offer.
            if let row = navigator.currentRow {
                usedRows.insert(row)
                paint(row: row, nodes: navigator.currentOptions, level: optionLevel)
            }

            // The escape hatch back to the main tree.
            let top = TreeKind.main.startRow
            if !usedRows.contains(top) {
                paint(row: top, nodes: config.roots(.main), level: escapeLevel)
            }
        } else {
            for tree in TreeKind.allCases {
                paint(row: tree.startRow, nodes: config.roots(tree), level: optionLevel)
            }
        }

        if let key, key >= 0, key < colours.count {
            colours[key] = invalidColour
        }
        return colours
    }

    private func scale(_ colour: KeyColour, by factor: Double) -> KeyColour {
        func channel(_ value: UInt8) -> UInt8 {
            UInt8(max(0, min(255, (Double(value) * factor).rounded())))
        }
        return KeyColour(red: channel(colour.red), green: channel(colour.green), blue: channel(colour.blue))
    }
}
