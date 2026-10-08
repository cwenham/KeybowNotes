import AppKit
import KeybowAI
import KeybowKit
import SwiftUI

/// Designing keypads with Claude: a conversation on the left, and on the right
/// the whole tree editor, on a working copy of the tree with Claude's draft in
/// it — to click through, try, and change by hand. Each turn sends the draft
/// as it stands, the person's own changes included, and Claude's new draft
/// replaces it as one step to undo. Nothing reaches the tree until the person
/// adds it.
@MainActor
@Observable
final class DesignModel {
    struct Message: Identifiable {
        enum Kind { case you, claude, status, problem }

        let id = UUID()
        let kind: Kind
        let text: String
    }

    enum Where: Hashable { case newKeypad, keypad, tree }

    // What to draft, chosen before the first turn.
    var place: Where = .newKeypad
    var newName = "Drafted"
    var newModel: KeypadDevice.Model?
    var keypad = 0
    var tree: TreeKind = .main
    var sendOutline = true
    var sendWhatsHere = true

    var input = ""
    private(set) var messages: [Message] = []
    /// While Claude's working: since when, and doing what.
    private(set) var working: (since: Date, step: String)?
    /// Where the draft is in the working copy, once there is one.
    private(set) var drafted: TreeDraft.Scope?
    /// A keypad of its own, added to the tree as a new section.
    private(set) var asNewSection = false
    /// The working copy's revision when last added: changes since are unadded.
    private(set) var addedRevision: Int?

    /// The working copy: the tree as it was, with the draft in it.
    let editor: EditorModel
    let coordinator: OutlineCoordinator
    private(set) var keypadNames: [String]
    @ObservationIgnored private var original: OutlineDocument
    @ObservationIgnored private var turns: [(role: String, text: String)] = []
    @ObservationIgnored private var context: TreeDraft.Context?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(outlineURL: URL) {
        let text = (try? String(contentsOf: outlineURL, encoding: .utf8)) ?? ""
        editor = EditorModel(outlineURL: outlineURL, text: text, draft: true)
        coordinator = OutlineCoordinator(model: editor)
        original = editor.document
        keypadNames = TreeControl.keypadNames(original)
        // A section for no model is used by no keypad: start from one that's here.
        newModel = USBSerialPorts.keypads().first?.model
        if let used = KeypadBar.users(of: editor).keys.min(), KeypadBar.users(of: editor)[0] == nil {
            editor.keypad = used
            keypad = used
        }
    }

    var claudeIsReady: Bool {
        (ModuleRegistry.shared.module(id: ClaudeModule.id) as? ClaudeModule)?.isReady ?? false
    }

    var hasUnaddedChanges: Bool {
        drafted != nil && addedRevision != editor.revision
    }

    /// What was chosen, before the first draft.
    private var chosen: TreeDraft.Scope {
        switch place {
        case .newKeypad:
            let name = newName.trimmingCharacters(in: .whitespaces)
            return .newKeypad(name: name.isEmpty ? "Drafted" : name, model: newModel)
        case .keypad: return .keypad(keypad)
        case .tree: return .tree(tree, keypad: keypad)
        }
    }

    /// "a new keypad section, “Writing”, for a Keybow 2040".
    var aboutDraft: String {
        switch drafted ?? chosen {
        case .newKeypad(let name, let model):
            return "a new keypad section, “\(name)”" + (model.map { ", for a \($0.title)" } ?? "")
        case .keypad(let index):
            let name = TreeControl.keypadNames(editor.document)[min(index, editor.document.keypads.count)]
            return asNewSection ? "a new keypad section, “\(name)”" : "all the trees of “\(name)”"
        case .tree(let tree, let index):
            return "the \(TreeControl.treeName(tree)) tree of “\(keypadNames[min(index, keypadNames.count - 1)])”"
        }
    }

    // MARK: Talking

    func send() {
        let said = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, working == nil, claudeIsReady else { return }
        input = ""
        messages.append(Message(kind: .you, text: said))
        working = (Date(), drafted == nil ? "Claude is drafting…" : "Claude is thinking…")
        task = Task { await converse(said) }
    }

    private func setStep(_ step: String) {
        if let since = working?.since { working = (since, step) }
    }

    private func converse(_ said: String) async {
        let turnsBefore = turns
        defer { working = nil }
        do {
            guard let claude = ModuleRegistry.shared.module(id: ClaudeModule.id) as? ClaudeModule else {
                throw Automation.Problem("Claude isn't here.")
            }
            let system = TreeDraft.system(guide: try AgentGuide.text(), catalog: AgentGuide.catalog())
            if let drafted {
                turns.append(("user", TreeDraft.followUp(said, current: TreeDraft.outline(of: editor.document, scope: drafted))))
            } else {
                if context == nil {
                    setStep("Gathering what's here…")
                    context = await gather()
                    setStep("Claude is drafting…")
                }
                turns = [("user", TreeDraft.request(said, scope: chosen, document: editor.document, context: context!))]
            }
            var reply = try await ask(claude, system)
            if var outline = TreeDraft.outline(in: reply) {
                if let mistakes = TreeDraft.mistakes(outline) {
                    setStep("Claude is correcting its draft…")
                    turns.append(("assistant", reply))
                    turns.append(("user", """
                        KeybowNotes found mistakes in that outline:

                        ```outline
                        \(outline)
                        ```

                        \(mistakes)

                        Correct every one, and answer the same way: the whole outline, then a short note.
                        """))
                    reply = try await ask(claude, system)
                    outline = TreeDraft.outline(in: reply) ?? outline
                }
                try apply(outline)
                turns.append(("assistant", reply))
                let note = TreeDraft.note(in: reply)
                if !note.isEmpty { messages.append(Message(kind: .claude, text: note)) }
                var status = "The draft is in the editor: click through it, try it, change it."
                if let mistakes = TreeDraft.mistakes(outline) {
                    status += " It still has mistakes — what they touch is left out:\n" + mistakes
                }
                let fills = TreeControl.check(outline, locateApp: AppLocator.locate)
                    .components(separatedBy: .newlines).filter { $0.hasPrefix("to fill in:") }
                if !fills.isEmpty { status += "\n" + fills.joined(separator: "\n") }
                messages.append(Message(kind: .status, text: status))
            } else {
                // Only answering: nothing changes.
                turns.append(("assistant", reply))
                messages.append(Message(kind: .claude, text: reply.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        } catch is CancellationError {
            turns = turnsBefore
            messages.append(Message(kind: .status, text: "Stopped. Nothing was changed."))
        } catch let error as ModuleError {
            turns = turnsBefore
            messages.append(Message(kind: .problem, text: error.message + (error.detail.map { " — \($0)" } ?? "")))
        } catch {
            turns = turnsBefore
            messages.append(Message(kind: .problem, text: "\(error)"))
        }
    }

    /// The conversation as sent: every earlier draft left out, since the
    /// newest is in the person's last turn.
    private func ask(_ claude: ClaudeModule, _ system: String) async throws -> String {
        let sent = turns.map { turn in turn.role == "assistant" ? (turn.role, TreeDraft.withoutOutline(turn.text)) : turn }
        return try await claude.converse(system: system, turns: sent, effort: "medium", maxTokens: 32_000, timeout: 600)
    }

    /// Claude's outline into the working copy, replacing the last draft — and
    /// what that draft added that the tree didn't have.
    private func apply(_ outline: String) throws {
        var document = editor.document
        document.lists.removeAll { list in !original.lists.contains { $0.name == list.name } }
        document.contacts.removeAll { entry in !original.contacts.contains { $0.name == entry.name } }
        document.projects.removeAll { entry in !original.projects.contains { $0.name == entry.name } }
        if let drafted {
            try TreeDraft.apply(outline, scope: drafted, to: &document)
        } else {
            let scope = chosen
            try TreeDraft.apply(outline, scope: scope, to: &document)
            if case .newKeypad = scope {
                drafted = .keypad(document.keypads.count)
                asNewSection = true
            } else {
                drafted = scope
            }
        }
        editor.replace(with: document, name: "Claude's Draft")
        switch drafted {
        case .keypad(let index)?: editor.keypad = index
        case .tree(let tree, let index)?:
            editor.keypad = index
            editor.tab = tree
        default: break
        }
    }

    /// What the person has, as far as they've agreed to send it.
    private func gather() async -> TreeDraft.Context {
        var context = TreeDraft.Context()
        if sendOutline { context.outline = OutlineWriter.text(original) }
        context.keypads = Automation.shared?.connectedKeypads(in: original) ?? []
        guard sendWhatsHere else { return context }
        context.apps = AppCatalog.all.map(\.name)
        context.shortcuts = await ShortcutCatalog.names()
        if let home = ModuleRegistry.shared.module(id: "home"),
           let entities = try? await home.choices(for: "entity", type: "home", fields: [:]) {
            context.homeEntities = entities.prefix(400).map { entity in
                entity.title.map { "\(entity.value) — \($0)" } ?? entity.value
            }
        }
        return context
    }

    func stop() {
        task?.cancel()
    }

    // MARK: Using it

    /// The draft into the tree: added as a section, or replacing what was
    /// drafted. Again, after more changes, it updates what it added.
    func add() {
        guard let drafted, let automation = Automation.shared else { return }
        do {
            let said = try automation.carryDraft(from: editor.document, original: original, scope: drafted,
                                                 asNewSection: asNewSection && addedRevision == nil)
            addedRevision = editor.revision
            // Trees no keypad that's plugged in uses are felt nowhere: say so.
            let document = try automation.document()
            let name = TreeControl.keypadNames(editor.document)[draftedKeypad]
            let users = automation.connectedKeypads(in: document).filter { $0.hasSuffix("“\(name)”") }
            var note = " KeybowNotes is using it."
            if users.isEmpty, !USBSerialPorts.keypads().isEmpty {
                note = " No keypad that's plugged in uses it yet: in the tree editor, give its section the ID of the "
                    + "keypad it's for, or a model no other section claims."
            }
            messages.append(Message(kind: .status, text: said + note))
        } catch {
            messages.append(Message(kind: .problem, text: "\(error)"))
        }
    }

    /// The keypad the draft is in, in the working copy.
    private var draftedKeypad: Int {
        switch drafted {
        case .keypad(let index)?, .tree(_, let index)?: return min(index, editor.document.keypads.count)
        default: return 0
        }
    }

    func startOver() {
        task?.cancel()
        turns = []
        context = nil
        messages = []
        drafted = nil
        asNewSection = false
        addedRevision = nil
        if let current = try? Automation.shared?.document() { original = current }
        keypadNames = TreeControl.keypadNames(original)
        editor.replace(with: original, name: "Start Over")
    }
}

struct DesignView: View {
    @Bindable var model: DesignModel
    let openSettings: () -> Void

    var body: some View {
        HSplitView {
            conversation
                .frame(minWidth: 340, idealWidth: 400, maxWidth: 560)
            EditorRootView(model: model.editor, coordinator: model.coordinator, save: {})
                .frame(minWidth: 680)
        }
        .frame(minWidth: 1080, minHeight: 640)
    }

    // MARK: The conversation

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars").font(.system(size: 22)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Design with Claude").font(.title3.weight(.semibold))
                        Text(model.drafted == nil ? "Say what you'd like your keypads for."
                             : "Drafting \(model.aboutDraft).")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !model.claudeIsReady {
                    HStack {
                        Label("Needs your Anthropic API key, in Settings → Claude.", systemImage: "key.fill")
                            .foregroundStyle(.orange).font(.callout)
                        Spacer()
                        Button("Settings…", action: openSettings).controlSize(.small)
                    }
                }
                if model.drafted == nil, model.messages.isEmpty { setup }
            }
            .padding(14)
            Divider()
            transcript
            Divider()
            composer.padding(12)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Draft", selection: $model.place) {
                Text("A new keypad section").tag(DesignModel.Where.newKeypad)
                Text("All of a keypad's trees").tag(DesignModel.Where.keypad)
                Text("One tree").tag(DesignModel.Where.tree)
            }
            .pickerStyle(.radioGroup)
            switch model.place {
            case .newKeypad:
                HStack {
                    TextField("Name", text: $model.newName).frame(width: 140)
                    Picker("for", selection: $model.newModel) {
                        Text("any model").tag(KeypadDevice.Model?.none)
                        ForEach(KeypadDevice.Model.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    .fixedSize()
                }
            case .keypad:
                keypadPicker
            case .tree:
                HStack {
                    Picker("The", selection: $model.tree) {
                        ForEach(TreeKind.allCases, id: \.self) { Text(TreeControl.treeName($0)).tag($0) }
                    }
                    .fixedSize()
                    keypadPicker
                }
            }
            Toggle("Send my tree file, so it fits — contacts and projects too", isOn: $model.sendOutline)
            Toggle("Send the names of my apps, shortcuts and Home Assistant entities", isOn: $model.sendWhatsHere)
            Text("What you write, and what's ticked, goes to Anthropic with your key. Your tree changes only when you add "
                 + "the draft.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private var keypadPicker: some View {
        Picker(model.place == .tree ? "of" : "Keypad", selection: $model.keypad) {
            ForEach(Array(model.keypadNames.enumerated()), id: \.offset) { index, name in Text(name).tag(index) }
        }
        .fixedSize()
    }

    private var transcript: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.messages.isEmpty {
                        Text("Describe what you'd like the keypads for: the apps you use, what you do again and again, "
                             + "the people you message, the lamps you switch. Then ask for changes, as you would a person.")
                            .foregroundStyle(.secondary).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.messages) { message in bubble(message) }
                    if let working = model.working {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            TimelineView(.periodic(from: working.since, by: 1)) { context in
                                Text("\(working.step) \(Int(context.date.timeIntervalSince(working.since))) s")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer()
                            Button("Stop", action: model.stop).controlSize(.small)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(14)
            }
            .onChange(of: model.messages.count) { _, _ in withAnimation { scroller.scrollTo("end") } }
            .onChange(of: model.working == nil) { _, _ in withAnimation { scroller.scrollTo("end") } }
        }
    }

    @ViewBuilder
    private func bubble(_ message: DesignModel.Message) -> some View {
        switch message.kind {
        case .you:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
        case .claude:
            Text(Self.markdown(message.text))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        case .status:
            Label(message.text, systemImage: "arrow.right.circle")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .problem:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $model.input)
                .font(.body)
                .frame(height: 72)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .overlay(alignment: .topLeading) {
                    if model.input.isEmpty {
                        Text(model.drafted == nil ? "I write fiction in Ulysses, and I'd like quick ways to jot ideas…"
                             : "Put the lamps on their own page, and add a key to message Sam…")
                            .foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                    }
                }
            HStack {
                Button("Start Over", action: model.startOver)
                    .disabled(model.messages.isEmpty || model.working != nil)
                Spacer()
                Button(model.addedRevision == nil ? (model.asNewSection ? "Add to My Tree" : "Use in My Tree") : "Update My Tree",
                       action: model.add)
                    .disabled(model.drafted == nil || model.working != nil || !model.hasUnaddedChanges)
                Button("Send", action: model.send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.working != nil
                              || !model.claudeIsReady)
            }
        }
    }
}

@MainActor
final class DesignWindowController: NSWindowController, NSWindowDelegate {
    private let model: DesignModel
    private var keyMonitor: Any?

    init(outlineURL: URL, openSettings: @escaping () -> Void) {
        model = DesignModel(outlineURL: outlineURL)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 800),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Design with Claude"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: DesignView(model: model, openSettings: openSettings))
        window.setContentSize(NSSize(width: 1320, height: 800))
        window.center()
        window.setFrameAutosaveName("KeybowNotesDesign")
        model.editor.undoManager = window.undoManager
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        showWindow(nil)
        window?.bringToFront()
        if let window { WindowSnapshots.keep(window, as: "design") }
        installKeyMonitor()
        // Development builds only: KEYBOW_DRAFT_WANTED says it and sends it,
        // then KEYBOW_DRAFT_THEN once that's answered; KEYBOW_DRAFT_USE=1 adds
        // the draft.
        let environment = ProcessInfo.processInfo.environment
        if Bundle.main.bundleIdentifier == nil, let wanted = environment["KEYBOW_DRAFT_WANTED"], model.messages.isEmpty {
            Task { [model] in
                model.input = wanted
                model.send()
                while model.working != nil { try? await Task.sleep(for: .milliseconds(200)) }
                if let then = environment["KEYBOW_DRAFT_THEN"] {
                    try? await Task.sleep(for: .seconds(1))
                    model.input = then
                    model.send()
                    while model.working != nil { try? await Task.sleep(for: .milliseconds(200)) }
                }
                if environment["KEYBOW_DRAFT_USE"] == "1" {
                    try? await Task.sleep(for: .seconds(2))
                    model.add()
                }
            }
        }
    }

    /// The tree editor's ⌃⌘↑/↓, for the draft's outline; the conversation's
    /// own text field keeps its keys.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if let text = self.window?.firstResponder as? NSTextView, !text.isFieldEditor { return event }
            if let offset = MoveKeys.offset(for: event) {
                self.model.coordinator.move(by: offset)
                return nil
            }
            return event
        }
    }

    @objc func moveNodeUp(_ sender: Any?) { model.coordinator.move(by: -1) }
    @objc func moveNodeDown(_ sender: Any?) { model.coordinator.move(by: 1) }
    @objc func addChildNode(_ sender: Any?) { model.coordinator.addChild() }
    /// ⌘S: there's nothing to save — the draft goes in with Add.
    @objc func saveDocument(_ sender: Any?) { NSSound.beep() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.hasUnaddedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Close without adding the draft?"
        alert.informativeText = "Your tree hasn't changed. The draft and the conversation will be gone."
        alert.addButton(withTitle: "Keep Designing")
        alert.addButton(withTitle: "Close")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
