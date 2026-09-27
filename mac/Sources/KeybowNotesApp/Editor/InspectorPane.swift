import KeybowKit
import SwiftUI

struct InspectorPane: View {
    let model: EditorModel

    var body: some View {
        ScrollView {
            Group {
                if let id = model.selectedNodeID, let node = model.node(id),
                   let location = model.document.location(of: id) {
                    NodeInspector(model: model, id: id, node: node, location: location)
                        .id(id)          // fresh drafts for each node
                } else if case .empty(let location)? = model.selection {
                    Text("Key \(location.slot + 1) is empty. Type to put a node on it.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select a node in the outline, or a key below.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }
}

/// The fields each action type uses, in the order they're shown.
private struct FieldSpec {
    enum Kind { case text, number, flag }

    let key: String
    let title: String
    var kind: Kind = .text
    var hint = ""
}

private let fieldsByType: [String: [FieldSpec]] = [
    "notes.create": [
        .init(key: "title", title: "Title"), .init(key: "folder", title: "Folder", hint: "Levels separated by /"),
        .init(key: "template", title: "Template"), .init(key: "account", title: "Account"),
    ],
    "notes.append": [
        .init(key: "find.byName", title: "Note"), .init(key: "folder", title: "Folder"),
        .init(key: "template", title: "Template"), .init(key: "entry", title: "Entry"),
        .init(key: "createIfMissing", title: "Create if missing", kind: .flag),
        .init(key: "guards.maxBodyBytes", title: "Largest note", kind: .number, hint: "characters"),
        .init(key: "guards.refuseInlineImages", title: "Refuse inline images", kind: .flag),
    ],
    "calendar.createEvent": [
        .init(key: "title", title: "Title"), .init(key: "start", title: "Starts", hint: "tomorrow 14:00, friday…"),
        .init(key: "duration", title: "Duration", hint: "30m, 1h"),
        .init(key: "alertMinutes", title: "Alert", kind: .number, hint: "minutes before"),
        .init(key: "calendar", title: "Calendar"), .init(key: "calendarId", title: "Calendar ID"),
        .init(key: "notes", title: "Notes"), .init(key: "show", title: "Open for editing", kind: .flag),
    ],
    "reminders.create": [
        .init(key: "title", title: "Title"), .init(key: "due", title: "Due", hint: "+25m, tomorrow…"),
        .init(key: "list", title: "List"), .init(key: "notes", title: "Notes"),
    ],
    "messages.compose": [.init(key: "to", title: "To"), .init(key: "body", title: "Message"),
                         .init(key: "template", title: "Template")],
    "mail.compose": [.init(key: "to", title: "To"), .init(key: "subject", title: "Subject"), .init(key: "body", title: "Body"),
                     .init(key: "template", title: "Template")],
    "phone.call": [.init(key: "to", title: "Number"), .init(key: "via", title: "Via", hint: "empty for iPhone, or facetime")],
    "app.open": [
        .init(key: "app", title: "App"), .init(key: "bundleId", title: "Bundle ID"),
        .init(key: "open", title: "Open", hint: "a path or a link"), .init(key: "target", title: "Target"),
    ],
    "shortcut": [.init(key: "name", title: "Shortcut"), .init(key: "input", title: "Input")],
    "url.open": [.init(key: "url", title: "Link", hint: "https://…?q={{selection}}, or a path")],
    "clipboard.copy": [.init(key: "text", title: "Text", hint: "empty copies the label"),
                       .init(key: "template", title: "Template")],
]

private let typeNames: [(String?, String)] = [
    (nil, "Inherit"), ("notes.create", "New note"), ("notes.append", "Add to a note"),
    ("calendar.createEvent", "Calendar event"), ("reminders.create", "Reminder"),
    ("messages.compose", "Message"), ("mail.compose", "Email"), ("phone.call", "Phone call"),
    ("app.open", "Open an app"), ("url.open", "Open a link"), ("clipboard.copy", "Copy to clipboard"),
    ("shortcut", "Run a shortcut"),
]

private func typeName(_ type: String?) -> String {
    typeNames.first { $0.0 == type }?.1 ?? type ?? "—"
}

private struct NodeInspector: View {
    let model: EditorModel
    let id: UUID
    let node: OutlineNode
    let location: OutlineLocation

    private var tree: TreeKind? {
        if case .tree(let kind) = location.container { return kind }
        return nil
    }

    /// The nodes from the top of the tree down to this one.
    private var chain: [OutlineNode] {
        (1...location.path.count).compactMap {
            model.document.node(at: OutlineLocation(location.container, Array(location.path.prefix($0))))
        }
    }

    private var config: KeybowConfig? { model.compilation.config }

    /// Everything down to and including this node — for a branch, what its
    /// leaves inherit.
    private var action: ActionSpec? {
        guard let tree else { return nil }
        return config?.inheritedAction(tree: tree, path: location.path)
    }

    /// The annotations with what the compiler made of each.
    private var annotated: [(Annotation, AnnotationRole)] {
        Array(zip(node.annotations, model.info(id)?.roles ?? []))
    }

    /// The type this node sets itself — by keyword, by naming an app, or `type:`.
    private var ownType: String? {
        for (annotation, role) in annotated {
            switch (annotation, role) {
            case (_, .actionType(let type)), (_, .noteMode(let type)): return type
            case (_, .app): return "app.open"
            case (.pair("type", let value), _): return value
            // A link opens itself when nothing above says what to do with it.
            case (_, .link) where parentType == nil: return "url.open"
            default: continue
            }
        }
        return nil
    }

    /// The type the outline gives this node's parent — not the config's
    /// default action, which applies only where nothing names a type.
    private var parentType: String? {
        chain.dropLast().last.flatMap { model.info($0.id)?.actionType }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            preview
            Divider()
            DraftField(title: "Label", value: node.label) { label in
                model.edit("Rename") { try $0.setLabel(id, label) }
            }
            actionSection
            valuesSection
            entrySection
            problemsSection
        }
    }

    // MARK: - Where and what

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chain.map(\.label).joined(separator: " › "))
                .font(.headline)
                .lineLimit(2)
            if let tree {
                let depth = location.path.count - 1
                Text("\(treeName(tree)) · row \(tree.rows[depth] + 1) · key \(location.slot + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .list(let name) = location.container {
                Text("List @\(name) · key \(location.slot + 1)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let tree, let config, node.isLeaf, let selection = config.resolve(tree: tree, path: location.path) {
            let summary = ActionSummary(selection: selection, config: config)
            VStack(alignment: .leading, spacing: 3) {
                Text("Pressing this")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(summary.verb) · \(summary.subject)")
                    .font(.system(size: 13, weight: .semibold))
                if !summary.details.isEmpty {
                    Text(summary.details.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
                }
                if !summary.missing.isEmpty {
                    Label("Needs \(summary.missing.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        } else if tree != nil, let action {
            Text("Leaves under this: \(typeName(action.type))")
                .font(.callout).foregroundStyle(.secondary)
        } else if model.compilation.config == nil {
            Label("The outline doesn't compile yet; see the problems.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    // MARK: - Action

    @ViewBuilder
    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Action").font(.subheadline.weight(.semibold))
            InspectorRow("Type") {
                Picker("Type", selection: Binding(
                    get: { ownType },
                    set: { type in model.edit("Set Type") { try $0.setType(id, type) } }
                )) {
                    ForEach(Array(typeNames.enumerated()), id: \.offset) { _, entry in
                        let (type, name) = entry
                        Text(type == nil ? "Inherit (\(typeName(inheritedTypeAbove)))" : name).tag(type)
                    }
                }
                .labelsHidden()
            }
            if let type = action?.type, let fields = fieldsByType[type] {
                ForEach(fields, id: \.key) { spec in
                    fieldRow(spec)
                }
            }
            let template = effectiveValue("template")
            if !template.isEmpty {
                TemplateSection(model: model, name: template, source: source(of: "template"))
                    .padding(.top, 6)
            }
        }
    }

    private var inheritedTypeAbove: String? {
        guard let tree, location.path.count > 1 else { return nil }
        return config?.inheritedAction(tree: tree, path: Array(location.path.dropLast()))?.type
    }

    /// A field set here, by a pair or by a word: `[Rider]` sets the app,
    /// `[worklog.md]` the template, `[5 min alert]` the alert.
    private func ownValue(_ key: String) -> String? {
        for case .pair(key, let value) in node.annotations { return value }
        for (annotation, role) in annotated {
            guard case .word(let word) = annotation else { continue }
            switch (role, key) {
            case (.app, "app"), (.template, "template"), (.target, "target"), (.link, "url"), (.link, "open"): return word
            case (.alert(let minutes), "alertMinutes"): return String(minutes)
            default: continue
            }
        }
        return nil
    }

    /// Sets the app, replacing an app word where there is one so the outline
    /// keeps its `[Rider]` style. A bundle ID is written only when the name
    /// alone wouldn't find the app.
    private func setApp(_ name: String?, _ bundle: String?) {
        let roles = model.info(id)?.roles ?? []
        model.edit("Set App") { document in
            guard var current = document.node(id) else { return }
            let appIndex = zip(current.annotations.indices, roles).first { pair in
                if case .app = pair.1, case .word = current.annotations[pair.0] { return true }
                return false
            }?.0
            if let appIndex {
                if let name { current.annotations[appIndex] = .word(name) } else { current.annotations.remove(at: appIndex) }
                try document.setText(id, current.text)
            } else {
                try document.setPair(id, key: "app", value: name)
            }
            let findable = name.flatMap(AppLocator.locate)?.bundleIdentifier != nil
            try document.setPair(id, key: "bundleId", value: findable ? nil : bundle)
        }
    }

    private func effectiveValue(_ key: String) -> String {
        guard let action else { return "" }
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        if parts.count == 2, case .object(let inner)? = action.fields[parts[0]] {
            return inner[parts[1]]?.stringValue ?? ""
        }
        return action.fields[key]?.stringValue ?? ""
    }

    /// "set here", "from Meeting", or "default". A field can be set by a pair
    /// or by a word: `5 min alert` sets alertMinutes, `worklog.md` the template.
    private func source(of key: String) -> String {
        func sets(_ node: OutlineNode) -> Bool {
            let roles = model.info(node.id)?.roles ?? []
            for (annotation, role) in zip(node.annotations, roles) {
                if annotation.key == key { return true }
                switch (role, key) {
                case (.alert, "alertMinutes"), (.template, "template"), (.app, "app"), (.target, "target"),
                     (.link, "url"), (.link, "open"): return true
                default: continue
                }
            }
            return false
        }
        if sets(node) { return "set here" }
        for ancestor in chain.dropLast().reversed() where sets(ancestor) {
            return "from \(ancestor.label)"
        }
        return effectiveValue(key).isEmpty ? "" : "default"
    }

    @ViewBuilder
    private func fieldRow(_ spec: FieldSpec) -> some View {
        let own = ownValue(spec.key)
        switch spec.kind {
        case .flag:
            InspectorRow(spec.title) {
                Picker(spec.title, selection: Binding(
                    get: { own.map { ["true", "yes", "on", "1"].contains($0.lowercased()) ? "on" : "off" } ?? "inherit" },
                    set: { choice in setField(spec.key, choice == "inherit" ? nil : (choice == "on" ? "true" : "false")) }
                )) {
                    Text("Inherit (\(effectiveValue(spec.key).isEmpty ? "—" : effectiveValue(spec.key)))").tag("inherit")
                    Text("On").tag("on")
                    Text("Off").tag("off")
                }
                .labelsHidden()
                .fixedSize()
            }
        default:
            if spec.key == "app" {
                AppField(own: own, placeholder: effectiveValue("app"), note: source(of: "app")) { name, bundle in
                    setApp(name, bundle)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    DraftField(title: spec.title, value: own ?? "", placeholder: effectiveValue(spec.key),
                               note: source(of: spec.key), hint: spec.hint,
                               multiline: ["body", "entry", "notes", "text"].contains(spec.key)) { value in
                        setField(spec.key, value.isEmpty ? nil : value)
                    }
                    if spec.key == "open" {
                        Button("Choose…") { chooseFileToOpen() }.controlSize(.small)
                    }
                }
            }
        }
    }

    private func chooseFileToOpen() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = "Choose a file or folder for the app to open."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setField("open", (url.path as NSString).abbreviatingWithTildeInPath)
    }

    /// Writes a field as a pair. Alerts, templates and links can also be
    /// written as words (`5 min alert`, `worklog.md`, `https://…`); setting the
    /// pair replaces those.
    private func setField(_ key: String, _ value: String?) {
        model.edit("Set \(key)") { document in
            if ["alertMinutes", "template", "url", "open"].contains(key), var current = document.node(id) {
                current.annotations.removeAll { annotation in
                    guard case .word(let word) = annotation else { return false }
                    let lower = word.lowercased()
                    switch key {
                    case "template": return lower.hasSuffix(".md")
                    case "url", "open": return word.contains("://")
                    default: return OutlineCompiler.alertMinutes(lower) != nil
                    }
                }
                try document.setText(id, current.text)
            }
            try document.setPair(id, key: key, value: value)
        }
    }

    // MARK: - Values

    private var ownParameters: [(String, String)] {
        node.annotations.compactMap { annotation in
            guard case .pair(let key, let value) = annotation,
                  !OutlineCompiler.actionFields.contains(key), key != "colour", key != "color" else { return nil }
            return (key, value)
        }
    }

    private var inheritedParameters: [(key: String, value: String, from: String)] {
        var seen = Set(ownParameters.map(\.0))
        var result: [(String, String, String)] = []
        for ancestor in chain.dropLast().reversed() {
            for case .pair(let key, let value) in ancestor.annotations
            where !OutlineCompiler.actionFields.contains(key) && key != "colour" && key != "color" && !seen.contains(key) {
                seen.insert(key)
                result.append((key, value, ancestor.label))
            }
        }
        return result
    }

    @State private var newKey = ""
    @State private var newValue = ""

    private var valuesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Values").font(.subheadline.weight(.semibold))
            ForEach(ownParameters, id: \.0) { key, value in
                HStack(alignment: .firstTextBaseline) {
                    DraftField(title: key, value: value, note: "set here") { updated in
                        model.edit("Set \(key)") { try $0.setPair(id, key: key, value: updated) }
                    }
                    Button {
                        model.edit("Remove \(key)") { try $0.setPair(id, key: key, value: nil) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            ForEach(inheritedParameters, id: \.key) { item in
                InspectorRow(item.key) {
                    Text("\(item.value) — from \(item.from)").foregroundStyle(.secondary)
                }
            }
            HStack(spacing: InspectorLayout.spacing) {
                TextField("name", text: $newKey).frame(width: InspectorLayout.labelWidth)
                TextField("value", text: $newValue)
                Button("Add") {
                    let key = newKey.trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { return }
                    model.edit("Add \(key)") { try $0.setPair(id, key: key, value: newValue) }
                    newKey = ""
                    newValue = ""
                }
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Contact or project

    @ViewBuilder
    private var entrySection: some View {
        if let tree, let selection = config?.resolve(tree: tree, path: location.path) {
            if let name = selection.params["contact.name"] {
                entryFields(.contacts, name: name, title: "Contact", keys: ["phone", "email"], params: selection.params, prefix: "contact.")
            }
            if let name = selection.params["project.name"] {
                entryFields(.projects, name: name, title: "Project", keys: ["path"], params: selection.params, prefix: "project.")
            }
        }
    }

    private func entryFields(_ kind: OutlineEntryKind, name: String, title: String, keys: [String],
                             params: [String: String], prefix: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title): \(name)").font(.subheadline.weight(.semibold))
            let extra = params.keys.filter { $0.hasPrefix(prefix) && $0 != prefix + "name" }
                .map { String($0.dropFirst(prefix.count)) }.filter { !keys.contains($0) }.sorted()
            ForEach(keys + extra, id: \.self) { key in
                DraftField(title: key, value: params[prefix + key] ?? "", note: "shared") { value in
                    model.edit("Set \(key)") { $0.setEntryField(kind, name: name, key: key, value: value) }
                }
            }
            if kind == .contacts {
                ContactLookup(name: name) { key, value in
                    model.edit("Set \(key)") { $0.setEntryField(.contacts, name: name, key: key, value: value) }
                }
            }
        }
    }

    // MARK: - Problems

    @ViewBuilder
    private var problemsSection: some View {
        let problems = model.info(id)?.diagnostics ?? []
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Problems").font(.subheadline.weight(.semibold))
                ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                    Label(problem.message, systemImage: problem.severity == .error ? "exclamationmark.octagon.fill"
                          : problem.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(problem.severity == .error ? .red : problem.severity == .warning ? .orange : .blue)
                        .font(.callout)
                }
            }
        }
    }
}

func treeName(_ tree: TreeKind) -> String {
    switch tree {
    case .main: return "Main tree"
    case .row2: return "Row 2 tree"
    case .row3: return "Row 3 tree"
    case .bottom: return "Bottom tree"
    }
}

/// One labelled row of the inspector. Labels sit in a right-aligned column
/// so the controls line up, and each label is level with the first line of
/// text in its control — not centred on the control and whatever note or
/// extra lines sit beneath it.
enum InspectorLayout {
    static let labelWidth: CGFloat = 104
    static let spacing: CGFloat = 8
}

struct InspectorRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: InspectorLayout.spacing) {
            Text(title)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: InspectorLayout.labelWidth, alignment: .trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A text field that commits on Return or on leaving it, rather than on every
/// keystroke — one edit, one undo step.
struct DraftField: View {
    let title: String
    let value: String
    var placeholder = ""
    var note = ""
    var hint = ""
    /// Grows to several lines; ⌥Return starts a new line.
    var multiline = false
    let commit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        InspectorRow(title) {
            VStack(alignment: .trailing, spacing: 2) {
                TextField(placeholder.isEmpty ? hint : placeholder, text: $draft, axis: multiline ? .vertical : .horizontal)
                    .lineLimit(multiline ? 1...6 : 1...1)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(save)
                if !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(note == "set here" ? Color.accentColor : .secondary)
                }
            }
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, newValue in if !focused { draft = newValue } }
        .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed != value { commit(trimmed) }
    }
}

/// The app to open: type a name (with completion from the installed apps),
/// or choose one in the file browser. Records the bundle ID too, so the app is
/// found wherever it lives.
private struct AppField: View {
    let own: String?
    let placeholder: String
    let note: String
    let set: (String?, String?) -> Void

    var body: some View {
        InspectorRow("App") {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    AppComboBox(value: own ?? "", placeholder: placeholder) { name in
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return set(nil, nil) }
                        set(trimmed, AppCatalog.named(trimmed)?.bundleIdentifier)
                    }
                    Button("Choose…", action: choose).controlSize(.small)
                }
                if !note.isEmpty {
                    Text(note).font(.caption2).foregroundStyle(note == "set here" ? Color.accentColor : .secondary)
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose the app to open."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        set(url.deletingPathExtension().lastPathComponent, Bundle(url: url)?.bundleIdentifier)
    }
}

private struct AppComboBox: NSViewRepresentable {
    let value: String
    let placeholder: String
    let commit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(commit: commit) }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.completes = true
        box.numberOfVisibleItems = 16
        box.addItems(withObjectValues: AppCatalog.all.map(\.name))
        box.delegate = context.coordinator
        box.stringValue = value
        box.placeholderString = placeholder
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.commit = commit
        if box.currentEditor() == nil, box.stringValue != value { box.stringValue = value }
        box.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var commit: (String) -> Void

        init(commit: @escaping (String) -> Void) {
            self.commit = commit
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox, box.indexOfSelectedItem >= 0,
                  let name = box.itemObjectValue(at: box.indexOfSelectedItem) as? String else { return }
            commit(name)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            commit(box.stringValue)
        }
    }
}

/// Finds a contact by name in the Contacts app and offers their numbers and
/// addresses to fill in.
private struct ContactLookup: View {
    let name: String
    let apply: (String, String) -> Void

    @State private var matches: [ContactsService.Match] = []
    @State private var searched = false
    @State private var denied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !ContactsService.isAvailable {
                Text("Looking people up in Contacts works in KeybowNotes.app.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !ContactsService.isAuthorised {
                Button("Look Up “\(name)” in Contacts…") {
                    NSApp.activate()
                    Task {
                        denied = await ContactsService.shared.requestAccess() != .granted
                        await search()
                    }
                }
                .controlSize(.small)
                if denied {
                    Text("KeybowNotes isn't allowed to read Contacts. Allow it in System Settings → Privacy & Security → Contacts.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else if searched && matches.isEmpty {
                Text("No one called “\(name)” in Contacts.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(matches) { match in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(match.organisation.isEmpty ? match.name : "\(match.name) · \(match.organisation)")
                            .font(.caption.weight(.semibold))
                        ForEach(match.phones, id: \.self) { phone in
                            Button { apply("phone", phone.value) } label: {
                                Label("\(phone.label.isEmpty ? "phone" : phone.label)  \(phone.value)", systemImage: "phone")
                            }
                        }
                        ForEach(match.emails, id: \.self) { email in
                            Button { apply("email", email.value) } label: {
                                Label("\(email.label.isEmpty ? "email" : email.label)  \(email.value)", systemImage: "envelope")
                            }
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                if !matches.isEmpty {
                    Text("From Contacts: click one to use it.").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: name) { await search() }
    }

    private func search() async {
        guard ContactsService.isAuthorised else { return }
        matches = await ContactsService.shared.search(name)
        searched = true
    }
}
