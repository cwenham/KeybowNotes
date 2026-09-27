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
    let configURL: URL
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
    var selection: EditorSelection?
    /// A refusal or notice, shown briefly.
    private(set) var message: String?
    private(set) var saveStatus: String?

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var savedText: String
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private let locateApp: (String) -> OutlineConverter.AppMatch?

    init(outlineURL: URL, configURL: URL) {
        self.outlineURL = outlineURL
        self.configURL = configURL
        // App lookups hit the disk; the editor asks the same few names often.
        var cache: [String: OutlineConverter.AppMatch?] = [:]
        locateApp = { name in
            if let known = cache[name] { return known }
            let found = AppLocator.locate(name)
            cache[name] = found
            return found
        }

        let text = (try? String(contentsOf: outlineURL, encoding: .utf8)) ?? ""
        let (document, problems) = OutlineParser.parse(text)
        self.document = document
        self.readProblems = problems
        self.savedText = text.isEmpty ? "" : OutlineWriter.text(document)
        self.compilation = OutlineCompiler.compile(document, locateApp: locateApp)
    }

    var container: OutlineContainer { .tree(tab) }

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

    /// Writes the outline, and the config compiled from it if that compiles
    /// cleanly. The outline is the source, so it's saved even with errors.
    @discardableResult
    func save() -> Bool {
        let text = OutlineWriter.text(document)
        do {
            try FileManager.default.createDirectory(at: outlineURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: outlineURL, atomically: true, encoding: .utf8)
        } catch {
            flash("Couldn't save: \(error.localizedDescription)")
            return false
        }
        savedText = text
        isDirty = false
        readProblems = []

        let errors = compilation.diagnostics.filter { $0.severity == .error }
        if compilation.config != nil && errors.isEmpty {
            do {
                try compilation.json.write(to: configURL, atomically: true, encoding: .utf8)
                saveStatus = "Saved. KeybowNotes is using it."
            } catch {
                saveStatus = "Saved the outline, but couldn't write the config: \(error.localizedDescription)"
            }
        } else {
            let count = max(errors.count, 1)
            saveStatus = "Saved the outline. It has \(count) error\(count == 1 ? "" : "s"), so KeybowNotes is still using the previous version."
        }
        return true
    }
}
