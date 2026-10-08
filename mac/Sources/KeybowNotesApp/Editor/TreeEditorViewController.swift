import AppKit
import KeybowKit
import SwiftUI

/// The tree editor, whole — keypad tabs, outline, inspector and keypad — as one
/// piece any window can hold: the tree's own editor window, or Design with
/// Claude beside its conversation. Give it a model and it does the rest when
/// it's put in a window: the window's undo, the keys the outline's text field
/// would otherwise take (⌃⌘↑/↓ to move, ⌘Return for a child), and the menu's
/// commands, which reach it along the responder chain.
@MainActor
final class TreeEditorViewController: NSViewController {
    let model: EditorModel
    let coordinator: OutlineCoordinator
    /// What Save does; nil for a draft, which has nothing to save.
    private let save: (() -> Void)?
    /// The development builds' KEYBOW_EDITOR_SELECT and KEYBOW_EDITOR_SCRIPT.
    private let debugHooks: Bool
    private var keyMonitor: Any?
    private var appeared = false

    init(model: EditorModel, save: (() -> Void)?, debugHooks: Bool = false) {
        self.model = model
        coordinator = OutlineCoordinator(model: model)
        self.save = save
        self.debugHooks = debugHooks
        super.init(nibName: nil, bundle: nil)
        model.showTreesInUse()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = NSHostingView(rootView: EditorRootView(model: model, coordinator: coordinator,
                                                      save: { [weak self] in self?.saveDocument(nil) }))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        model.undoManager = view.window?.undoManager
        installKeyMonitor()
        guard !appeared else { return }
        appeared = true
        if debugHooks {
            preselectForDebugging()
            runDebugScript()
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Whether the keyboard is in the editor — a row being typed in, the
    /// outline, the inspector — or nowhere in particular, rather than in
    /// something beside it: Design with Claude's conversation.
    private var hasKeyboard: Bool {
        guard let window = view.window else { return false }
        if window.firstResponder === window { return true }
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.view.window, self.hasKeyboard else { return event }
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

    // MARK: - The menu's commands

    /// ⌘S, and the Save button.
    @objc func saveDocument(_ sender: Any?) {
        view.window?.makeFirstResponder(nil)       // commit a row being edited
        if let save {
            save()
        } else {
            NSSound.beep()
            model.flash("A draft isn't saved: add it to your tree instead.")
        }
    }

    /// ⌃⌘↑ / ⌃⌘↓ from the menu — a second route for the same keys.
    @objc func moveNodeUp(_ sender: Any?) { coordinator.move(by: -1) }
    @objc func moveNodeDown(_ sender: Any?) { coordinator.move(by: 1) }
    /// ⌘Return from the menu.
    @objc func addChildNode(_ sender: Any?) { coordinator.addChild() }

    // MARK: - Development builds

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

    /// KEYBOW_EDITOR_SCRIPT="wait:1;type:Bob;key:return;key:ctrl+cmd+up;dump:/tmp/out.md"
    /// replays keystrokes through the normal event path, then writes the outline
    /// and selection to a file — for reproducing keyboard behaviour without a
    /// person at the keyboard.
    private func runDebugScript() {
        guard let script = ProcessInfo.processInfo.environment["KEYBOW_EDITOR_SCRIPT"], let window = view.window else { return }
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
                    saveDocument(nil)
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
                    text += "\nSHOWING: keypad \(model.keypad), \(TreeControl.treeName(model.tab))"
                    try? text.write(toFile: argument, atomically: true, encoding: .utf8)
                default:
                    break
                }
            }
        }
    }
}
