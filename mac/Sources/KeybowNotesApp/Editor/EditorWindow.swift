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
    }

    /// ⌃⌘↑ and ⌃⌘↓ move a node, whether or not its row is being edited — the
    /// field editor would otherwise take them.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains([.control, .command]) else { return event }
            switch event.keyCode {
            case 126: self.coordinator.move(by: -1); return nil      // ↑
            case 125: self.coordinator.move(by: 1); return nil       // ↓
            default: return event
            }
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
