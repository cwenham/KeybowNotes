import AppKit
import KeybowKit
import SwiftUI
import UniformTypeIdentifiers

/// Which template file an action uses: one in the templates folder, picked
/// from the list or typed; one anywhere, with Choose…; or one dragged in from
/// the Finder. A file in the templates folder is written as it's named there —
/// `standup.md` — and any other by its path.
struct TemplateFileField: View {
    let model: EditorModel
    var title = "Template file"
    let own: String?
    let placeholder: String
    var note = ""
    let help: String?
    /// Why it's out of use — text is set instead — shown under it, greyed.
    var unused: String?
    let set: (String?) -> Void

    @State private var files: [String] = []
    @State private var targeted = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        InspectorRow(title, help: help) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    NameComboBox(items: files, value: own ?? "",
                                 placeholder: placeholder.isEmpty ? "Choose, or drop a file here" : placeholder,
                                 toolTip: help) { name in
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        set(trimmed.isEmpty ? nil : trimmed)
                    }
                    .overlay {
                        if targeted {
                            RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2)
                        }
                    }
                    Button("Choose…", action: choose)
                        .controlSize(.small)
                        .help("Choose a file in the Finder — in the templates folder, or anywhere else.")
                }
                FieldFooter(unused: unused, note: note)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard isEnabled, let url = urls.first(where: \.isFileURL) else { return false }
            return use(url)
        } isTargeted: { over in
            targeted = over && isEnabled
        }
        .onAppear(perform: reload)
        // Back from the Finder, perhaps with a new file in the folder.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reload()
        }
    }

    private func reload() {
        files = model.templateFiles()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.text] + [UTType(filenameExtension: "md")].compactMap { $0 }
        let current = own ?? placeholder
        panel.directoryURL = current.isEmpty ? model.templatesDirectory
            : model.templateURL(current).deletingLastPathComponent()
        panel.message = "Choose a template file: its text is filled in and used when the key is pressed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = use(url)
    }

    /// Names the file as the action will: by its place in the templates
    /// folder, else by its path.
    private func use(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
            model.flash("A template is a file, not a folder")
            return false
        }
        set(Template.fileName(for: url, in: model.templatesDirectory))
        return true
    }
}

/// The template a node's action uses: edited in place, with its placeholders
/// highlighted, or opened in TextEdit. Templates are files beside the outline,
/// so saving here writes the file — shared by every node that uses it.
struct TemplateSection: View {
    let model: EditorModel
    /// The template's name as the action has it: `worklog.md`.
    let name: String
    /// Who sets it: "set here" or "from Meeting".
    let source: String
    /// Its {{values}}, as the node using it has them.
    let context: ValueContext

    @State private var text = ""
    @State private var saved = ""
    @State private var exists = false
    @State private var issues: [TemplateIssue] = []

    private var url: URL { model.templateURL(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Template: \(name)").font(.subheadline.weight(.semibold))
                Spacer()
                Text(source).font(.caption2).foregroundStyle(.secondary)
            }
            if exists {
                ValueTextEditor(text: $text, context: context, kind: .page,
                                font: .monospacedSystemFont(ofSize: 12, weight: .regular), issues: $issues)
                    .frame(minHeight: 140, maxHeight: 260)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                HStack {
                    Button("Save Template") { write() }
                        .disabled(text == saved)
                        .help("Write the file now. It's shared, so every node using it changes too.")
                    Button("Revert") { text = saved }
                        .disabled(text == saved)
                        .help("Throw away the changes since it was last saved.")
                    Spacer()
                    Button("Open in TextEdit") { openInTextEdit() }
                        .help("Edit the file in TextEdit instead, saving any changes here first.")
                }
                .controlSize(.small)
                ForEach(Array(issues.prefix(4).enumerated()), id: \.offset) { _, issue in
                    Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.octagon.fill"
                          : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(issue.severity == .error ? .red : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Shared by every node that uses \(name). {{ offers the values there are, each checked as it is here; "
                     + "they're filled in when the key is pressed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("There's no \(name) in the templates folder yet.")
                    .font(.callout).foregroundStyle(.orange)
                Button("Create It") { create() }
                    .controlSize(.small)
                    .help("Make the file in the templates folder, starting with a heading to fill in.")
            }
        }
        .onAppear(perform: load)
        .onChange(of: name) { _, _ in load() }
    }

    private func load() {
        let content = try? String(contentsOf: url, encoding: .utf8)
        exists = content != nil
        text = content ?? ""
        saved = text
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            saved = text
            exists = true
            model.flash("Saved \(name)")
        } catch {
            model.flash("Couldn't save \(name): \(error.localizedDescription)")
        }
    }

    private func create() {
        text = "# {{leaf}} — {{date}}\n\n"
        write()
    }

    private func openInTextEdit() {
        if text != saved { write() }
        let configuration = NSWorkspace.OpenConfiguration()
        if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: configuration)
        } else {
            NSWorkspace.shared.open(url)
        }
        model.flash("Opened \(name) in TextEdit — come back and reselect the node to see changes")
    }
}
