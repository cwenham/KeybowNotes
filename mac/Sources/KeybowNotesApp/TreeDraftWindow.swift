import AppKit
import KeybowAI
import KeybowKit
import SwiftUI

/// Describe what the keypads are for, and Claude drafts their trees: told
/// what KeybowNotes can do — the guide for agents, the language, the action
/// types here — and what the person has. The draft is checked, corrected
/// once if it needs it, and shown before anything changes.
@MainActor
@Observable
final class TreeDraftModel {
    enum Where: Hashable { case newKeypad, keypad, tree }

    enum Phase {
        case writing
        case drafting(since: Date, step: String)
        case drafted(outline: String, note: String, check: String, mistakes: String?)
        case failed(String, String?)
        case used(String, keypad: Int)
    }

    var wanted = ""
    var place: Where = .newKeypad
    var newName = "Drafted"
    var newModel: KeypadDevice.Model?
    var keypad = 0
    var tree: TreeKind = .main
    /// Send the tree file — contacts and projects too — for Claude to fit in with.
    var sendOutline = true
    /// Send the apps installed, the shortcuts and Home Assistant's entities.
    var sendWhatsHere = true
    private(set) var phase: Phase = .writing
    private(set) var keypadNames: [String] = ["Default"]
    @ObservationIgnored private var task: Task<Void, Never>?

    var claudeIsReady: Bool {
        (ModuleRegistry.shared.module(id: ClaudeModule.id) as? ClaudeModule)?.isReady ?? false
    }

    func refresh() {
        keypadNames = (try? Automation.shared?.document()).map(TreeControl.keypadNames) ?? ["Default"]
        keypad = min(keypad, keypadNames.count - 1)
        // A section for no model is used by no keypad: start from one that's here.
        if newModel == nil { newModel = USBSerialPorts.keypads().first?.model }
    }

    var scope: TreeDraft.Scope {
        switch place {
        case .newKeypad:
            let name = newName.trimmingCharacters(in: .whitespaces)
            return .newKeypad(name: name.isEmpty ? "Drafted" : name, model: newModel)
        case .keypad: return .keypad(keypad)
        case .tree: return .tree(tree, keypad: keypad)
        }
    }

    var isDrafting: Bool {
        if case .drafting = phase { return true }
        return false
    }

    func draft() {
        let wanted = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !isDrafting else { return }
        let scope = scope
        phase = .drafting(since: Date(), step: "Gathering what's here…")
        task = Task {
            do {
                guard let automation = Automation.shared,
                      let claude = ModuleRegistry.shared.module(id: ClaudeModule.id) as? ClaudeModule else {
                    throw Automation.Problem("KeybowNotes is still starting.")
                }
                let document = try automation.document()
                let context = await gather(document: document)
                let system = TreeDraft.system(guide: try AgentGuide.text(), catalog: AgentGuide.catalog())
                setStep("Claude is drafting…")
                var reply = try await claude.ask(system: system, prompt: TreeDraft.request(wanted, scope: scope, document: document,
                                                                                          context: context),
                                                 effort: "medium", maxTokens: 32_000, timeout: 600)
                guard var outline = TreeDraft.outline(in: reply) else {
                    throw Automation.Problem("Claude didn't answer with an outline. Try again, or say more about what you'd like.")
                }
                if let mistakes = TreeDraft.mistakes(outline) {
                    setStep("Claude is correcting its draft…")
                    reply = try await claude.ask(system: system,
                                                 prompt: TreeDraft.repair(wanted, scope: scope, document: document,
                                                                          context: context, draft: outline, mistakes: mistakes),
                                                 effort: "medium", maxTokens: 32_000, timeout: 600)
                    outline = TreeDraft.outline(in: reply) ?? outline
                }
                phase = .drafted(outline: outline, note: TreeDraft.note(in: reply),
                                 check: TreeControl.check(outline, locateApp: AppLocator.locate),
                                 mistakes: TreeDraft.mistakes(outline))
            } catch is CancellationError {
                phase = .writing
            } catch let error as ModuleError {
                phase = .failed(error.message, error.detail)
            } catch {
                phase = .failed("\(error)", nil)
            }
        }
    }

    private func setStep(_ step: String) {
        if case .drafting(let since, _) = phase { phase = .drafting(since: since, step: step) }
    }

    /// What the person has, as far as they've agreed to send it.
    private func gather(document: OutlineDocument) async -> TreeDraft.Context {
        var context = TreeDraft.Context()
        if sendOutline { context.outline = OutlineWriter.text(document) }
        context.keypads = Automation.shared?.connectedKeypads(in: document) ?? []
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

    func cancel() {
        task?.cancel()
    }

    func use() {
        guard case .drafted(let outline, _, _, _) = phase, let automation = Automation.shared else { return }
        do {
            var said = try automation.applyDraft(outline, scope: scope)
            refresh()
            let index: Int
            switch scope {
            case .newKeypad: index = keypadNames.count - 1
            case .keypad(let keypad), .tree(_, let keypad): index = keypad
            }
            // Trees no keypad uses are felt nowhere: say so.
            let document = try automation.document()
            let users = automation.connectedKeypads(in: document).filter { $0.hasSuffix("“\(keypadNames[index])”") }
            if users.isEmpty, !USBSerialPorts.keypads().isEmpty {
                said += " No keypad that's plugged in uses it yet: in the tree editor, give its section the ID of the "
                    + "keypad it's for, or a model no other section claims."
            }
            phase = .used(said, keypad: index)
        } catch {
            phase = .failed("\(error)", nil)
        }
    }

    func again() {
        phase = .writing
    }
}

struct TreeDraftView: View {
    @Bindable var model: TreeDraftModel
    let openSettings: () -> Void
    let openEditor: (Int) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars").font(.system(size: 26)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Describe Your Keypads").font(.title2.weight(.semibold))
                    Text("Say what you'd like them for, and Claude drafts the trees. You see the draft before anything changes.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.claudeIsReady {
                HStack {
                    Label("Drafting needs your Anthropic API key, in Settings → Claude.", systemImage: "key.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Settings", action: openSettings)
                }
            }
            switch model.phase {
            case .writing, .failed: writing
            case .drafting(let since, let step): drafting(since, step)
            case .drafted(let outline, let note, let check, let mistakes): drafted(outline, note, check, mistakes)
            case .used(let said, let keypad): used(said, keypad)
            }
        }
        .padding(20)
        .frame(width: 660, height: 660)
        .onAppear { model.refresh() }
    }

    // MARK: Writing

    private var writing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What would you like your keypads to do?").font(.headline)
            TextEditor(text: $model.wanted)
                .font(.body)
                .frame(minHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .overlay(alignment: .topLeading) {
                    if model.wanted.isEmpty {
                        Text("I write fiction in Ulysses and want quick ways to jot ideas and log word counts. I'd like the "
                             + "lamps in my study on a page, a timer for writing sprints, and to message my editor, Sam.")
                            .foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                    }
                }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Draft", selection: $model.place) {
                        Text("A new keypad section, with all its trees").tag(TreeDraftModel.Where.newKeypad)
                        Text("All of a keypad's trees, replacing them").tag(TreeDraftModel.Where.keypad)
                        Text("One tree, replacing it").tag(TreeDraftModel.Where.tree)
                    }
                    .pickerStyle(.radioGroup)
                    switch model.place {
                    case .newKeypad:
                        HStack {
                            TextField("Name", text: $model.newName).frame(width: 180)
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
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Send my tree file, so the draft fits with it — its contacts and projects too", isOn: $model.sendOutline)
            Toggle("Send the names of my apps, shortcuts and Home Assistant's entities, so it uses them", isOn: $model.sendWhatsHere)
            Text("What you write, and what's ticked, goes to Anthropic with your API key. Nothing changes here until you "
                 + "use the draft.")
                .font(.caption).foregroundStyle(.secondary)
            if case .failed(let message, let detail) = model.phase {
                Label(message + (detail.map { " — \($0)" } ?? ""), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                Button("Draft", action: model.draft)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.wanted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.claudeIsReady)
            }
        }
    }

    private var keypadPicker: some View {
        Picker(model.place == .tree ? "tree of" : "Keypad", selection: $model.keypad) {
            ForEach(Array(model.keypadNames.enumerated()), id: \.offset) { index, name in Text(name).tag(index) }
        }
        .fixedSize()
    }

    // MARK: Drafting

    private func drafting(_ since: Date, _ step: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(step).font(.headline)
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text("\(Int(context.date.timeIntervalSince(since))) seconds — a thorough draft can take a minute or two.")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Button("Stop", action: model.cancel)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: The draft

    private func drafted(_ outline: String, _ note: String, _ check: String, _ mistakes: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The draft").font(.headline)
            ScrollView {
                Text(outline)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 220)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            if !note.isEmpty {
                ScrollView {
                    Text(note).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
            if let mistakes {
                Label("It still has mistakes; what they touch would be left out:\n" + mistakes, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            } else if !check.hasPrefix("OK:") {
                Text(check).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Change What I Asked") { model.again() }
                Button("Draft Again", action: model.draft)
                Spacer()
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                Button(useTitle, action: model.use).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var useTitle: String {
        switch model.place {
        case .newKeypad: return "Add It"
        case .keypad, .tree: return "Replace with It"
        }
    }

    private func used(_ said: String, _ keypad: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(said, systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
            Text("KeybowNotes is using it. The tree file as it was is kept beside it as tree.md.previous.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open the Tree Editor") { openEditor(keypad) }
                Button("Draft Something Else") { model.again() }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
    }
}

@MainActor
final class TreeDraftWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = TreeDraftModel()
    private let openSettings: () -> Void
    private let openEditor: (Int) -> Void

    init(openSettings: @escaping () -> Void, openEditor: @escaping (Int) -> Void) {
        self.openSettings = openSettings
        self.openEditor = openEditor
    }

    func show() {
        if window == nil {
            let view = TreeDraftView(model: model, openSettings: openSettings, openEditor: openEditor,
                                     close: { [weak self] in self?.window?.performClose(nil) })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Describe Your Keypads"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
            WindowSnapshots.keep(window, as: "draft")
        }
        model.refresh()
        window?.bringToFront()
        // Development builds only: KEYBOW_DRAFT_WANTED types a description and
        // presses Draft; KEYBOW_DRAFT_USE=1 then uses what comes back.
        let environment = ProcessInfo.processInfo.environment
        if Bundle.main.bundleIdentifier == nil, let wanted = environment["KEYBOW_DRAFT_WANTED"], model.wanted.isEmpty {
            model.wanted = wanted
            model.draft()
            if environment["KEYBOW_DRAFT_USE"] == "1" {
                Task { [model] in
                    while model.isDrafting { try? await Task.sleep(for: .milliseconds(200)) }
                    try? await Task.sleep(for: .seconds(3))
                    model.use()
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.cancel()
        window = nil
    }
}
