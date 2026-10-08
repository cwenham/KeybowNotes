import AppKit
import KeybowKit

/// What's selected in the editor: a node, or an empty key waiting to be typed into.
enum EditorSelection: Hashable {
    case node(UUID)
    case empty(OutlineLocation)
}

/// The tree editor's state: the outline being edited, what's selected, and the
/// latest compilation of it. Every change goes through `edit`, which recompiles
/// and registers undo — so the outline pane, the inspector and the keypad all
/// read one consistent picture.
@MainActor @Observable
final class EditorModel {
    let outlineURL: URL
    var templatesDirectory: URL { outlineURL.deletingLastPathComponent().appendingPathComponent("templates") }

    private(set) var document: OutlineDocument
    private(set) var compilation: OutlineCompilation
    /// Problems found reading the file. Lines they refer to were skipped, and
    /// are lost if the outline is saved.
    private(set) var readProblems: [OutlineDiagnostic]
    /// Bumped on every change, so the outline view knows to reload.
    private(set) var revision = 0
    private(set) var isDirty = false

    var tab: TreeKind = .main
    /// The keypad whose trees are shown: 0 for the first keypad's, 1… a
    /// `# keypad` section's.
    var keypad = 0
    var selection: EditorSelection?
    /// Every node selected in the outline, in its order, when several are:
    /// what Cut, Copy and Delete act on. `selection` is the one shown.
    var selectedIDs: [UUID] = []
    /// A refusal or notice, shown briefly.
    private(set) var message: String?
    private(set) var saveStatus: String?

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var savedText: String
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private let locateApp: (String) -> OutlineConverter.AppMatch?

    /// A working copy — Claude's draft — that's never saved: what it holds
    /// goes into the tree only when the person adds it.
    let isDraft: Bool

    /// The tree at `outlineURL` — or, for a draft, `text` in its place, with
    /// the templates beside the tree still found.
    init(outlineURL: URL, text given: String? = nil, draft: Bool = false) {
        self.outlineURL = outlineURL
        isDraft = draft
        // App lookups hit the disk; the editor asks the same few names often.
        var cache: [String: OutlineConverter.AppMatch?] = [:]
        locateApp = { name in
            if let known = cache[name] { return known }
            let found = AppLocator.locate(name)
            cache[name] = found
            return found
        }

        let text = given ?? OutlineFile(outlineURL).text()
        let (document, problems) = OutlineParser.parse(text)
        self.document = document
        self.readProblems = problems
        self.savedText = text.isEmpty ? "" : OutlineWriter.text(document)
        self.compilation = OutlineCompiler.compile(document, locateApp: locateApp)
    }

    /// The keypads plugged in: USB, in the app — or whatever a test, or a
    /// draft, says instead.
    @ObservationIgnored var connectedKeypads: () -> [KeypadDevice] = { USBSerialPorts.keypads() }

    /// The keypads plugged in, by the trees each uses: 0 for Default.
    func keypadsInUse() -> [Int: [String]] {
        Dictionary(grouping: connectedKeypads()) { device in compilation.config?.keypadIndex(for: device) ?? 0 }
            .mapValues { $0.map(\.model.title) }
    }

    /// Shows trees a keypad that's plugged in uses, rather than Default when
    /// every keypad has a section of its own.
    func showTreesInUse() {
        let users = keypadsInUse()
        if keypad == 0, users[0] == nil, let used = users.keys.min() { keypad = used }
    }

    /// The whole document replaced — by a new draft — as one step to undo.
    func replace(with document: OutlineDocument, name: String) {
        edit(name) { $0 = document }
    }

    var container: OutlineContainer { .tree(tab, keypad: min(keypad, document.keypads.count)) }

    /// Whether the shown keypad's tree is pages.
    func isPaged(_ tree: TreeKind) -> Bool { document.isPaged(tree, keypad: min(keypad, document.keypads.count)) }

    /// The compiled config, with the shown keypad's trees.
    var keypadConfig: KeybowConfig? { compilation.config?.forKeypad(min(keypad, document.keypads.count)) }

    // MARK: - Reading

    func info(_ id: UUID) -> OutlineNodeInfo? { compilation.nodes[id] }

    func node(_ id: UUID) -> OutlineNode? { document.node(id) }

    var selectedNodeID: UUID? {
        if case .node(let id)? = selection { return id }
        return nil
    }

    /// Whether a tree has problems, for the dot on its tab.
    func hasProblems(_ tree: TreeKind) -> Bool {
        compilation.nodes.values.contains { $0.tree == tree && $0.diagnostics.contains { $0.severity == .error || $0.severity == .warning } }
    }

    /// The action type in force above a node — what its own bracket words are
    /// read against, for highlighting as you type.
    func inheritedType(above location: OutlineLocation) -> String? {
        guard location.path.count > 1,
              let parent = document.node(at: OutlineLocation(location.container, location.parentPath)) else { return nil }
        return info(parent.id)?.actionType
    }

    func listNames() -> Set<String> { Set(document.lists.map(\.name)) }

    func role(of annotation: Annotation, inheritedType: String?) -> AnnotationRole {
        OutlineCompiler.role(of: annotation, inheritedType: inheritedType, inheritedApp: nil,
                             listNames: listNames(), locateApp: locateApp)
    }

    func templateExists(_ name: String) -> Bool {
        let url = name.hasPrefix("/") || name.hasPrefix("~")
            ? URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
            : templatesDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Changing

    /// Applies an edit. On refusal, shows the reason and changes nothing.
    /// Returns whether it happened.
    @discardableResult
    func edit(_ name: String, _ change: (inout OutlineDocument) throws -> Void) -> Bool {
        var changed = document
        do {
            try change(&changed)
        } catch let error as OutlineEditError {
            flash(error.description)
            return false
        } catch {
            flash("\(error)")
            return false
        }
        guard changed != document else { return true }
        commit(changed, name: name)
        return true
    }

    private func commit(_ newDocument: OutlineDocument, name: String) {
        let previous = document
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.commit(previous, name: name) }
        }
        undoManager?.setActionName(name)
        document = newDocument
        compilation = OutlineCompiler.compile(document, locateApp: locateApp)
        // A selection that no longer exists (undone away) is dropped.
        if case .node(let id)? = selection, document.location(of: id) == nil { selection = nil }
        selectedIDs = selectedIDs.filter { document.location(of: $0) != nil }
        isDirty = OutlineWriter.text(document) != savedText
        revision += 1
        saveStatus = nil
    }

    func flash(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    // MARK: - Saving

    /// Called after a save, so the app loads the tree at once.
    @ObservationIgnored var onSaved: (() -> Void)?

    /// Reads the file again, after it was changed from outside — by a script
    /// or an agent — while nothing here was unsaved. Undo starts afresh: what
    /// it would undo is gone from the file.
    func reloadFromFile() {
        let text = OutlineFile(outlineURL).text()
        let (document, problems) = OutlineParser.parse(text)
        self.document = document
        readProblems = problems
        savedText = text.isEmpty ? "" : OutlineWriter.text(document)
        compilation = OutlineCompiler.compile(document, locateApp: locateApp)
        isDirty = false
        selection = nil
        selectedIDs = []
        revision += 1
        undoManager?.removeAllActions()
    }

    /// Writes the outline, which is the config: the app compiles it as it
    /// loads it. It's saved even with mistakes; what they touch is left out.
    /// The version before is kept beside it, as a script's change keeps it.
    @discardableResult
    func save() -> Bool {
        guard !isDraft else { return false }
        let text = OutlineWriter.text(document)
        do {
            try OutlineFile(outlineURL).write(text)
        } catch {
            flash("Couldn't save: \(error.localizedDescription)")
            return false
        }
        savedText = text
        isDirty = false
        readProblems = []

        let errors = compilation.diagnostics.filter { $0.severity == .error }
        if compilation.config == nil {
            saveStatus = "Saved, but it doesn't compile, so KeybowNotes is still using the previous version."
        } else if errors.isEmpty, let left = compilation.leftOut.first {
            saveStatus = "Saved. KeybowNotes is using it, but left out \(left)"
        } else if errors.isEmpty {
            saveStatus = "Saved. KeybowNotes is using it."
        } else {
            let count = errors.count
            saveStatus = "Saved. KeybowNotes is using it, apart from the \(count == 1 ? "mistake" : "\(count) mistakes") marked here."
        }
        onSaved?()
        return true
    }
}
