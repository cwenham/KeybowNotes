import KeybowKit
import SwiftUI

/// How each tree looks wherever it's named — the editor's tabs, the overlay's
/// badge — so a colour and a little diagram come to mean that tree.
extension TreeKind {
    /// Kept clear of the key palette's green and purple, so a tree's colour
    /// isn't mistaken for a key's.
    var tint: Color {
        switch self {
        case .main: return .blue
        case .row2: return .teal
        case .row3: return .orange
        case .bottom: return .pink
        }
    }

    /// "starts on row 1 and goes down, four levels"
    var shape: String {
        let levels = ["", "one level", "two levels", "three levels", "four levels"][rows.count]
        return "starts on row \(startRow + 1) and goes \(rows.count > 1 && rows[1] < rows[0] ? "up" : "down"), \(levels)"
    }
}

/// The keypad as a 4 × 4 grid: the tree's starting row at full strength, the
/// rows it goes on to fading in the order it visits them — so the diagram
/// shows which way it runs — and rows it never uses in grey.
struct TreeGridIcon: View {
    let tree: TreeKind
    var cell: CGFloat = 3.5
    var gap: CGFloat = 1

    /// Strength of each row, in the order the tree visits them.
    private static let fade: [Double] = [1, 0.55, 0.38, 0.26]

    var body: some View {
        VStack(spacing: gap) {
            ForEach(0..<KeybowProtocol.rows, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<KeybowProtocol.columns, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: cell * 0.25)
                            .fill(fill(row))
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func fill(_ row: Int) -> Color {
        guard let step = tree.rows.firstIndex(of: row) else { return Color.secondary.opacity(0.22) }
        return tree.tint.opacity(Self.fade[step])
    }
}
