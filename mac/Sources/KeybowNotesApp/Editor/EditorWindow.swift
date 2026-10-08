import AppKit
import KeybowKit
import SwiftUI

/// The tree's own editor window: the editor component, on the tree file,
/// saved with ⌘S and asked about on closing with changes unsaved.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel
    private let editor: TreeEditorViewController

    init(outlineURL: URL) {
        model = EditorModel(outlineURL: outlineURL)
        editor = TreeEditorViewController(model: model, save: { [model] in _ = model.save() }, debugHooks: true)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 700),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "KeybowNotes — \(outlineURL.lastPathComponent)"
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self
        window.contentViewController = editor
        window.setContentSize(NSSize(width: 1020, height: 700))
        window.center()
        window.setFrameAutosaveName("KeybowNotesTreeEditor")
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        showWindow(nil)
        window?.bringToFront()
        if let window { WindowSnapshots.keep(window, as: "editor") }
    }

    /// ⌘S with nothing in the window holding the keyboard: the editor's Save.
    @objc func saveDocument(_ sender: Any?) { editor.saveDocument(sender) }

    private func updateTitle() {
        window?.isDocumentEdited = model.isDirty
    }

    func windowDidUpdate(_ notification: Notification) {
        if window?.isDocumentEdited != model.isDirty { updateTitle() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        guard model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to the tree?"
        alert.informativeText = "Saving updates what the Keybow does straight away."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return model.save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
}

struct EditorRootView: View {
    @Bindable var model: EditorModel
    let coordinator: OutlineCoordinator
    let save: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !model.readProblems.isEmpty { readProblemsBanner }
            Divider()
            HSplitView {
                OutlinePane(model: model, coordinator: coordinator)
                    .frame(minWidth: 380, idealWidth: 560)
                    .overlay(alignment: .bottom) { flash }
                VStack(spacing: 0) {
                    InspectorPane(model: model)
                        .frame(minHeight: 240, maxHeight: .infinity)
                    Divider()
                    KeypadPane(model: model)
                }
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)
            }
            if let status = model.saveStatus {
                Divider()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .onChange(of: model.tab) { _, _ in model.selection = nil; model.selectedIDs = [] }
        .onChange(of: model.keypad) { _, _ in model.selection = nil; model.selectedIDs = [] }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            KeypadBar(model: model)
            HStack(spacing: 12) {
                TreeTabs(selection: $model.tab, title: tabTitle)
                if model.tab.canHavePages {
                    Toggle("Pages", isOn: Binding(get: { model.isPaged(model.tab) }, set: setPages))
                        .toggleStyle(.checkbox)
                        .help("Pages: each key on row \(model.tab.startRow + 1) picks a page, which stays. The rows "
                              + "below become its keys, each running its action when it's pressed, in the page's "
                              + "colour. Its key again, or a key on a row above, goes back to the trees.")
                }
                Spacer()
                if model.isDraft {
                    Label("Draft: your tree changes only when you add it", systemImage: "pencil.and.outline")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    if model.isDirty {
                        Text("Edited").font(.caption).foregroundStyle(.secondary)
                    }
                    // ⌘S comes from the main menu, which routes it to the window.
                    Button("Save", action: save)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func setPages(_ paged: Bool) {
        let tree = model.tab
        let keypad = min(model.keypad, model.document.keypads.count)
        _ = model.edit(paged ? "Make Pages" : "Make a Tree") { try $0.setPages(paged, for: tree, keypad: keypad) }
    }

    private func tabTitle(_ tree: TreeKind) -> String {
        var base: String
        switch tree {
        case .main: base = "Main ↓"
        case .row2: base = "Row 2 ↓"
        case .row3: base = "Row 3 ↓"
        case .bottom: base = "Bottom ↑"
        }
        if model.isPaged(tree) { base = "Row \(tree.startRow + 1) pages" }
        return model.hasProblems(tree) ? base + " •" : base
    }

    private var readProblemsBanner: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("\(model.readProblems.count) line\(model.readProblems.count == 1 ? "" : "s") of the file couldn't be read, and will be left out if you save:",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            ForEach(Array(model.readProblems.prefix(4).enumerated()), id: \.offset) { _, problem in
                Text("Line \(problem.line): \(problem.message)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.08))
    }

    @ViewBuilder
    private var flash: some View {
        if let message = model.message {
            Text(message)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 14)
                .transition(.opacity)
        }
    }
}

/// The keypads, as tabs over the trees: the first keypad's trees — those
/// before any `# keypad` heading — then each keypad with trees of its own,
/// and + for another. A keypad of its own shows its name, model and ID beside
/// them, to change.
private struct KeypadBar: View {
    let model: EditorModel
    @State private var confirmingRemove = false

    private var document: OutlineDocument { model.document }

    var body: some View {
        let users = model.keypadsInUse()
        VStack(alignment: .leading, spacing: 6) {
            bar(users)
            if !users.isEmpty, users[min(model.keypad, document.keypads.count)] == nil { unused(users) }
        }
    }

    /// Edits here wouldn't reach a keypad: say which trees each one uses.
    private func unused(_ users: [Int: [String]]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("No keypad that's plugged in uses these trees.")
            ForEach(users.keys.sorted(), id: \.self) { index in
                Button("\(users[index]!.joined(separator: " and ")) uses “\(title(index))”") { model.keypad = index }
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
    }

    private func bar(_ users: [Int: [String]]) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(0..<document.keypadCount, id: \.self) { index in tab(index, inUse: users[index] != nil) }
                Button(action: add) {
                    Image(systemName: "plus").padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add a keypad with trees of its own")
            }
            .padding(2)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            if model.keypad > 0, model.keypad <= document.keypads.count { settings(model.keypad) }
            Spacer()
        }
    }

    private func title(_ index: Int) -> String {
        index == 0 ? "Default" : document.keypads[index - 1].name
    }

    private func tab(_ index: Int, inUse: Bool) -> some View {
        let chosen = index == min(model.keypad, document.keypads.count)
        return Button {
            model.keypad = index
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.grid.4x3.fill").imageScale(.small)
                Text(title(index)).fontWeight(chosen ? .semibold : .regular)
                if inUse {
                    // A keypad that's plugged in uses these.
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(chosen ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help(index))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// Which keypads use these trees, of those connected.
    private func help(_ index: Int) -> String {
        let users = model.connectedKeypads().filter { device in
            (model.compilation.config?.keypadIndex(for: device) ?? 0) == index
        }.map(\.model.title)
        let using = users.isEmpty ? "" : " Connected and using these: \(users.joined(separator: ", "))."
        if index == 0 {
            return "The trees before any keypad section, for every keypad without trees of its own." + using
        }
        let keypad = document.keypads[index - 1]
        let forWhat = keypad.id.map { "the keypad with ID \($0)" } ?? keypad.model.map { "any \($0.title)" } ?? "no keypad yet: give it a model"
        return "“\(keypad.name)”: trees for \(forWhat)." + using
    }

    // MARK: A keypad of its own

    @ViewBuilder
    private func settings(_ index: Int) -> some View {
        let keypad = document.keypads[index - 1]
        DraftField(title: "Name", value: keypad.name, placeholder: "Name",
                   help: "What the keypad is called here, and in the tree's # keypad heading.", labelWidth: 40) { name in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            _ = model.edit("Rename Keypad") { $0.keypads[index - 1].name = trimmed }
        }
        .frame(width: 220)
        Picker("Model", selection: Binding(
            get: { keypad.model },
            set: { model in set(index, model: model, id: keypad.id) }
        )) {
            Text("Any model").tag(KeypadDevice.Model?.none)
            ForEach(KeypadDevice.Model.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
        }
        .labelsHidden()
        .fixedSize()
        .help("Which keypads these trees are for: every one of this model, unless it's given an ID.")
        Menu(keypad.id.map { "ID \($0.prefix(6))…" } ?? "Any one") {
            Button("Any of the model") { set(index, model: keypad.model, id: nil) }
            let connected = model.connectedKeypads()
            if !connected.isEmpty { Divider() }
            ForEach(connected, id: \.serial) { device in
                Button("\(device.model.title) — \(device.serial)") { set(index, model: device.model, id: device.serial) }
            }
        }
        .fixedSize()
        .help("For one keypad of a model you have two of: its unique ID, from those connected.")
        if document.keypadIsEmpty(index) {
            Button("Copy Default's Trees") {
                _ = model.edit("Copy Trees") { $0.copyTrees(from: 0, to: index) }
            }
            .help("Start from a copy of the Default trees, rather than from nothing.")
        }
        Button("Remove…") {
            if document.keypadIsEmpty(index) { remove(index) } else { confirmingRemove = true }
        }
        .help("Remove this keypad's section; its keypads go back to the Default trees.")
        .alert("Remove “\(keypad.name)” and its trees?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { remove(index) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its keypads go back to the Default trees. Undo brings it back.")
        }
    }

    /// Writes the model as its word, `[RGB Keypad]`, and the ID as `id: …`.
    private func set(_ index: Int, model newModel: KeypadDevice.Model?, id: String?) {
        _ = model.edit("Set Keypad") { document in
            var annotations = document.keypads[index - 1].annotations.filter { annotation in
                switch annotation {
                case .word(let word): return KeypadDevice.Model(words: word) == nil
                case .pair(let key, _): return key != "id"
                }
            }
            if let id { annotations.insert(.pair(key: "id", value: id), at: 0) }
            if let newModel { annotations.insert(.word(newModel.title), at: 0) }
            document.keypads[index - 1].annotations = annotations
        }
    }

    /// A keypad connected without trees of its own, else "Keypad n".
    private func add() {
        let config = model.compilation.config
        let unclaimed = model.connectedKeypads().first { device in
            !document.keypads.contains { $0.model == device.model || $0.id == device.serial }
                && (config?.keypadIndex(for: device) ?? 0) == 0
        }
        let name = unclaimed?.model.title ?? "Keypad \(document.keypadCount + 1)"
        let annotations: [Annotation] = unclaimed.map { [.word($0.model.title)] } ?? []
        var added = 0
        if model.edit("Add Keypad", { added = $0.addKeypad(OutlineKeypad(name: name, annotations: annotations)) }) {
            model.keypad = added
        }
    }

    private func remove(_ index: Int) {
        if model.edit("Remove Keypad", { $0.removeKeypad(index) }) {
            model.keypad = 0
        }
    }
}

/// The four trees, as tabs: each with a diagram of the keypad showing where
/// it starts and which way it runs, in its own colour. A segmented control
/// would draw the diagrams in one colour, so these are buttons that look the
/// part. ⌘1 to ⌘4 choose them from the keyboard.
private struct TreeTabs: View {
    @Binding var selection: TreeKind
    let title: (TreeKind) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(TreeKind.allCases.enumerated()), id: \.element) { index, tree in
                tab(tree, shortcut: KeyEquivalent(Character(String(index + 1))))
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tab(_ tree: TreeKind, shortcut: KeyEquivalent) -> some View {
        let chosen = tree == selection
        return Button {
            selection = tree
        } label: {
            HStack(spacing: 6) {
                TreeGridIcon(tree: tree)
                Text(title(tree))
                    .fontWeight(chosen ? .semibold : .regular)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(chosen ? tree.tint.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(chosen ? tree.tint.opacity(0.65) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .help("\(treeName(tree)): \(tree.shape). ⌘\(shortcut.character)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
