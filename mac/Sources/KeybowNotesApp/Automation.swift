import AppKit
import KeybowKit

/// What other apps and AI agents can ask of KeybowNotes — through
/// AppleScript, Shortcuts and the MCP server alike: read and change the
/// tree, run an entry as though its key were pressed, and work the
/// stopwatch. On the main thread, where the app keeps its state.
///
/// Changes go to the tree file, which the app then loads, as a save from
/// the tree editor does. The version before is kept beside it as
/// `tree.md.previous`. With the editor open and unsaved, nothing is
/// changed: one of the two would be lost.
@MainActor
final class Automation {
    static var shared: Automation?

    struct Problem: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    enum EditorState { case closed, clean, unsaved }

    /// What the app hands it.
    struct Hooks {
        var outlineURL: () -> URL
        var config: () -> KeybowConfig
        /// The trees each keypad that's plugged in uses, in a steady order:
        /// what an entry is looked for in when no keypad is named.
        var connected: () -> [(name: String, keypad: Int)]
        var reload: () -> Void
        var editorState: () -> EditorState
        var reloadEditor: () -> Void
        var fire: (ResolvedSelection, @escaping (ActionOutcome) -> Void) -> Void
        var notice: (String, String) -> Void
        var modulesChanged: () -> Void
    }

    private let hooks: Hooks

    init(hooks: Hooks) {
        self.hooks = hooks
    }

    // MARK: Reading

    /// The tree file — an outline, not compiled JSON.
    private func file() throws -> OutlineFile {
        let url = hooks.outlineURL()
        guard ConfigFile.isOutline(url) else {
            throw Problem("The config is a compiled JSON file, \(url.lastPathComponent): only an outline can be changed from here.")
        }
        return OutlineFile(url)
    }

    /// The tree, to read: lines that can't be read are skipped, as the app
    /// skips them when it loads the tree.
    func document() throws -> OutlineDocument {
        try file().read().document
    }

    /// Nothing named: the trees the first keypad that's plugged in uses.
    func keypad(_ name: String?, in document: OutlineDocument) throws -> Int {
        try TreeControl.keypad(name, in: document, otherwise: hooks.connected().first?.keypad ?? 0)
    }

    /// The keypads' trees by name, and which keypads plugged in use them.
    func keypads() throws -> String {
        let document = try document()
        let connected = hooks.connected()
        return TreeControl.keypadNames(document).enumerated().map { index, name in
            let users = connected.filter { $0.keypad == index }.map(\.name)
            return users.isEmpty ? name : "\(name) — used by the \(users.joined(separator: " and "))"
        }.joined(separator: "\n")
    }

    func outline(tree: String?, keypad: String?) throws -> String {
        let document = try document()
        let tree = try TreeControl.tree(tree)
        return TreeControl.outline(document, keypad: try self.keypad(keypad, in: document), tree: tree)
    }

    /// Every leaf in a tree, a path a line: what can be run.
    func leaves(tree: String?, keypad: String?) throws -> [String] {
        let document = try document()
        return TreeControl.leaves(document, keypad: try self.keypad(keypad, in: document), tree: try TreeControl.tree(tree))
            .map { $0.joined(separator: "/") }
    }

    /// The whole outline: every keypad's trees, lists, contacts, projects.
    func wholeOutline() throws -> String {
        OutlineWriter.text(try document())
    }

    /// "Keybow 2040, using the trees “Desk”", for each keypad plugged in.
    func connectedKeypads(in document: OutlineDocument) -> [String] {
        let names = TreeControl.keypadNames(document)
        return hooks.connected().map { "\($0.name), using the trees “\(names[min($0.keypad, names.count - 1)])”" }
    }

    func check(_ text: String) -> String {
        TreeControl.check(text, locateApp: AppLocator.locate)
    }

    // MARK: Changing

    /// Changes the tree file, and loads it.
    private func edit<T>(_ change: (inout OutlineDocument) throws -> T) throws -> T {
        if hooks.editorState() == .unsaved {
            throw Problem("The tree editor has changes that aren't saved. Save them, or undo them, first: otherwise one "
                          + "or the other would be lost.")
        }
        let file = try self.file()
        let (document, problems) = file.read()
        guard problems.isEmpty else {
            let lines = problems.prefix(5).map { String($0.line) }.joined(separator: ", ")
            throw Problem("Some lines of the tree can't be read — \(lines) — and would be lost. Fix them in the tree editor first.")
        }
        var changed = document
        let result = try change(&changed)
        do {
            try file.write(changed)
        } catch {
            throw Problem("The tree couldn't be saved: \(error.localizedDescription)")
        }
        hooks.reload()
        if hooks.editorState() == .clean { hooks.reloadEditor() }
        return result
    }

    func add(_ text: String, under parent: String?, tree: String?, keypad: String?) throws -> String {
        try edit { document in
            let tree = try TreeControl.tree(tree)
            let keypad = try self.keypad(keypad, in: document)
            let added = try TreeControl.add(text, under: TreeControl.path(parent ?? ""), keypad: keypad, tree: tree, to: &document)
            let place = parent.map { "under “\($0)”" } ?? "at the top"
            return "Added " + added.map { "“\($0)”" }.joinedList + " \(place) of the \(tree.name) tree"
                + " of \(TreeControl.keypadNames(document)[keypad])."
        }
    }

    func remove(_ path: String, tree: String?, keypad: String?) throws -> String {
        try edit { document in
            let tree = try TreeControl.tree(tree)
            let keypad = try self.keypad(keypad, in: document)
            let label = try TreeControl.remove(TreeControl.path(path), keypad: keypad, tree: tree, from: &document)
            return "Removed “\(label)”, and everything under it."
        }
    }

    func change(_ path: String, to text: String, tree: String?, keypad: String?) throws -> String {
        try edit { document in
            try TreeControl.change(TreeControl.path(path), to: text, keypad: try self.keypad(keypad, in: document),
                                   tree: try TreeControl.tree(tree), in: &document)
            return "Changed “\(path)” to “\(text.trimmingCharacters(in: .whitespacesAndNewlines))”."
        }
    }

    func replace(tree: String?, keypad: String?, with text: String) throws -> String {
        try edit { document in
            let kind = try TreeControl.tree(tree)
            let index = try self.keypad(keypad, in: document)
            try TreeControl.replace(kind, keypad: index, with: text, in: &document)
            return "Replaced the \(kind.name) tree of \(TreeControl.keypadNames(document)[index])."
        }
    }

    /// Claude's draft, where it was asked for.
    func applyDraft(_ outline: String, scope: TreeDraft.Scope) throws -> String {
        try edit { document in try TreeDraft.apply(outline, scope: scope, to: &document) }
    }

    /// What was drafted in a working copy, carried into the tree file.
    func carryDraft(from draft: OutlineDocument, original: OutlineDocument, scope: TreeDraft.Scope,
                    asNewSection: Bool) throws -> String {
        try edit { document in
            try TreeDraft.carry(from: draft, original: original, scope: scope, asNewSection: asNewSection, into: &document)
        }
    }

    /// A new keypad section, for a keypad of `model`, optionally one board's.
    func addKeypad(named name: String, model: String?, id: String?) throws -> String {
        try edit { document in
            guard !TreeControl.keypadNames(document).contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw Problem("There's a keypad called “\(name)” already.")
            }
            var annotations: [Annotation] = []
            if let model {
                guard let known = KeypadDevice.Model(words: model) else {
                    throw Problem("“\(model)” isn't a keypad model: Keybow 2040 or RGB Keypad.")
                }
                annotations.append(.word(known.title))
            }
            if let id, !id.isEmpty { annotations.append(.pair(key: "id", value: id)) }
            _ = document.addKeypad(OutlineKeypad(name: name, annotations: annotations))
            return "Added the keypad “\(name)”, with no trees yet."
        }
    }

    // MARK: Music

    /// What's in the Music library, as Claude's music_library tool answers.
    func musicLibrary(_ list: String, genre: String?, artist: String?, album: String?, rankedBy: String?,
                      limit: Int?) async throws -> String {
        var input: [String: Any] = ["list": list]
        for (key, value) in [("genre", genre), ("artist", artist), ("album", album), ("rank_by", rankedBy)] {
            if let value { input[key] = value }
        }
        if let limit { input["limit"] = limit }
        return try await MusicLibrary.shared.contents().answer(try MusicQuery(input: input))
    }

    // MARK: Running

    /// Runs an entry as though its keys were pressed, and says how it went.
    func trigger(_ path: String, tree: String?, keypad: String?) async throws -> ActionOutcome {
        let document = try document()
        let kind = try TreeControl.tree(tree)
        let index = try self.keypad(keypad, in: document)
        let config = hooks.config().forKeypad(index)
        let keys: [Int]
        do {
            keys = try TreeControl.keys(TreeControl.path(path), in: config, tree: kind)
        } catch let problem as TreeControl.Problem where keypad == nil {
            // Say where it looked, since nothing said where to.
            let users = hooks.connected().filter { $0.keypad == index }.map(\.name)
            let whose = users.isEmpty ? "" : ", which the \(users.joined(separator: " and ")) uses"
            throw Problem("\(problem) That's in “\(TreeControl.keypadNames(document)[index])”\(whose): say keypad to look in another.")
        }
        guard let selection = config.resolve(tree: kind, path: keys), selection.action != nil else {
            throw Problem("“\(path)” has keys under it: name one of them.")
        }
        return await withCheckedContinuation { continuation in
            hooks.fire(selection) { outcome in continuation.resume(returning: outcome) }
        }
    }

    /// start, stop, lap, reset or toggle.
    func stopwatch(_ command: String) async throws -> String {
        guard let module = ModuleRegistry.shared.module(handling: "stopwatch") else {
            throw Problem("The stopwatch isn't here.")
        }
        let request = ModuleRequest(type: "stopwatch", fields: ["do": command], labels: ["Stopwatch"])
        if let problem = module.problem(with: request) { throw Problem(problem) }
        let outcome = await module.run(request, now: Date())
        hooks.modulesChanged()
        guard outcome.succeeded else { throw Problem(outcome.message + (outcome.detail.map { ": \($0)" } ?? "")) }
        hooks.notice(outcome.message, "stopwatch")
        return outcome.message + (outcome.detail.map { " — \($0)" } ?? "")
    }

    /// What the stopwatch reads, and whether it's running.
    func stopwatchReading() -> String {
        let values = ModuleRegistry.shared.module(handling: "stopwatch")?.values(now: Date()) ?? [:]
        let status = ModuleRegistry.shared.module(handling: "stopwatch")?.status(now: Date())
        let reading = values["stopwatch"] ?? "0:00"
        return status?.countingFrom != nil ? "\(reading), running" : "\(reading), stopped"
    }
}

private extension Array where Element == String {
    var joinedList: String {
        count <= 2 ? joined(separator: " and ") : dropLast().joined(separator: ", ") + " and " + last!
    }
}
