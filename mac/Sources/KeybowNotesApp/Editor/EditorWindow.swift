import AppKit
import KeybowKit
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel
    private let coordinator: OutlineCoordinator
    private var keyMonitor: Any?

    init(outlineURL: URL, configURL: URL) {
        model = EditorModel(outlineURL: outlineURL, configURL: configURL)
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
                case "dump":
                    var text = OutlineWriter.text(model.document)
                    if case .node(let id)? = model.selection, let node = model.node(id) {
                        text += "\nSELECTED: \(node.label)"
                    }
                    if let message = model.message { text += "\nMESSAGE: \(message)" }
                    try? text.write(toFile: argument, atomically: true, encoding: .utf8)
                default:
                    break
                }
            }
        }
    }

    /// KEYBOW_EDITOR_SELECT="bottom:0.1.0" opens with that node selected — for
    /// checking the inspector and keypad without clicking.
    private func preselectForDebugging() {
        guard let spec = ProcessInfo.processInfo.environment["KEYBOW_EDITOR_SELECT"] else { return }
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let tree = parts.count == 2 ? TreeKind(name: parts[0]) ?? .main : .main
        let path = (parts.last ?? "").split(separator: ".").compactMap { Int($0) }
        model.tab = tree
        if let node = model.document.node(at: OutlineLocation(.tree(tree), path)) {
            model.selection = .node(node.id)
        } else {
            model.selection = .empty(OutlineLocation(.tree(tree), path))
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        // A menu-bar app isn't active, so its window would open behind others.
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
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
        .onChange(of: model.tab) { _, _ in model.selection = nil }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Tree", selection: $model.tab) {
                ForEach(TreeKind.allCases, id: \.self) { tree in
                    Text(tabTitle(tree)).tag(tree)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if model.isDirty {
                Text("Edited").font(.caption).foregroundStyle(.secondary)
            }
            // ⌘S comes from the main menu, which routes it to the window.
            Button("Save", action: save)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tabTitle(_ tree: TreeKind) -> String {
        let base: String
        switch tree {
        case .main: base = "Main ↓"
        case .row2: base = "Row 2 ↓"
        case .row3: base = "Row 3 ↓"
        case .bottom: base = "Bottom ↑"
        }
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
