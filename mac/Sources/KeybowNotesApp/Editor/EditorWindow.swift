import AppKit
import KeybowKit
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel
    private let coordinator: OutlineCoordinator
    private var keyMonitor: Any?

    init(outlineURL: URL) {
        model = EditorModel(outlineURL: outlineURL)
        coordinator = OutlineCoordinator(model: model)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 700),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "KeybowNotes — \(outlineURL.lastPathComponent)"
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self
        window.contentViewController = NSHostingController(rootView: EditorRootView(
            model: model, coordinator: coordinator, save: { [weak self] in self?.saveTree() }))
        window.setContentSize(NSSize(width: 1020, height: 700))
        window.center()
        window.setFrameAutosaveName("KeybowNotesTreeEditor")
        model.undoManager = window.undoManager
        // On the trees a keypad that's plugged in uses: not Default, when
        // every one has a section of its own.
        if let used = KeypadBar.users(of: model).keys.min(), model.keypad == 0, KeypadBar.users(of: model)[0] == nil {
            model.keypad = used
        }
        updateTitle()
        preselectForDebugging()
    }

    /// KEYBOW_EDITOR_SCRIPT="wait:1;type:Bob;key:return;key:ctrl+cmd+up;dump:/tmp/out.md"
    /// replays keystrokes through the normal event path, then writes the outline
    /// and selection to a file — for reproducing keyboard behaviour without a
    /// person at the keyboard. Nothing is saved.
    func runDebugScript() {
        guard let script = ProcessInfo.processInfo.environment["KEYBOW_EDITOR_SCRIPT"], let window else { return }
        let codes: [String: UInt16] = ["return": 36, "tab": 48, "esc": 53, "delete": 51,
                                       "up": 126, "down": 125, "left": 123, "right": 124]
        func post(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil,
                                                characters: characters, charactersIgnoringModifiers: characters,
                                                isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        Task { @MainActor in
            for step in script.split(separator: ";").map(String.init) {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                let argument = parts.count > 1 ? parts[1] : ""
                switch parts[0] {
                case "wait":
                    try? await Task.sleep(for: .seconds(Double(argument) ?? 0.5))
                case "type":
                    for character in argument {
                        post(String(character), code: 0, flags: [])
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                case "key":
                    var flags: NSEvent.ModifierFlags = []
                    var name = argument
                    for (prefix, flag) in [("ctrl+", NSEvent.ModifierFlags.control), ("cmd+", .command),
                                           ("shift+", .shift), ("alt+", .option)] {
                        while name.hasPrefix(prefix) { flags.insert(flag); name.removeFirst(prefix.count) }
                    }
                    if ["up", "down", "left", "right"].contains(name) { flags.formUnion([.function, .numericPad]) }
                    let code = codes[name] ?? 0
                    let characters: String
                    switch name {
                    case "return": characters = "\r"
                    case "tab": characters = flags.contains(.shift) ? "\u{19}" : "\t"
                    case "esc": characters = "\u{1b}"
                    case "delete": characters = "\u{7f}"
                    case "up": characters = String(UnicodeScalar(NSUpArrowFunctionKey)!)
                    case "down": characters = String(UnicodeScalar(NSDownArrowFunctionKey)!)
                    case "left": characters = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
                    case "right": characters = String(UnicodeScalar(NSRightArrowFunctionKey)!)
                    default: characters = name
                    }
                    post(characters, code: code, flags: flags)
                    try? await Task.sleep(for: .milliseconds(300))
                case "save":
                    // As the Save button does; a menu shortcut needs the app in front.
                    saveTree()
                case "menu":
                    // The right-click menu for a row, as "row:file".
                    let bits = argument.split(separator: ":", maxSplits: 1).map(String.init)
                    let items = coordinator.menuItems(clickedRow: Int(bits[0]) ?? -1)
                    let text = items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.isEnabled ? "" : " (off)") }
                    try? text.joined(separator: "\n").write(toFile: bits.count > 1 ? bits[1] : "/dev/null",
                                                             atomically: true, encoding: .utf8)
                case "send":
                    // An Edit menu command — copy, cut, paste — the way the
                    // menu sends it: along the responder chain.
                    if window.firstResponder?.tryToPerform(Selector(argument + ":"), with: nil) != true {
                        model.flash("Nothing took \(argument).")
                    }
                case "dump":
                    var text = OutlineWriter.text(model.document)
                    if case .node(let id)? = model.selection, let node = model.node(id) {
                        text += "\nSELECTED: \(node.label)"
                    }
                    if model.selectedIDs.count > 1 {
                        text += "\nALL SELECTED: " + model.selectedIDs.compactMap { model.node($0)?.label }.joined(separator: ", ")
                    }
                    if let message = model.message { text += "\nMESSAGE: \(message)" }
                    try? text.write(toFile: argument, atomically: true, encoding: .utf8)
                default:
                    break
                }
            }
        }
    }

    /// KEYBOW_EDITOR_SELECT="bottom:0.1.0" opens with that node selected —
    /// "1/main:0" in the first keypad section's trees — for checking the
    /// inspector and keypad without clicking.
    private func preselectForDebugging() {
        guard var spec = ProcessInfo.processInfo.environment["KEYBOW_EDITOR_SELECT"] else { return }
        var keypad = 0
        if let slash = spec.firstIndex(of: "/"), let number = Int(spec[..<slash]) {
            keypad = number
            spec = String(spec[spec.index(after: slash)...])
        }
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let tree = parts.count == 2 ? TreeKind(name: parts[0]) ?? .main : .main
        let path = (parts.last ?? "").split(separator: ".").compactMap { Int($0) }
        model.keypad = keypad
        model.tab = tree
        let container = OutlineContainer.tree(tree, keypad: keypad)
        // After the tab's change has cleared the selection, not before.
        DispatchQueue.main.async { [model] in
            if let node = model.document.node(at: OutlineLocation(container, path)) {
                model.selection = .node(node.id)
            } else {
                model.selection = .empty(OutlineLocation(container, path))
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        showWindow(nil)
        window?.bringToFront()
        if let window { WindowSnapshots.keep(window, as: "editor") }
        installKeyMonitor()
        runDebugScript()
    }

    /// ⌃⌘↑ and ⌃⌘↓ (or ⇧⌘) move a node, whether or not its row is being
    /// edited — the field editor would otherwise take them.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if let offset = MoveKeys.offset(for: event) {
                self.coordinator.move(by: offset)
                return nil
            }
            // ⌘Return: a child of this node, editing or not.
            let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
            if [36, 76].contains(event.keyCode), flags == .command {
                self.coordinator.addChild()
                return nil
            }
            return event
        }
    }

    // MARK: - Saving

    @objc func saveTree() {
        window?.makeFirstResponder(nil)       // commit a row being edited
        model.save()
        updateTitle()
    }

    /// ⌘S from the menu.
    @objc func saveDocument(_ sender: Any?) { saveTree() }

    /// ⌃⌘↑ / ⌃⌘↓ from the menu — a second route for the same keys.
    @objc func moveNodeUp(_ sender: Any?) { coordinator.move(by: -1) }
    @objc func moveNodeDown(_ sender: Any?) { coordinator.move(by: 1) }
    /// ⌘Return from the menu.
    @objc func addChildNode(_ sender: Any?) { coordinator.addChild() }

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

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
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
                if model.isDirty {
                    Text("Edited").font(.caption).foregroundStyle(.secondary)
                }
                // ⌘S comes from the main menu, which routes it to the window.
                Button("Save", action: save)
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

    /// The keypads connected, by the trees each uses: 0 for Default.
    static func users(of model: EditorModel) -> [Int: [String]] {
        Dictionary(grouping: USBSerialPorts.keypads()) { device in
            model.compilation.config?.keypadIndex(for: device) ?? 0
        }.mapValues { $0.map(\.model.title) }
    }

    var body: some View {
        let users = Self.users(of: model)
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
        let users = USBSerialPorts.keypads().filter { device in
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
            let connected = USBSerialPorts.keypads()
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
        let unclaimed = USBSerialPorts.keypads().first { device in
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
