import AppKit
import KeybowKit
import KeybowWindows
import SwiftUI

/// For *Switch Spaces*: every screen, one under another as they're counted
/// from the left, each with a box per desktop — shaped like the screen, in
/// Mission Control's order — and *No change* first. Each screen's field is
/// set here or inherited on its own, and picking what the branch above gives
/// takes the node's own away again, so it inherits.
struct SpacesPicker: View {
    /// What the node writes for a field, if anything.
    let own: (String) -> String?
    /// What the branches above give it, if anything.
    let above: (String) -> String?
    /// "set here", "from Coding".
    let source: (String) -> String
    let set: (String, String?) -> Void

    @State private var layout: SpacesLayout?
    @State private var shortcuts: [Int: DesktopShortcut] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let layout {
                ForEach(layout.screens, id: \.identifier) { screen in
                    screenRow(screen, layout: layout)
                }
                ForEach(notConnected(layout), id: \.self) { number in
                    missingScreenRow(number)
                }
                Text("Screens are counted from the left, and each screen's desktops from 1, as Mission Control "
                     + "shows them. A key switches them with Mission Control's “Switch to Desktop” shortcuts.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Reading the Spaces…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        layout = SystemSpaces.layout()
        shortcuts = SystemSpaces.shortcuts()
    }

    // MARK: - A screen

    private func screenRow(_ screen: SpacesLayout.Screen, layout: SpacesLayout) -> some View {
        let key = SpacesModule.key(forScreen: screen.number)
        let own = own(key), above = above(key)
        let choice = (own ?? above).flatMap(SpacesModule.Choice.init) ?? .unchanged
        let inherited = own == nil
        let box = Self.boxSize(for: screen.frame.size)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Screen \(screen.number)").fontWeight(.medium)
                Text(screen.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if own != nil, above != nil {
                    Button("Use Inherited") { set(key, nil) }
                        .buttonStyle(.link).font(.caption2)
                        .help("Take this screen's choice away, so it's the branch above's.")
                }
                SourceNote(note: source(key))
            }
            .help(Self.help(key))
            if screen.spaces.isEmpty {
                Text(layout.separate ? "macOS lists no Spaces for this screen."
                     : "Shows the main screen's Spaces: “Displays have separate Spaces” is off in Desktop & Dock.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 6) {
                    SpaceBox(label: "No change", size: CGSize(width: 66, height: box.height), selected: choice == .unchanged,
                             inherited: inherited, dashed: true) {
                        choose(.unchanged, key: key, above: above)
                    }
                    .help("Leave screen \(screen.number) as it is when the key is pressed.")
                    ForEach(screen.spaces, id: \.id) { space in
                        spaceBox(space, on: screen, size: box, choice: choice, inherited: inherited, key: key, above: above)
                    }
                    if case .desktop(let number) = choice, screen.desktop(number) == nil {
                        SpaceBox(label: "\(number)?", size: box, selected: true, inherited: inherited, warning: true) {}
                            .help("There's no desktop \(number) on this screen.")
                    }
                }
                footer(for: choice, on: screen)
            }
        }
    }

    @ViewBuilder
    private func spaceBox(_ space: SpacesLayout.Space, on screen: SpacesLayout.Screen, size: CGSize,
                          choice: SpacesModule.Choice, inherited: Bool, key: String, above: String?) -> some View {
        let showing = screen.showing == space.id
        if let desktop = space.desktop {
            SpaceBox(label: String(desktop), size: size, selected: choice == .desktop(desktop), inherited: inherited,
                     showing: showing) {
                choose(.desktop(desktop), key: key, above: above)
            }
            .help(boxHelp(space, showing: showing))
        } else {
            SpaceBox(symbol: "arrow.up.left.and.arrow.down.right", size: size, showing: showing) {}
                .disabled(true)
                .help("\(space.app ?? "An app")'s full-screen space. Mission Control has no shortcut to switch to it.")
        }
    }

    private func boxHelp(_ space: SpacesLayout.Space, showing: Bool) -> String {
        var text = "Desktop \(space.missionControl ?? 0) in Mission Control"
        if let overall = space.missionControl, let shortcut = shortcuts[overall] {
            text += " · \(shortcut.title)"
        } else {
            text += " · no shortcut is on"
        }
        return showing ? text + " · showing now" : text
    }

    /// What's wrong with the screen's choice, if anything.
    @ViewBuilder
    private func footer(for choice: SpacesModule.Choice, on screen: SpacesLayout.Screen) -> some View {
        if case .desktop(let number) = choice {
            if screen.desktop(number) == nil {
                warning("This screen has \(screen.desktops.count) desktop\(screen.desktops.count == 1 ? "" : "s"); "
                        + "Mission Control adds more.")
            } else if let overall = screen.desktop(number)?.missionControl, shortcuts[overall] == nil {
                HStack(alignment: .firstTextBaseline) {
                    warning(overall > DesktopShortcut.most
                        ? "Mission Control has shortcuts for the first \(DesktopShortcut.most) desktops only; this is Desktop \(overall)."
                        : DesktopShortcut.whereToTurnOn(overall))
                    if overall <= DesktopShortcut.most {
                        Button("Open…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption2).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Screens not connected

    /// Screens this node sets that aren't connected now.
    private func notConnected(_ layout: SpacesLayout) -> [Int] {
        guard layout.screens.count < SpacesModule.screenCount else { return [] }
        return ((layout.screens.count + 1)...SpacesModule.screenCount).filter { own(SpacesModule.key(forScreen: $0)) != nil }
    }

    private func missingScreenRow(_ number: Int) -> some View {
        let key = SpacesModule.key(forScreen: number)
        let value = own(key).flatMap(SpacesModule.Choice.init).map { choice -> String in
            if case .desktop(let desktop) = choice { return "desktop \(desktop)" }
            return "no change"
        } ?? (own(key) ?? "")
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Screen \(number)").fontWeight(.medium)
            Text("not connected · \(value)").foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("Remove") { set(key, nil) }.controlSize(.small)
        }
        .help(Self.help(key))
    }

    // MARK: - Choosing

    /// Writes the choice — or, when it's what the branch above gives,
    /// takes the node's own away, so it inherits.
    private func choose(_ choice: SpacesModule.Choice, key: String, above: String?) {
        let inherited = above.flatMap(SpacesModule.Choice.init) ?? .unchanged
        let value = choice == inherited ? nil : choice.written
        // Already so: nothing to undo.
        guard value != own(key) else { return }
        set(key, value)
    }

    private static func help(_ key: String) -> String {
        ModuleRegistry.shared.vocabulary.describe(SpacesModule.type)?.fields.first { $0.key == key }?.help ?? ""
    }

    /// A desktop's box: the screen's shape, within 44 by 28 points.
    static func boxSize(for screen: CGSize) -> CGSize {
        let most = CGSize(width: 44, height: 28)
        guard screen.width > 0, screen.height > 0 else { return CGSize(width: 44, height: 25) }
        let aspect = screen.width / screen.height
        if aspect >= most.width / most.height {
            return CGSize(width: most.width, height: max(most.width / aspect, 14).rounded())
        }
        return CGSize(width: max(most.height * aspect, 16).rounded(), height: most.height)
    }
}

/// One space: a desktop's number, No change, or an app's full screen.
private struct SpaceBox: View {
    var label: String?
    var symbol: String?
    let size: CGSize
    var selected = false
    /// Chosen by a branch above, not here.
    var inherited = false
    /// The screen shows it now.
    var showing = false
    var dashed = false
    var warning = false
    let action: () -> Void

    init(label: String, size: CGSize, selected: Bool = false, inherited: Bool = false, showing: Bool = false,
         dashed: Bool = false, warning: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.size = size
        self.selected = selected
        self.inherited = inherited
        self.showing = showing
        self.dashed = dashed
        self.warning = warning
        self.action = action
    }

    init(symbol: String, size: CGSize, showing: Bool, action: @escaping () -> Void) {
        self.symbol = symbol
        self.size = size
        self.showing = showing
        self.action = action
    }

    private var tint: Color { warning ? .orange : .accentColor }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selected ? (inherited ? tint.opacity(0.2) : tint) : Color.secondary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(selected ? tint : Color.secondary.opacity(0.45),
                                      style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: dashed && !selected ? [3, 2] : []))
                    if let label {
                        Text(label)
                            .font(.system(size: 11, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected && !inherited ? Color.white : Color.primary)
                            .lineLimit(1)
                            .fixedSize()
                    } else if let symbol {
                        Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: size.width, height: size.height)
                // The one each screen shows now.
                Circle()
                    .fill(showing ? Color.secondary : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Lays its views out in rows, starting a new one when the width runs out.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                // Along the row's foot, so the dots under the boxes line up.
                subviews[index].place(at: CGPoint(x: x, y: y + row.height - size.height), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
