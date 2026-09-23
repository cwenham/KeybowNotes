import Foundation

/// Turns the navigator's state into the 16 colours the firmware wants.
///
/// - chosen keys stay lit at full strength, so the path is readable at a glance
/// - the row in play shows its options dimmed
/// - rows that cannot be used yet stay dark
public struct Lighting {
    public var chosenLevel: Double = 1.0
    public var optionLevel: Double = 0.35
    public var pendingLevel: Double = 1.0
    public var invalidColour = KeyColour(red: 255, green: 0, blue: 0)

    public init() {}

    public func colours(for navigator: Navigator, config: KeybowConfig, flashing key: Int? = nil) -> [KeyColour] {
        var colours = [KeyColour](repeating: .off, count: KeybowProtocol.keyCount)

        // Rows already decided.
        var level = config.tree
        for (row, column) in navigator.path.enumerated() {
            guard column < level.count, let node = level[column] else { break }
            let base = node.colour ?? config.defaultColour
            colours[KeybowProtocol.key(row: row, column: column)] = scale(base, by: chosenLevel)
            level = node.children
        }

        // The row currently on offer.
        if let row = navigator.currentRow {
            for (column, node) in navigator.currentOptions.enumerated() {
                guard let node else { continue }
                let base = node.colour ?? config.defaultColour
                colours[KeybowProtocol.key(row: row, column: column)] = scale(base, by: optionLevel)
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
