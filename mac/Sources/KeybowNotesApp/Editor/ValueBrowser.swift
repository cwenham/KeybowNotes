import AppKit
import KeybowKit
import SwiftUI

/// Every value there is, for one field — like a spreadsheet's function
/// browser: a list to search and choose from, each with what it holds and
/// what it comes to at this key, above the field's text, larger, with what
/// that comes to and anything wrong with it. Double-click a value, or Insert,
/// to put it in at the caret.
struct ValueBrowser: View {
    let title: String
    let context: ValueContext
    let multiline: Bool
    let done: (String) -> Void

    @State private var text: String
    @State private var search = ""
    @State private var chosen: String?
    @State private var issues: [TemplateIssue] = []
    @State private var handle = ValueEditorHandle()
    @Environment(\.dismiss) private var dismiss

    init(title: String, text: String, context: ValueContext, multiline: Bool, done: @escaping (String) -> Void) {
        self.title = title
        self.context = context
        self.multiline = multiline
        self.done = done
        _text = State(initialValue: text)
    }

    private struct Row: Identifiable {
        let id: String
        let entry: ValueEntry
    }

    /// The groups, and in each the values that match the search.
    private var sections: [(group: String, rows: [Row])] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return context.catalog.groups.compactMap { group in
            let rows = context.catalog.entries(in: group).filter { entry in
                query.isEmpty || [entry.name, entry.title, entry.help].contains { $0.lowercased().contains(query) }
            }.map { Row(id: "\(group)|\($0.kind)|\($0.name)", entry: $0) }
            return rows.isEmpty ? nil : (group, rows)
        }
    }

    private func entry(_ id: String?) -> ValueEntry? {
        sections.lazy.flatMap(\.rows).first { $0.id == id }?.entry
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 6) {
                    TextField("Search values", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .padding([.horizontal, .top], 10)
                    List(selection: $chosen) {
                        ForEach(sections, id: \.group) { section in
                            Section(section.group) {
                                ForEach(section.rows) { row in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(Self.written(row.entry)).font(.callout.monospaced()).lineLimit(1)
                                        Text(row.entry.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .tag(row.id)
                                }
                            }
                        }
                    }
                    .contextMenu(forSelectionType: String.self) { _ in
                        EmptyView()
                    } primaryAction: { ids in
                        if let entry = entry(ids.first) { handle.insert(entry.insertion) }
                    }
                }
                .frame(width: 280)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
            Divider()
            editor.padding(12)
        }
        .frame(width: 780, height: 600)
    }

    // MARK: - The value chosen

    @ViewBuilder
    private var detail: some View {
        if let entry = entry(chosen) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(entry.title).font(.title3.weight(.semibold))
                    Text(Self.written(entry)).font(.body.monospaced()).textSelection(.enabled)
                    Text(entry.help).fixedSize(horizontal: false, vertical: true)
                    here(entry)
                    if entry.example != entry.insertion {
                        labelled("Example") { Text(entry.example).font(.callout.monospaced()).textSelection(.enabled) }
                    }
                    if !entry.formats.isEmpty { formats(entry) }
                    if !entry.attributes.isEmpty { attributes(entry) }
                    Button("Insert \(entry.insertion)") { handle.insert(entry.insertion) }
                        .help("Put it in at the caret, below.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        } else {
            Text("Choose a value to see what it holds and what it comes to here. Double-click one to put it in.")
                .foregroundStyle(.secondary)
                .padding(16)
        }
    }

    /// What it comes to at this key, or why that can't be shown yet.
    @ViewBuilder
    private func here(_ entry: ValueEntry) -> some View {
        if entry.kind == .block {
            labelled("Here") { Text("Its reply, when the key is pressed.").foregroundStyle(.secondary) }
        } else if entry.holes > 0 {
            labelled("For example") { Text(entry.sample.isEmpty ? "—" : entry.sample).foregroundStyle(.secondary) }
        } else {
            let value = ValueCatalog.preview(of: entry.insertion, params: context.params).text
            labelled("Here") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.isEmpty ? "empty" : value)
                        .foregroundStyle(value.isEmpty ? .secondary : .primary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                    if entry.fetched || Template.environmentNames.contains(entry.name) {
                        Text("Found when the key is pressed.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func formats(_ entry: ValueEntry) -> some View {
        labelled("Formats") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entry.formats, id: \.pattern) { format in
                    let written = "{{\(entry.name):\(format.pattern)}}"
                    Button {
                        handle.insert(written)
                    } label: {
                        HStack {
                            Text(format.pattern).font(.callout.monospaced())
                            Text(ValueCatalog.preview(of: written, params: context.params).text).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.link)
                    .help("Put in \(written)")
                }
            }
        }
    }

    private func attributes(_ entry: ValueEntry) -> some View {
        labelled("Takes") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(entry.attributes, id: \.name) { attribute in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attribute.name + (attribute.required ? " — needed" : "")).font(.callout.monospaced())
                        Text(attribute.help).font(.caption).fixedSize(horizontal: false, vertical: true)
                        if !attribute.choices.isEmpty {
                            Text(attribute.choices.joined(separator: " · ")).font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        } else if !attribute.example.isEmpty {
                            Text(attribute.example).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func labelled(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 78, alignment: .trailing)
            content()
        }
    }

    /// How it's shown in the list: `{{leaf}}`, `{{quote …}}`, `{{#ai}}…{{/ai}}`.
    static func written(_ entry: ValueEntry) -> String {
        switch entry.kind {
        case .value: return "{{\(entry.name)}}"
        case .call: return "{{\(entry.name) …}}"
        case .block: return "{{#\(entry.name)}}…{{/\(entry.name)}}"
        }
    }

    // MARK: - The field's text

    private var editor: some View {
        let outcome = ValueCatalog.preview(of: text, params: context.params)
        // Missing here, though known: what the issues don't already say, and
        // not what each key below gives itself.
        let missing = outcome.missing.filter { name in
            guard let entry = context.catalog.entry(named: name) else { return false }
            return entry.group != "Set below"
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            ValueTextEditor(text: $text, context: context, kind: .field(multiline: multiline, lines: multiline ? 6 : 3),
                            font: .monospacedSystemFont(ofSize: 12, weight: .regular), issues: $issues, handle: handle,
                            onReturn: finish)
                .frame(minHeight: multiline ? 96 : 44, alignment: .top)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Comes to").font(.caption).foregroundStyle(.secondary)
                Text(outcome.text.isEmpty ? "empty" : outcome.text)
                    .foregroundStyle(outcome.text.isEmpty ? .secondary : .primary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if !missing.isEmpty {
                Label("Empty here: " + missing.map { "{{\($0)}}" }.joined(separator: ", "),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.octagon.fill"
                      : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(issue.severity == .error ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(multiline ? "Return finishes; ⌥Return starts a new line. {{ offers the values there are."
                     : "Return finishes. {{ offers the values there are.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done", action: finish)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func finish() {
        done(text)
        dismiss()
    }
}
