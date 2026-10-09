import AppKit
import KeybowAI
import KeybowKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let actions: SettingsActions

    @State private var calendars: [EventKitService.Choice] = []
    @State private var lists: [EventKitService.Choice] = []
    /// What macOS allows, for the Privacy page.
    @State private var access = MacAccess()

    /// Modules with settings of their own: a page each, after the app's.
    private var modules: [KeybowModule] {
        ModuleRegistry.shared.all.filter { !$0.manifest.settings.isEmpty }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $settings.pane) {
                Section {
                    ForEach(SettingsPane.standard, id: \.self) { pane in
                        Label(pane.title, systemImage: pane.symbol).tag(pane)
                    }
                }
                if !modules.isEmpty {
                    Section("Modules") {
                        ForEach(modules, id: \.manifest.id) { module in
                            Label(module.manifest.name, systemImage: module.manifest.symbol)
                                .tag(SettingsPane.module(module.manifest.id))
                        }
                    }
                }
            }
            // In a window of AppKit's making the column width alone is
            // ignored, and the sidebar cuts "Calendar & Reminders" short.
            .frame(minWidth: 200)
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Form { page }
                .formStyle(.grouped)
                // A page of its own each time: its rows read their settings afresh.
                .id(settings.pane)
                // Closed, the window keeps its views: nothing's watched then.
                .task(id: settings.isWindowOpen ? settings.pane : nil) {
                    guard settings.isWindowOpen else { return }
                    switch settings.pane {
                    case .privacy?: await access.watch()
                    // Again each time: access may have been given since, on the Privacy page.
                    case .calendar?: await loadChoices()
                    default: break
                    }
                }
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    @ViewBuilder
    private var page: some View {
        switch settings.pane ?? .general {
        case .general:
            keypads
            general
            selectionSection
        case .keys:
            lights
            timing
        case .overlay:
            overlay
        case .calendar:
            calendarSection
        case .tree:
            configSection
        case .privacy:
            PrivacyPane(access: access)
        case .module(let id):
            moduleSections(id)
        }
    }

    // MARK: - Pages

    private var keypads: some View {
        Section("Keypads") {
            LabeledContent("Status") {
                HStack {
                    Text(settings.keybowStatus).foregroundStyle(.secondary)
                    Button("Troubleshoot…") { actions.troubleshoot(nil) }
                        .controlSize(.small)
                }
            }
            ForEach(settings.missingKeypads) { missing in
                MissingKeypadRow(missing: missing, actions: actions)
            }
        }
    }

    private var general: some View {
        Section {
            Toggle("Open at login", isOn: Binding(get: { settings.openAtLogin }, set: actions.setOpenAtLogin))
            if let note = settings.openAtLoginNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Toggle(isOn: $settings.dryRun) {
                Text("Dry run")
                Text("Show what an action would do, without doing it.")
            }
        }
    }

    private var lights: some View {
        Section("Lights") {
            LabeledContent("Key brightness") {
                HStack {
                    Slider(value: $settings.brightness, in: 0.05...1)
                    Text("\(Int((settings.brightness * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    private var overlay: some View {
        Section("Overlay") {
            Picker("Show on", selection: $settings.placement) {
                Text("The screen with the pointer").tag(OverlayPlacement.screenWithCursor)
                Text("The main screen, with the menu bar").tag(OverlayPlacement.mainScreen)
                let names = NSScreen.screens.map(\.localizedName)
                if !names.isEmpty {
                    Divider()
                    ForEach(names, id: \.self) { name in
                        Text(name).tag(OverlayPlacement.display(name))
                    }
                }
                // A remembered display that isn't connected right now.
                if case .display(let name) = settings.placement, !names.contains(name) {
                    Text("\(name) (not connected)").tag(settings.placement)
                }
            }
            HStack {
                Text("A display that isn't connected falls back to the one with the pointer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Test", action: actions.testOverlay)
            }
        }
    }

    private var timing: some View {
        Section {
            TimingRow(title: "Time to cancel",
                      explanation: "After the last key, before the action runs. Any key cancels. 0 runs at once.",
                      value: $settings.commitDelay, fileValue: settings.fileTimings.commitDelay,
                      range: 0...3, step: 0.1)
            TimingRow(title: "Hold to clear",
                      explanation: "Holding any key this long abandons an unfinished choice.",
                      value: $settings.longPressCancel, fileValue: settings.fileTimings.longPressCancel,
                      range: 0.8...3, step: 0.1)
            TimingRow(title: "Give up after",
                      explanation: "An unfinished choice clears itself after this long untouched.",
                      value: $settings.idleTimeout, fileValue: settings.fileTimings.idleTimeout,
                      range: 3...30, step: 1)
        } header: {
            HStack {
                Text("Timing")
                Spacer()
                Button("Use the Config File's Timings") { settings.useFileTimings() }
                    .controlSize(.small)
                    .disabled(!settings.hasTimingOverrides)
            }
        }
    }

    @ViewBuilder
    private var calendarSection: some View {
        Section("Calendar and Reminders") {
            if !EventKitService.isAvailable {
                Text("Available when running as KeybowNotes.app.")
                    .foregroundStyle(.secondary)
            } else if calendars.isEmpty && lists.isEmpty {
                HStack {
                    Text("KeybowNotes needs full access to list your calendars.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow Access…") {
                        Task {
                            await actions.requestCalendarAccess()
                            await loadChoices()
                        }
                    }
                }
            } else {
                choicePicker("New events go to", selection: $settings.defaultCalendarID,
                             choices: calendars, systemDefault: "Calendar's default calendar")
                choicePicker("New reminders go to", selection: $settings.defaultReminderListID,
                             choices: lists, systemDefault: "Reminders' default list")
                Text("Used when a tree doesn't name a calendar or list itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectionSection: some View {
        Section("Selected Text") {
            HStack {
                if settings.accessibilityAllowed {
                    Label("{{selection}} can read the text selected in the app in front.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Text("{{selection}} needs Accessibility access to read the text selected in other apps.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Allow Access…") { SelectedText.requestAccess() }
                }
            }
            Toggle(isOn: $settings.copySelection) {
                Text("Copy with ⌘C when an app won't share its selection")
                Text("Needed for Chrome and apps built like it. The clipboard is put back straight afterwards, though a clipboard manager may record the copy.")
            }
        }
        .task {
            // Access is granted in System Settings, which doesn't tell us.
            while !Task.isCancelled {
                settings.accessibilityAllowed = SelectedText.isAllowed
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// A module's own settings, as it describes them.
    @ViewBuilder
    private func moduleSections(_ id: String) -> some View {
        if let module = ModuleRegistry.shared.module(id: id) {
            Section(module.manifest.name) {
                ForEach(module.manifest.settings, id: \.key) { setting in
                    ModuleSettingRow(module: id, setting: setting)
                }
            }
            if id == ClaudeModule.id {
                Section {
                    HStack {
                        Text("What Claude is sent — your tree, your music, the selected text — is chosen in Privacy.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Privacy…") { settings.pane = .privacy }
                    }
                }
            }
        }
    }

    private var configSection: some View {
        Section("Config File") {
            LabeledContent("File") {
                Text(abbreviated(settings.configURL.path))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let problem = settings.configProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else if !settings.configSummary.isEmpty {
                Text(settings.configSummary).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Choose…", action: chooseConfig)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([settings.configURL])
                }
                if !settings.configPath.isEmpty {
                    Button("Use Default") { settings.configPath = "" }
                }
                Spacer()
                Button("Reload", action: actions.reloadConfig)
            }
        }
    }

    // MARK: - Pieces

    private func choicePicker(_ title: String, selection: Binding<String>, choices: [EventKitService.Choice],
                              systemDefault: String) -> some View {
        Picker(title, selection: selection) {
            Text(systemDefault).tag("")
            let accounts = choices.reduce(into: [String]()) { if !$0.contains($1.account) { $0.append($1.account) } }
            ForEach(accounts, id: \.self) { account in
                Section(account) {
                    ForEach(choices.filter { $0.account == account }) { choice in
                        Label {
                            Text(choice.title)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(Color(red: Double(choice.colour.red) / 255,
                                                       green: Double(choice.colour.green) / 255,
                                                       blue: Double(choice.colour.blue) / 255))
                        }
                        .tag(choice.id)
                    }
                }
            }
            // A saved choice that no longer exists.
            if !selection.wrappedValue.isEmpty, !choices.contains(where: { $0.id == selection.wrappedValue }) {
                Text("A calendar that no longer exists").tag(selection.wrappedValue)
            }
        }
    }

    private func loadChoices() async {
        let loaded = await actions.loadCalendarChoices()
        calendars = loaded.calendars
        lists = loaded.lists
    }

    private func chooseConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .json]
        panel.directoryURL = settings.configURL.deletingLastPathComponent()
        panel.message = "Choose a KeybowNotes tree — an outline, like tree.md. Its templates folder should sit beside it."
        if panel.runModal() == .OK, let url = panel.url {
            settings.configPath = url.path == AppLocations.defaultTree.path ? "" : url.path
        }
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// A keypad that was set up, or that the tree names, and isn't connected.
private struct MissingKeypadRow: View {
    let missing: MissingKeypad
    let actions: SettingsActions

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("The \(missing.keypad.name) isn’t connected")
                Text(seen).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if missing.canForget, let serial = missing.keypad.serial {
                Button("Forget") { actions.forgetKeypad(serial) }
                    .controlSize(.small)
                    .help("For a keypad given away: stop looking for it")
            }
            Button("Find It…") { actions.troubleshoot(missing.id) }
                .controlSize(.small)
        }
    }

    private var seen: String {
        guard let last = missing.keypad.lastSeen else {
            return missing.keypad.serial.map { "ID \($0) — not seen on this Mac yet" } ?? "Not seen on this Mac yet"
        }
        return "Last seen \(Troubleshooter.when(last))" + (missing.keypad.lastPlace.map { ", on \($0)" } ?? "")
    }
}

/// A timing slider that shows whether the value comes from the config file or
/// was set here. Moving it sets it here.
private struct TimingRow: View {
    let title: String
    let explanation: String
    @Binding var value: Double?
    let fileValue: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                HStack {
                    // Smooth rather than stepped: a stepped slider draws a tick for
                    // every step, which crowds the row. The value is rounded instead.
                    Slider(value: Binding(get: { value ?? fileValue },
                                          set: { value = ($0 / step).rounded() * step }), in: range)
                    Text(formatted(value ?? fileValue))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            HStack {
                Text(explanation)
                Spacer()
                Text(value == nil ? "from the config file" : "set here")
                    .foregroundStyle(value == nil ? .secondary : Color.accentColor)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func formatted(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
    }
}

/// A setting of the `several` kind: every one of what the module lists —
/// the person's calendars — or only those ticked, kept as their values
/// separated by commas. Kept empty, it's every one.
private struct SeveralSettingRow: View {
    let module: String
    let setting: ModuleSetting
    /// "Every calendar".
    let all: String

    /// As kept, in the order ticked.
    @State private var chosen: [String] = []
    @State private var onlySome = false
    /// Nil until the module has said.
    @State private var choices: [FieldChoice]?
    @State private var problem: String?

    private var host: AppModuleHost { Modules.host }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(setting.title, selection: Binding(get: { onlySome }, set: chooseOnlySome)) {
                Text(all).tag(false)
                Text("Only these:").tag(true)
            }
            .pickerStyle(.radioGroup)
            if onlySome {
                if choices == nil { ProgressView().controlSize(.small) }
                ForEach(rows, id: \.value) { choice in
                    Toggle(choice.title ?? choice.value, isOn: ticked(choice.value))
                        .toggleStyle(.checkbox)
                        // One stays ticked: none would be kept as every one.
                        .disabled(chosen.count == 1 && isChosen(choice.value))
                }
                .padding(.leading, 20)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            chosen = host.setting(setting.key, for: module).map(Self.names) ?? []
            onlySome = !chosen.isEmpty
            do {
                choices = try await ModuleRegistry.shared.module(id: module)?.choices(forSetting: setting.key) ?? []
            } catch {
                choices = []
                problem = "\(error)"
            }
        }
    }

    /// What's offered, and anything kept that isn't among it any more.
    private var rows: [FieldChoice] {
        let offered = choices ?? []
        let gone = chosen.filter { name in !offered.contains { $0.value.lowercased() == name.lowercased() } }
        return offered + gone.map { FieldChoice($0, title: "\($0) — not found") }
    }

    private func isChosen(_ value: String) -> Bool {
        chosen.contains { $0.lowercased() == value.lowercased() }
    }

    private func ticked(_ value: String) -> Binding<Bool> {
        Binding(get: { isChosen(value) }, set: { on in
            if on, !isChosen(value) { chosen.append(value) }
            if !on { chosen.removeAll { $0.lowercased() == value.lowercased() } }
            keep()
        })
    }

    /// Only some starts with every one ticked, to untick from.
    private func chooseOnlySome(_ some: Bool) {
        onlySome = some
        chosen = some ? (choices ?? []).map(\.value) : []
        keep()
    }

    private func keep() {
        host.setSetting(chosen.isEmpty ? nil : chosen.joined(separator: ", "), setting.key, for: module)
    }

    /// "Work, Family" → ["Work", "Family"].
    static func names(_ kept: String) -> [String] {
        kept.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// One module setting, with what it's for written beneath: a secret goes to
/// the Keychain and is never shown again; the rest are kept with the app's
/// settings.
private struct ModuleSettingRow: View {
    let module: String
    let setting: ModuleSetting

    @State private var value = ""
    @State private var draft = ""
    @State private var stored = false
    @State private var replacing = false
    @State private var problem: String?

    private var host: AppModuleHost { Modules.host }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Written out, rather than a tooltip: one went unseen.
            if !setting.help.isEmpty {
                Text(setting.help).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            value = host.setting(setting.key, for: module) ?? ""
            stored = setting.kind == .secret && host.hasSecret(setting.key, for: module)
        }
    }

    @ViewBuilder
    private var control: some View {
        switch setting.kind {
        case .secret: secret
        case .choice(let choices):
            Picker(setting.title, selection: Binding(
                get: { value.isEmpty ? setting.defaultValue : value },
                set: { value = $0; host.setSetting($0, setting.key, for: module) }
            )) {
                ForEach(choices, id: \.value) { Text($0.title).tag($0.value) }
            }
        case .flag:
            Toggle(setting.title, isOn: Binding(
                get: { (value.isEmpty ? setting.defaultValue : value) == "true" },
                set: { value = $0 ? "true" : "false"; host.setSetting(value, setting.key, for: module) }
            ))
        case .text:
            TextField(setting.title, text: $value, prompt: Text(setting.defaultValue))
                .onSubmit { host.setSetting(value.isEmpty ? nil : value, setting.key, for: module) }
        case .several(let all):
            SeveralSettingRow(module: module, setting: setting, all: all)
        }
    }

    @ViewBuilder
    private var secret: some View {
        if stored && !replacing {
            LabeledContent(setting.title) {
                HStack {
                    Label("Saved in the Keychain", systemImage: "key.fill").foregroundStyle(.secondary)
                    Spacer()
                    Button("Replace…") { replacing = true }
                    Button("Remove") {
                        problem = host.setSecret(nil, setting.key, for: module)
                        stored = host.hasSecret(setting.key, for: module)
                    }
                }
            }
        } else {
            HStack {
                SecureField(setting.title, text: $draft, prompt: Text("Paste it here"))
                    .onSubmit(save)
                Button("Save", action: save).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if replacing { Button("Cancel") { replacing = false; draft = "" } }
            }
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        problem = host.setSecret(key, setting.key, for: module)
        stored = host.hasSecret(setting.key, for: module)
        if problem == nil { draft = ""; replacing = false }
    }
}
