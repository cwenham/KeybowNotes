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
    "messages.compose": [.init(key: "to", title: "To"), .init(key: "body", title: "Message")],
    "mail.compose": [.init(key: "to", title: "To"), .init(key: "subject", title: "Subject"), .init(key: "body", title: "Body")],
    "app.open": [
        .init(key: "app", title: "App"), .init(key: "bundleId", title: "Bundle ID"),
        .init(key: "open", title: "Open", hint: "a path or a link"), .init(key: "target", title: "Target"),
    ],
    "shortcut": [.init(key: "name", title: "Shortcut"), .init(key: "input", title: "Input")],
]

private let typeNames: [(String?, String)] = [
    (nil, "Inherit"), ("notes.create", "New note"), ("notes.append", "Add to a note"),
    ("calendar.createEvent", "Calendar event"), ("reminders.create", "Reminder"),
    ("messages.compose", "Message"), ("mail.compose", "Email"), ("app.open", "Open an app"),
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

    private var ownType: String? {
        for annotation in node.annotations {
            switch annotation {
            case .word(let word):
                let lower = word.lowercased()
                if let type = OutlineCompiler.actionTypeWords[lower] { return type }
                if lower == "append" { return "notes.append" }
                if lower == "new" || lower == "create" { return "notes.create" }
            case .pair("type", let value):
                return value
            default:
                break
            }
        }
        return nil
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
            Picker("Type", selection: Binding(
                get: { ownType },
                set: { type in model.edit("Set Type") { try $0.setType(id, type) } }
            )) {
                ForEach(typeNames, id: \.1) { type, name in
                    Text(type == nil ? "Inherit (\(typeName(inheritedTypeAbove)))" : name).tag(type)
                }
            }
            if let type = action?.type, let fields = fieldsByType[type] {
                ForEach(fields, id: \.key) { spec in
                    fieldRow(spec)
                }
            }
        }
    }

    private var inheritedTypeAbove: String? {
        guard let tree, location.path.count > 1 else { return nil }
        return config?.inheritedAction(tree: tree, path: Array(location.path.dropLast()))?.type
    }

    private func ownValue(_ key: String) -> String? {
        for case .pair(key, let value) in node.annotations { return value }
        return nil
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
                case (.alert, "alertMinutes"), (.template, "template"), (.app, "app"), (.target, "target"): return true
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
            LabeledContent(spec.title) {
                Picker("", selection: Binding(
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
            DraftField(title: spec.title, value: own ?? "", placeholder: effectiveValue(spec.key),
                       note: source(of: spec.key), hint: spec.hint) { value in
                setField(spec.key, value.isEmpty ? nil : value)
            }
        }
    }

    /// Writes a field as a pair. Alerts and templates can also be written as
    /// words (`5 min alert`, `worklog.md`); setting the pair replaces those.
    private func setField(_ key: String, _ value: String?) {
        model.edit("Set \(key)") { document in
            if key == "alertMinutes" || key == "template", var current = document.node(id) {
                current.annotations.removeAll { annotation in
                    guard case .word(let word) = annotation else { return false }
                    let lower = word.lowercased()
                    return key == "template" ? lower.hasSuffix(".md") : OutlineCompiler.alertMinutes(lower) != nil
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
                HStack {
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
                LabeledContent(item.key) {
                    Text("\(item.value) — from \(item.from)").foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("name", text: $newKey).frame(width: 90)
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

/// A text field that commits on Return or on leaving it, rather than on every
/// keystroke — one edit, one undo step.
struct DraftField: View {
    let title: String
    let value: String
    var placeholder = ""
    var note = ""
    var hint = ""
    let commit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                TextField(placeholder.isEmpty ? hint : placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(save)
                if !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(note == "set here" ? Color.accentColor : .secondary)
                }
            }
        } label: {
            Text(title)
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
