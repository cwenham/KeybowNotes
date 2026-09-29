import AppKit
import KeybowAI
import KeybowKit
import SwiftUI

/// The Data Sources window: the module's own, opened from the menu bar.
@MainActor
public enum DataSourcesWindow {
    private static var controller: DataSourcesWindowController?

    public static func show(_ module: DataModule) {
        if controller == nil { controller = DataSourcesWindowController(module: module) }
        controller?.show()
    }
}

@MainActor
final class DataSourcesWindowController: NSWindowController, NSWindowDelegate {
    let model: DataSourcesModel

    init(module: DataModule) {
        model = DataSourcesModel(module: module)
        let window = NSWindow(contentViewController: NSHostingController(rootView: DataSourcesView(model: model)))
        window.title = "Data Sources"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 920, height: 640))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("KeybowNotesDataSources")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        model.reload()
        // Development builds only: Find It on the first source as the window
        // opens, for screenshots.
        if Bundle.main.bundleIdentifier == nil, ProcessInfo.processInfo.environment["KEYBOW_DEBUG_DATA_FIND"] != nil,
           let source = model.selected {
            model.findIt(source)
        }
        // A menu-bar app isn't active, so its window would open behind others.
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.cancel()
        // Hand focus back to whatever was in use before, unless the editor's open.
        let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }
        if others.isEmpty { NSApp.hide(nil) }
    }
}

// MARK: - The model

@MainActor @Observable
final class DataSourcesModel {
    let module: DataModule
    var sources: [DataSource] = []
    var selection: UUID?

    /// What's under way for the selected source: "Asking Claude…".
    var busy: String?
    var message: String?
    var messageIsProblem = false
    var proposal: RuleFinder.Proposal?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(module: DataModule) {
        self.module = module
        reload()
        selection = sources.first?.id
        // A key press may find a value, or break a rule, while the window's open.
        observer = NotificationCenter.default.addObserver(forName: DataModule.changed, object: module, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        sources = module.sources
        claudeReady = (ModuleRegistry.shared.module(id: ClaudeModule.id) as? ClaudeModule)?.isReady ?? false
        if let selection, !sources.contains(where: { $0.id == selection }) { self.selection = sources.first?.id }
    }

    var selected: DataSource? { sources.first { $0.id == selection } }

    /// Whether Claude has a key: read with the sources, not on every redraw.
    var claudeReady = false

    func add() {
        var number = 1
        while sources.contains(where: { $0.name == "source\(number)" }) { number += 1 }
        let source = DataSource(name: "source\(number)", url: "https://")
        module.save(source)
        reload()
        select(source.id)
    }

    func remove(_ id: UUID) {
        cancel()
        module.remove(id)
        reload()
        select(sources.first?.id)
    }

    func select(_ id: UUID?) {
        guard id != selection else { return }
        cancel()
        selection = id
        proposal = nil
        message = nil
    }

    func update(_ source: DataSource) {
        module.save(source)
        reload()
    }

    func problems(with source: DataSource) -> [String] {
        var problems: [String] = []
        if !DataSource.isValidName(source.name) {
            problems.append("A name starts with a letter and has only letters, digits, - and _.")
        } else if sources.contains(where: { $0.id != source.id && $0.name.caseInsensitiveCompare(source.name) == .orderedSame }) {
            problems.append("Another source is already called “\(source.name)”.")
        }
        if !source.url.lowercased().hasPrefix("https://") && !source.url.lowercased().hasPrefix("http://localhost") {
            problems.append("The URL must start with https://.")
        }
        return problems
    }

    // MARK: Asking and testing

    /// Fetches a sample and has Claude write a rule for it.
    func findIt(_ source: DataSource) {
        run {
            self.proposal = nil
            self.busy = "Fetching a sample…"
            let sample = try await self.module.sample(source)
            self.busy = "Asking Claude to find the value…"
            let proposal = try await self.module.findRule(for: source, in: sample)
            self.proposal = proposal
            self.say("Claude found “\(Self.short(proposal.value))”. Is that the value you want?")
        }
    }

    func use(_ proposal: RuleFinder.Proposal, for source: DataSource) {
        var updated = source
        updated.rule = proposal.rule
        updated.ruleNote = proposal.note
        updated.lastValue = proposal.value
        updated.lastChecked = Date()
        updated.broken = nil
        update(updated)
        self.proposal = nil
        say("Rule saved. {{api.\(source.name)}} will be “\(Self.short(proposal.value))” until the response changes.")
    }

    func test(_ source: DataSource) {
        run {
            self.busy = "Fetching and applying the rule…"
            let value = try await self.module.test(source)
            self.reload()
            self.say("Found “\(Self.short(value))”.")
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        busy = nil
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        cancel()
        message = nil
        task = Task { @MainActor in
            defer { self.busy = nil; self.task = nil }
            do {
                try await work()
            } catch is CancellationError {
                self.message = nil
            } catch let error as ModuleError {
                self.reload()
                self.say(error.description, problem: true)
            } catch {
                self.say("\(error)", problem: true)
            }
        }
    }

    private func say(_ text: String, problem: Bool = false) {
        message = text
        messageIsProblem = problem
    }

    static func short(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 120 ? String(flat.prefix(120)) + "…" : flat
    }
}

// MARK: - The views

struct DataSourcesView: View {
    @Bindable var model: DataSourcesModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                ForEach(model.sources) { source in
                    SourceRow(source: source).tag(source.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 4) {
                    Button { model.add() } label: { Image(systemName: "plus") }
                        .help("Add a data source")
                    Button { if let id = model.selection { model.remove(id) } } label: { Image(systemName: "minus") }
                        .disabled(model.selection == nil)
                        .help("Remove the selected source, and its key from the Keychain")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        } detail: {
            if let id = model.selection, model.selected != nil {
                SourceDetail(model: model, source: Binding(
                    get: { model.sources.first { $0.id == id } ?? DataSource(name: "") },
                    set: { model.update($0) }
                ))
                .id(id)
            } else {
                VStack(spacing: 8) {
                    Text("No data source selected").font(.title3)
                    Text("Add one with +: an API's URL, its key if it needs one, and the value you want from it.")
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
    }
}

private struct SourceRow: View {
    let source: DataSource

    var body: some View {
        HStack {
            Image(systemName: source.broken != nil ? "exclamationmark.triangle.fill"
                  : source.rule == nil ? "circle.dashed" : "checkmark.circle.fill")
                .foregroundStyle(source.broken != nil ? Color.orange : source.rule == nil ? .secondary : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                if let value = source.lastValue, source.broken == nil {
                    Text(DataSourcesModel.short(value)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if source.broken != nil {
                    Text("Needs fixing").font(.caption).foregroundStyle(.orange)
                } else {
                    Text("No rule yet").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .help(source.broken ?? source.wanted)
    }
}

private struct SourceDetail: View {
    let model: DataSourcesModel
    @Binding var source: DataSource
    @State private var keyDraft = ""
    @State private var hasKey = false
    @State private var editingRule = false
    @State private var ruleKind: ExtractionRule.Kind = .jsonPath
    @State private var ruleExpression = ""

    private static let cacheChoices: [(Int, String)] = [
        (0, "Fetch every time"), (60, "1 minute"), (300, "5 minutes"), (900, "15 minutes"),
        (3600, "1 hour"), (86_400, "1 day"),
    ]

    var body: some View {
        Form {
            sourceSection
            if !source.urlNames.isEmpty { sampleSection }
            keySection
            valueSection
            ruleSection
        }
        .formStyle(.grouped)
        .onAppear {
            hasKey = model.module.key(for: source.id) != nil
            ruleKind = source.rule?.kind ?? .jsonPath
            ruleExpression = source.rule?.expression ?? ""
        }
    }

    // MARK: Sections

    private var sourceSection: some View {
        Section("Source") {
            TextField("Name", text: $source.name)
                .help("How templates refer to it: {{api.name}} for the value, {{api.name.raw}} for the whole response.\nExample: weather")
            WideField(title: "URL", text: $source.url, prompt: "https://api.example.com/v1/current?city={{city}}")
                .help("The address to fetch, over https. Placeholders take values from the key being pressed — {{selection}} and {{location.latitude}} too — and are encoded as in any link.\nExample: https://api.open-meteo.com/v1/forecast?latitude={{location.latitude}}&longitude={{location.longitude}}&current=temperature_2m")
            Picker("Keep responses for", selection: $source.cacheSeconds) {
                ForEach(Self.cacheChoices, id: \.0) { Text($0.1).tag($0.0) }
            }
            .help("Reuse a response for this long instead of fetching again — kinder to rate limits, and quicker. Each URL is kept separately.")
            ForEach(model.problems(with: source), id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            Text("Use it as {{api.\(source.name)}} — or {{api.\(source.name).raw}} for the whole response, to give an {{#ai}} block.")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var sampleSection: some View {
        Section {
            ForEach(source.urlNames.sorted(), id: \.self) { name in
                // {{location.latitude}}: fetched here as for a key, unless given.
                let fetched = ModuleRegistry.shared.module(fetching: name) != nil
                TextField(name, text: Binding(
                    get: { source.sampleValues[name] ?? "" },
                    set: { source.sampleValues[name] = $0.isEmpty ? nil : $0 }
                ), prompt: fetched ? Text(ModuleRegistry.shared.standIn(forValue: name)) : nil)
                .help(fetched
                      ? "Left empty, {{\(name)}} is fetched when you fetch a sample or test, as it is for a key. Fill it in to try another value."
                      : "Used for {{\(name)}} when fetching a sample or testing here. When a key is pressed, the value comes from the tree.")
            }
        } header: {
            Text("Sample values")
        } footer: {
            Text("The URL's placeholders, filled in for fetching a sample here.").font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var keySection: some View {
        Section("API key") {
            Picker("Sent", selection: $source.keyUse) {
                ForEach(DataSource.KeyUse.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .help("How the API expects its key: as a Bearer token in the Authorization header, in a header of its own, or as a parameter in the URL.")
            if source.keyUse == .header || source.keyUse == .query {
                TextField(source.keyUse == .header ? "Header" : "Parameter", text: $source.keyName,
                          prompt: Text(source.keyUse == .header ? "X-API-Key" : "key"))
                    .help(source.keyUse == .header ? "The header's name.\nExample: X-API-Key" : "The query parameter's name.\nExample: appid")
            }
            if source.keyUse != .none {
                if hasKey {
                    LabeledContent("Key") {
                        HStack {
                            Label("Saved in the Keychain", systemImage: "key.fill").foregroundStyle(.secondary)
                            Button("Remove") {
                                _ = model.module.setKey(nil, for: source.id)
                                hasKey = false
                            }
                        }
                    }
                } else {
                    HStack {
                        SecureField("Key", text: $keyDraft, prompt: Text("Paste it here"))
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey).disabled(keyDraft.isEmpty)
                    }
                    .help("Kept in the Keychain, and sent only to this source's server — never to Claude.")
                }
            }
        }
    }

    private var valueSection: some View {
        Section {
            WideField(title: "The value you want", text: $source.wanted, prompt: "The current temperature, in Celsius")
                .help("Describe it in your own words; Claude writes a rule to find it. Kept, to find it again if the API changes.\nExample: the time of the next train to London")
            HStack {
                Button(source.rule == nil ? "Find It with Claude" : "Find It Again") { model.findIt(source) }
                    .disabled(!model.claudeReady || model.busy != nil || source.wanted.isEmpty || !model.problems(with: source).isEmpty)
                if let busy = model.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                    Button("Cancel") { model.cancel() }
                }
            }
            if !model.claudeReady {
                Text("Finding the value needs your Anthropic API key, in Settings → Claude.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let proposal = model.proposal {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Claude suggests a \(proposal.rule.kind.title):").font(.callout.weight(.semibold))
                    Text(proposal.rule.expression).font(.body.monospaced()).textSelection(.enabled)
                    Text("It finds: \(DataSourcesModel.short(proposal.value))").font(.callout.weight(.semibold))
                    if !proposal.note.isEmpty { Text(proposal.note).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("Use This Rule") {
                            model.use(proposal, for: source)
                            ruleKind = proposal.rule.kind
                            ruleExpression = proposal.rule.expression
                        }
                        .keyboardShortcut(.defaultAction)
                        Button("Discard") { model.proposal = nil }
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(model.messageIsProblem ? Color.orange : .secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("The value")
        } footer: {
            Text("Finding it sends a sample of the response and your description to Claude, once. Every key press after that applies the rule here, on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var ruleSection: some View {
        Section("Rule") {
            if let broken = source.broken {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This rule has stopped finding its value.").font(.callout.weight(.semibold))
                        Text(broken).font(.caption)
                        Text("The API may have changed. Claude can write a new rule from your description.").font(.caption)
                        Button("Find It Again") { model.findIt(source) }
                            .disabled(!model.claudeReady || model.busy != nil || source.wanted.isEmpty)
                            .padding(.top, 4)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
            }
            if let rule = source.rule {
                LabeledContent(rule.kind.title) {
                    Text(rule.expression).font(.body.monospaced()).textSelection(.enabled)
                }
                if let value = source.lastValue {
                    LabeledContent("Last found") {
                        Text(DataSourcesModel.short(value)).textSelection(.enabled)
                    }
                }
                if !source.ruleNote.isEmpty {
                    Text(source.ruleNote).font(.caption).foregroundStyle(.secondary)
                }
                Button("Test Now") { model.test(source) }
                    .disabled(model.busy != nil)
                    .help("Fetch the source with its sample values and apply the rule")
            } else {
                Text("No rule yet: describe the value above and use Find It with Claude.").foregroundStyle(.secondary)
            }
            DisclosureGroup("Write the rule yourself", isExpanded: $editingRule) {
                Picker("Kind", selection: $ruleKind) {
                    ForEach(ExtractionRule.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("Rule", text: $ruleExpression, prompt: Text("$.current.temp_c"))
                    .font(.body.monospaced())
                    .help("JSONPath for JSON ($.current.temp_c), XPath for XML or HTML (//item[1]/title), or a regular expression whose first group is the value.")
                Button("Save and Test") {
                    var updated = source
                    updated.rule = ExtractionRule(kind: ruleKind, expression: ruleExpression)
                    updated.ruleNote = ""
                    updated.broken = nil
                    source = updated
                    model.test(updated)
                }
                .disabled(ruleExpression.isEmpty || model.busy != nil)
            }
        }
    }

    /// A field under its label, the width of the form: for long text.
    private struct WideField: View {
        let title: String
        @Binding var text: String
        let prompt: String

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                // Plain, with a border drawn here: a rounded-border field
                // wraps a long URL but stays one line tall, hiding the rest.
                TextField(title, text: $text, prompt: Text(prompt), axis: .vertical)
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
            }
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if let problem = model.module.setKey(key, for: source.id) {
            model.message = problem
            model.messageIsProblem = true
        } else {
            keyDraft = ""
            hasKey = true
        }
    }
}
