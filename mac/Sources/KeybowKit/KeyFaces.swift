import Foundation

/// The picture on a key, for keypads with a screen under each key (the Stream
/// Deck). Written in the outline as `icon: …`:
///
/// - `icon: sf:envelope.fill` — one of Apple's SF Symbols
/// - `icon: Icons/mum.png`, `icon: ~/Pictures/x.jpg` — an image file; a path
///   that doesn't start at `/` or `~` is in the tree file's folder
/// - `icon: 📞`, `icon: Hi` — emoji or a few letters, drawn large
public enum KeyIcon: Hashable, Sendable {
    case symbol(String)
    case file(String)
    case text(String)

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tif", "tiff", "bmp", "svg", "pdf",
                                               "icns", "webp"]

    public init?(_ written: String) {
        let text = written.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("sf:") {
            let name = text.dropFirst(3).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            self = .symbol(name)
        } else if let dot = text.lastIndex(of: "."),
                  Self.imageExtensions.contains(String(text[text.index(after: dot)...]).lowercased()),
                  !text.contains(" ") || text.contains("/") {
            self = .file(text)
        } else {
            self = .text(text)
        }
    }

    /// As written in the outline.
    public var written: String {
        switch self {
        case .symbol(let name): return "sf:" + name
        case .file(let path), .text(let path): return path
        }
    }

    /// Where an image file is, given the tree file's folder.
    public func fileURL(relativeTo folder: URL?) -> URL? {
        guard case .file(let path) = self else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return folder?.appendingPathComponent(path)
    }
}

extension Annotation {
    /// Keys that say how a key looks rather than what it does: not values for
    /// templates, and not inherited by the keys under it (except colour).
    public static let appearanceKeys: Set<String> = ["colour", "color", "icon", "caption"]
}

/// A move on a keypad that has keys to spare for it: one level back, or
/// clear everything.
public enum KeypadNavigation: String, Equatable, Sendable {
    case back
    case cancel
}

/// Everything a keypad that draws on its keys needs, each time anything changes.
public struct KeypadView: Sendable {
    public let config: KeybowConfig
    public let tree: TreeKind?
    public let path: [Int]
    public let page: KeypadPage?
    public let currentRow: Int?
    /// A leaf is chosen and waiting to run.
    public let pending: Bool
    /// What a Keybow would light, at full brightness: each key's colour with
    /// its state in it — chosen, on offer, the escape row, a flash, a pulse.
    public let colours: [KeyColour]
    /// The latest of each live key's readings.
    public let readings: [LiveKeySpec: LiveKeyReading]

    public init(config: KeybowConfig, tree: TreeKind?, path: [Int], page: KeypadPage?, currentRow: Int?,
                pending: Bool, colours: [KeyColour], readings: [LiveKeySpec: LiveKeyReading] = [:]) {
        self.readings = readings
        self.config = config
        self.tree = tree
        self.path = path
        self.page = page
        self.currentRow = currentRow
        self.pending = pending
        self.colours = colours
    }
}

/// What one key shows.
public struct KeyFace: Hashable, Sendable {
    public enum Emphasis: Hashable, Sendable {
        /// On offer.
        case normal
        /// Already chosen: on the path.
        case chosen
        /// A control of the keypad's own: Back, Cancel.
        case control
    }

    public var colour: KeyColour
    public var icon: KeyIcon?
    /// Text under the icon, or alone without one.
    public var caption: String?
    public var emphasis: Emphasis
    /// A live key's latest: drawn in place of the icon.
    public var reading: LiveKeyReading?

    public init(colour: KeyColour, icon: KeyIcon? = nil, caption: String? = nil, emphasis: Emphasis = .normal,
                reading: LiveKeyReading? = nil) {
        self.colour = colour
        self.icon = icon
        self.caption = caption
        self.emphasis = emphasis
        self.reading = reading
    }

    /// A tree's key, as its node says it should look.
    public init(node: TreeNode, colour: KeyColour, emphasis: Emphasis = .normal) {
        self.init(colour: colour, icon: node.icon, caption: node.keyCaption, emphasis: emphasis)
    }
}

extension TreeNode {
    /// The text on its key: `caption:`, else the label; `caption: none` for none.
    public var keyCaption: String? {
        guard let caption else { return label }
        let trimmed = caption.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.lowercased() == "none" ? nil : caption
    }
}

/// What pressing a key on a drawn keypad does.
public enum KeyPress: Hashable, Sendable {
    /// Presses this key of the 4×4 keypad the trees are laid out on.
    case key(Int)
    case navigate(KeypadNavigation)
    /// At rest, shows the bottom tree's first row in place of the main tree's,
    /// or back again.
    case showBottomTree(Bool)
    /// Runs a pinned key, by its place among them.
    case pinned(Int)
}

/// Lays the trees out on a keypad with a screen under each key, as folders:
/// the 4×4 keypad's rows become what's on offer at the moment.
///
/// - At rest: the first three rows of the 4×4 keypad, as on a Keybow — each
///   tree's first row, or a row of pages. The column on the right holds a key
///   for the bottom tree, which shifts the view down a row.
/// - Choosing in a tree: the top row is the path so far (press one to go back
///   to it), the next row the options, and the third the main tree's first row
///   when it's an escape from a side tree. On the right, Cancel and Back.
/// - On a page: its keys, up to twelve, with the page's own key on the right to
///   leave it.
/// - Pinned keys, always: along the bottom row from the right. The corner is
///   free in every state but rest, where the bottom tree's key moves up for it;
///   each pinned key past the first covers what the trees would put there.
///
/// Needs at least 5 columns and 3 rows; anything beyond those stays dark.
public struct FolderLayout {
    public struct Slot: Hashable, Sendable {
        public var face: KeyFace?
        public var press: KeyPress?

        public init(face: KeyFace? = nil, press: KeyPress? = nil) {
            self.face = face
            self.press = press
        }
    }

    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    public var fits: Bool { columns >= 5 && rows >= 3 }

    static let controlColour = KeyColour(red: 0x30, green: 0x30, blue: 0x34)

    /// One slot per key, left to right, top to bottom.
    public func slots(for view: KeypadView, showingBottomTree: Bool = false,
                      registry: ModuleRegistry = .shared) -> [Slot] {
        var slots = [Slot](repeating: Slot(), count: columns * rows)
        guard fits else { return slots }
        let config = view.config
        let grid = KeybowProtocol.columns

        func put(_ row: Int, _ column: Int, _ slot: Slot) { slots[row * columns + column] = slot }
        func colour(_ key: Int) -> KeyColour { key < view.colours.count ? view.colours[key] : .off }
        /// A node's face, with its reading if it's a live key.
        func face(_ node: TreeNode, colour: KeyColour, emphasis: KeyFace.Emphasis = .normal, tree: TreeKind,
                  path: [Int]) -> KeyFace {
            var face = KeyFace(node: node, colour: colour, emphasis: emphasis)
            if node.isLeaf, !view.readings.isEmpty,
               let spec = LiveKeySpec(config.resolve(tree: tree, path: path)?.action, registry: registry) {
                face.reading = view.readings[spec]
            }
            return face
        }
        /// A key of the 4×4 keypad, shown as it's lit.
        func keypadKey(_ key: Int, node: TreeNode?, tree: TreeKind, path: [Int]) -> Slot {
            guard let node else { return Slot() }
            return Slot(face: face(node, colour: colour(key), tree: tree, path: path), press: .key(key))
        }
        let pinned = config.roots(.pinned)
        let hasPinned = pinned.contains { $0 != nil }
        func control(_ symbol: String, _ caption: String, _ press: KeyPress) -> Slot {
            Slot(face: KeyFace(colour: Self.controlColour, icon: .symbol(symbol), caption: caption, emphasis: .control),
                 press: press)
        }

        if let tree = view.tree {
            // The path so far.
            var level = config.roots(tree)
            for (depth, column) in view.path.enumerated() where depth < grid {
                guard column < level.count, let node = level[column] else { break }
                let key = KeybowProtocol.key(row: tree.rows[depth], column: column)
                put(0, depth, Slot(face: face(node, colour: node.colour ?? config.defaultColour, emphasis: .chosen,
                                              tree: tree, path: Array(view.path.prefix(depth + 1))),
                                   press: .key(key)))
                level = node.children
            }
            // What's on offer next.
            if let row = view.currentRow {
                let options = config.options(in: tree, after: view.path)
                for (column, node) in options.enumerated() where column < grid {
                    put(1, column, keypadKey(KeybowProtocol.key(row: row, column: column), node: node, tree: tree,
                                             path: view.path + [column]))
                }
            }
            // The way out to the main tree, from a side tree.
            let top = TreeKind.main.startRow
            if tree != .main, !tree.rows.prefix(view.path.count + 1).contains(top) {
                for (column, node) in config.roots(.main).enumerated() where column < grid {
                    put(2, column, keypadKey(KeybowProtocol.key(row: top, column: column), node: node, tree: .main,
                                             path: [column]))
                }
            }
            put(0, 4, control("xmark", "Cancel", .navigate(.cancel)))
            put(1, 4, control("chevron.backward", "Back", .navigate(.back)))
        } else if let page = view.page {
            let roots = config.roots(page.tree)
            if page.column < roots.count, let pageNode = roots[page.column] {
                for (slot, node) in pageNode.children.enumerated() where slot < min(page.tree.pageKeys, 3 * grid) {
                    put(slot / grid, slot % grid, keypadKey(page.tree.key(onPage: slot), node: node, tree: page.tree,
                                                            path: [page.column, slot]))
                }
                // Its own key again leaves it.
                let own = KeybowProtocol.key(row: page.tree.startRow, column: page.column)
                put(0, 4, Slot(face: KeyFace(node: pageNode, colour: pageNode.colour ?? config.defaultColour,
                                             emphasis: .chosen),
                               press: .key(own)))
                put(1, 4, control("chevron.backward", "Back", .key(own)))
            }
        } else {
            let hasBottom = config.roots(.bottom).contains { $0 != nil }
            let shift = showingBottomTree && hasBottom ? 1 : 0
            for row in 0..<3 {
                let keypadRow = row + shift
                guard let tree = TreeKind.starting(at: keypadRow) else { continue }
                for (column, node) in config.roots(tree).enumerated() where column < grid {
                    put(row, column, keypadKey(KeybowProtocol.key(row: keypadRow, column: column), node: node,
                                               tree: tree, path: [column]))
                }
            }
            if hasBottom {
                put(shift == 1 ? 0 : hasPinned ? 1 : 2, 4, shift == 1
                    ? control("chevron.up", "Main", .showBottomTree(false))
                    : control("chevron.down", TreeKind.bottom.title, .showBottomTree(true)))
            }
        }

        // Pinned keys, over whatever's there.
        for (slot, node) in pinned.enumerated() where slot < columns {
            guard let node else { continue }
            let own = node.colour ?? config.defaultColour
            let dimmed = KeyColour(red: UInt8(Double(own.red) * 0.35), green: UInt8(Double(own.green) * 0.35),
                                   blue: UInt8(Double(own.blue) * 0.35))
            put(rows - 1, columns - 1 - slot, Slot(face: face(node, colour: dimmed, tree: .pinned, path: [slot]),
                                                    press: .pinned(slot)))
        }
        return slots
    }
}
