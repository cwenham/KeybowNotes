import AppKit
import KeybowKit
import SwiftUI

/// The template a node's action uses: edited in place, with its placeholders
/// highlighted, or opened in TextEdit. Templates are files beside the outline,
/// so saving here writes the file — shared by every node that uses it.
struct TemplateSection: View {
    let model: EditorModel
    /// The template's name as the action has it: `worklog.md`.
    let name: String
    /// Who sets it: "set here" or "from Meeting".
    let source: String

    @State private var text = ""
    @State private var saved = ""
    @State private var exists = false

    private var url: URL {
        name.hasPrefix("/") || name.hasPrefix("~")
            ? URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
            : model.templatesDirectory.appendingPathComponent(name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Template: \(name)").font(.subheadline.weight(.semibold))
                Spacer()
                Text(source).font(.caption2).foregroundStyle(.secondary)
            }
            if exists {
                TemplateTextView(text: $text)
                    .frame(minHeight: 140, maxHeight: 260)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                HStack {
                    Button("Save Template") { write() }
                        .disabled(text == saved)
                    Button("Revert") { text = saved }
                        .disabled(text == saved)
                    Spacer()
                    Button("Open in TextEdit") { openInTextEdit() }
                }
                .controlSize(.small)
                Text("Shared by every node that uses \(name). {{placeholders}} are filled in when the key is pressed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("There's no \(name) in the templates folder yet.")
                    .font(.callout).foregroundStyle(.orange)
                Button("Create It") { create() }
                    .controlSize(.small)
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

/// A plain-text editor that highlights `{{placeholders}}` and `#` headings.
struct TemplateTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.font = Coordinator.font
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.string = text
        context.coordinator.highlight(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        context.coordinator.highlight(view)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        private static let placeholder = try! NSRegularExpression(pattern: #"\{\{[^{}]*\}\}"#)
        private static let heading = try! NSRegularExpression(pattern: #"(?m)^#{1,3} .*$"#)

        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
            highlight(view)
        }

        func highlight(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let whole = NSRange(location: 0, length: storage.length)
            let selected = view.selectedRanges
            storage.beginEditing()
            storage.setAttributes([.font: Self.font, .foregroundColor: NSColor.labelColor], range: whole)
            for match in Self.heading.matches(in: storage.string, range: whole) {
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), range: match.range)
            }
            for match in Self.placeholder.matches(in: storage.string, range: whole) {
                storage.addAttributes([.foregroundColor: NSColor.systemPurple,
                                       .backgroundColor: NSColor.systemPurple.withAlphaComponent(0.12)], range: match.range)
            }
            storage.endEditing()
            view.selectedRanges = selected
        }
    }
}
