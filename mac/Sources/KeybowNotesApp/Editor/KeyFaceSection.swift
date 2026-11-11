import AppKit
import KeybowKit
import KeybowStreamDeck
import SwiftUI
import UniformTypeIdentifiers

/// The inspector's rows for how a key looks on a keypad that draws on its keys
/// (the Stream Deck): its icon — a symbol, emoji or text, or an image file —
/// and the text under it.
struct KeyFaceSection: View {
    let model: EditorModel
    let id: UUID
    let node: OutlineNode
    /// The colour in force, own or inherited.
    let colour: KeyColour?

    @State private var picking = false

    private func own(_ key: String) -> String? {
        node.annotations.first { $0.key == key }.flatMap {
            if case .pair(_, let value) = $0 { return value }
            return nil
        }
    }

    private var icon: KeyIcon? { own("icon").flatMap(KeyIcon.init) }
    private var caption: String? { own("caption") }
    private var hidesText: Bool { caption?.trimmingCharacters(in: .whitespaces).lowercased() == "none" }

    private var treeFolder: URL { model.outlineURL.deletingLastPathComponent() }

    /// The key as a Stream Deck shows it, in its colour as it's on offer.
    private var face: KeyFace {
        let shown = hidesText ? nil : (caption.map { $0.isEmpty ? node.label : $0 } ?? node.label)
        return KeyFace(colour: colour ?? KeyColour(red: 0x60, green: 0x60, blue: 0x60), icon: icon, caption: shown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorRow("Key icon", help: FieldHelp.icon) {
                HStack(alignment: .center, spacing: 10) {
                    Button { picking = true } label: {
                        KeyPreview(face: face, folder: treeFolder)
                    }
                    .buttonStyle(.plain)
                    .help("Choose an icon: a symbol, emoji or text, or an image file.")
                    .popover(isPresented: $picking, arrowEdge: .trailing) {
                        IconPicker(current: icon, folder: treeFolder) { chosen in
                            setIcon(chosen?.written)
                            picking = false
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Button(icon == nil ? "Choose Icon…" : "Change…") { picking = true }
                            .controlSize(.small)
                        if let icon {
                            Text(icon.written)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(icon.written)
                            Button("Remove Icon") { setIcon(nil) }
                                .controlSize(.small)
                        }
                    }
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            DraftField(title: "Key text", value: hidesText ? "" : (caption ?? ""),
                       placeholder: hidesText ? "no text" : node.label, help: FieldHelp.caption) { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                setCaption(trimmed.isEmpty || trimmed == node.label ? nil : trimmed)
            }
            InspectorRow("", help: nil) {
                Toggle("Show text on the key", isOn: Binding(
                    get: { !hidesText },
                    set: { show in setCaption(show ? nil : "none") }
                ))
                .controlSize(.small)
            }
        }
    }

    private func setIcon(_ written: String?) {
        model.edit(written == nil ? "Remove Icon" : "Set Icon") { try $0.setPair(id, key: "icon", value: written) }
    }

    private func setCaption(_ text: String?) {
        guard text != caption else { return }
        model.edit("Set Key Text") { try $0.setPair(id, key: "caption", value: text) }
    }
}

/// A key face, drawn as the Stream Deck draws it.
struct KeyPreview: View {
    let face: KeyFace
    let folder: URL?
    var side: CGFloat = 56

    var body: some View {
        let renderer = KeyRenderer(size: 144, iconFolder: folder)
        Group {
            if let image = renderer.image(face) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
            } else {
                Color.black
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.14))
        .overlay(RoundedRectangle(cornerRadius: side * 0.14).strokeBorder(Color.secondary.opacity(0.4), lineWidth: 0.5))
    }
}

/// Picks an icon: one of Apple's symbols, emoji or text, or an image file.
struct IconPicker: View {
    let current: KeyIcon?
    let folder: URL
    /// Nil removes the icon.
    let choose: (KeyIcon?) -> Void

    private enum Kind: String, CaseIterable, Identifiable {
        case symbol = "Symbols"
        case text = "Emoji & Text"
        case file = "Image File"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .symbol
    @State private var search = ""
    @State private var text = ""
    @State private var fileError: String?
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch kind {
            case .symbol: symbols
            case .text: emojiAndText
            case .file: imageFile
            }
        }
        .padding(12)
        .frame(width: 380)
        .onAppear {
            switch current {
            case .text(let written)?: kind = .text; text = written
            case .file?: kind = .file
            default: kind = .symbol
            }
        }
    }

    // MARK: - Symbols

    private var symbols: some View {
        let names = SymbolNames.matching(search)
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Search symbols: star, phone, calendar…", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 4), count: 8), spacing: 4) {
                    ForEach(names, id: \.self) { name in
                        let chosen = current == .symbol(name)
                        Button { choose(.symbol(name)) } label: {
                            Image(systemName: name)
                                .font(.system(size: 18))
                                .frame(width: 40, height: 36)
                                .background(chosen ? Color.accentColor.opacity(0.25) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
            }
            .frame(height: 260)
            Text(search.isEmpty ? "Everyday symbols first. Type to search all of them."
                 : names.count == SymbolNames.limit ? "The first \(SymbolNames.limit) matches; type to narrow them."
                 : "\(names.count) symbols. Rest the pointer on one for its name.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Emoji and text

    private var emojiAndText: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("An emoji, or a few letters, drawn large on the key.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                TextField("📞  or  Hi", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.title2)
                    .focused($textFocused)
                    .onSubmit(useText)
                Button("Emoji…") {
                    textFocused = true
                    DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
                }
                .help("Opens the Emoji & Symbols viewer; what you pick goes in the field.")
            }
            HStack {
                Spacer()
                Button("Use") { useText() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { textFocused = true }
    }

    private func useText() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Always as text, even if it looks like a file name.
        choose(KeyIcon(trimmed).flatMap { if case .text = $0 { return $0 } else { return nil } } ?? .text(trimmed))
    }

    // MARK: - Image file

    private var imageFile: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A PNG, JPEG, HEIC, SVG or PDF, scaled to fit the key. It's copied into the Icons folder beside "
                 + "your tree, so the tree keeps working if the original moves.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .file(let path)? = current {
                Text("Now: \(path)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let fileError {
                Text(fileError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Show Icons Folder") {
                    let icons = folder.appendingPathComponent("Icons")
                    NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: icons.path)
                                                                    ? icons : folder])
                }
                Spacer()
                Button("Choose…") { pickFile() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .gif, .tiff, .bmp, .svg, .pdf, .icns, .webP]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture for the key"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            choose(.file(try IconFiles.place(url, besideTreeIn: folder)))
        } catch {
            fileError = "Couldn't copy it: \(error.localizedDescription)"
        }
    }
}

enum IconFiles {
    /// The path to write in the outline: the file's own, under the tree's
    /// folder; else a copy in its Icons folder, renamed if one of that name
    /// is already there and different.
    static func place(_ url: URL, besideTreeIn folder: URL, subfolder: String = "Icons") throws -> String {
        let folderPath = folder.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        if path.hasPrefix(folderPath) { return String(path.dropFirst(folderPath.count)) }

        let icons = folder.appendingPathComponent(subfolder)
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var destination = icons.appendingPathComponent(url.lastPathComponent)
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            if FileManager.default.contentsEqual(atPath: destination.path, andPath: url.path) {
                return subfolder + "/" + destination.lastPathComponent
            }
            destination = icons.appendingPathComponent("\(base) \(number).\(ext)")
            number += 1
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return subfolder + "/" + destination.lastPathComponent
    }
}

/// SF Symbols' names, from the system's own list, to search.
enum SymbolNames {
    static let limit = 400

    /// macOS keeps the names, with the release each arrived in, in CoreGlyphs.
    static let all: [String] = {
        let path = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
        if let plist = NSDictionary(contentsOfFile: path), let symbols = plist["symbols"] as? [String: Any] {
            // Without the versions for other scripts: `character.ar`, `arrow.left.rtl`.
            return symbols.keys.filter { name in
                !name.split(separator: ".").contains { scripts.contains(String($0)) }
            }.sorted()
        }
        return common
    }()

    static let scripts: Set<String> = ["ar", "he", "hi", "ja", "ko", "th", "zh", "rtl", "bn", "gu", "kn", "ml", "mr",
                                       "pa", "ta", "te", "km", "my", "sat", "mni", "si", "el", "ru", "or", "traditional"]

    /// Everyday ones, shown first before anything's typed — and the whole
    /// list, should the system's ever move.
    static let common = [
        "star.fill", "heart.fill", "bolt.fill", "bell.fill", "bookmark.fill", "briefcase.fill", "calendar",
        "calendar.badge.plus", "checklist", "checkmark.circle.fill", "clock.fill", "timer", "alarm.fill",
        "stopwatch.fill", "hourglass", "note.text", "doc.text.fill", "folder.fill", "tray.fill", "archivebox.fill",
        "paperclip", "link", "pencil", "highlighter", "square.and.pencil", "list.bullet", "text.quote",
        "envelope.fill", "paperplane.fill", "message.fill", "bubble.left.and.bubble.right.fill", "phone.fill",
        "video.fill", "person.fill", "person.2.fill", "person.3.fill", "house.fill", "building.2.fill",
        "cart.fill", "bag.fill", "creditcard.fill", "gift.fill", "lightbulb.fill", "brain.head.profile",
        "sparkles", "wand.and.stars", "magnifyingglass", "globe", "map.fill", "location.fill", "car.fill",
        "airplane", "tram.fill", "figure.walk", "dumbbell.fill", "fork.knife", "cup.and.saucer.fill",
        "music.note", "play.fill", "pause.fill", "stop.fill", "forward.fill", "backward.fill",
        "speaker.wave.2.fill", "speaker.slash.fill", "mic.fill", "mic.slash.fill", "headphones", "camera.fill",
        "photo.fill", "film.fill", "tv.fill", "display", "macwindow", "rectangle.split.2x1",
        "rectangle.lefthalf.filled", "rectangle.righthalf.filled", "arrow.up.left.and.arrow.down.right",
        "keyboard", "command", "gearshape.fill", "wrench.and.screwdriver.fill", "hammer.fill", "terminal.fill",
        "chevron.left.forwardslash.chevron.right", "cpu", "wifi", "antenna.radiowaves.left.and.right",
        "lock.fill", "lock.open.fill", "key.fill", "sun.max.fill", "moon.fill", "cloud.fill", "cloud.rain.fill",
        "snowflake", "thermometer.medium", "drop.fill", "flame.fill", "leaf.fill", "pawprint.fill",
        "lightswitch.on", "powerplug.fill", "fan.fill", "lamp.desk.fill", "bed.double.fill", "flag.fill",
        "tag.fill", "pin.fill", "trash.fill", "xmark", "checkmark", "plus", "minus", "arrow.clockwise",
        "arrow.uturn.backward", "questionmark.circle.fill", "exclamationmark.triangle.fill", "info.circle.fill",
    ]

    /// Names containing every word typed, shortest first, up to the limit.
    static func matching(_ search: String) -> [String] {
        let words = search.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        guard !words.isEmpty else {
            let known = Set(all)
            let first = common.filter { known.contains($0) }
            let shown = Set(first)
            return Array((first + all.filter { !shown.contains($0) }).prefix(limit))
        }
        let found = all.filter { name in words.allSatisfy { name.contains($0) } }
        return Array(found.sorted { ($0.count, $0) < ($1.count, $1) }.prefix(limit))
    }
}
