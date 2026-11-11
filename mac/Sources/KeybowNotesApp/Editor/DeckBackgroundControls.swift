import AppKit
import ImageIO
import KeybowKit
import KeybowStreamDeck
import SwiftUI
import UniformTypeIdentifiers

/// Under the Stream Deck drawing: the picture across its keys, and how
/// strongly the keys' colours cover it — `streamDeck.background` and
/// `streamDeck.tint` in `# defaults`, shared by every Stream Deck.
struct DeckBackgroundControls: View {
    let model: EditorModel
    /// The tint while the slider is being dragged, for the drawing to follow
    /// before it's written to the tree.
    @Binding var draggingTint: Double?

    @State private var choosing = false

    static let backgroundKey = "streamDeck.background"
    static let tintKey = "streamDeck.tint"

    private var folder: URL { model.outlineURL.deletingLastPathComponent() }

    private var written: String? {
        guard let value = model.document.defaultValue(Self.backgroundKey)?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty, value.lowercased() != "none" else { return nil }
        return value
    }

    private var tint: Double { model.keypadConfig?.deckBackground?.tint ?? DeckBackground.defaultTint }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Background").foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button { choosing = true } label: {
                        BackgroundSwatch(url: written.flatMap { KeyIcon.file($0).fileURL(relativeTo: folder) })
                            .frame(width: 48, height: 27)
                    }
                    .buttonStyle(.plain)
                    .help("Choose the picture across the Stream Deck's keys")
                    .popover(isPresented: $choosing, arrowEdge: .bottom) {
                        BackgroundChooser(current: written.flatMap { KeyIcon.file($0).fileURL(relativeTo: folder) },
                                          choose: { set($0) }, chooseFile: { chooseFile() })
                    }
                    Text(name).lineLimit(1).truncationMode(.middle)
                        .help(written ?? "No picture: each key is its own colour")
                    Spacer(minLength: 0)
                    if written != nil {
                        Button("None") { set(nil) }.controlSize(.small)
                            .help("Take the picture away: each key is its own colour again")
                    }
                }
            }
            GridRow {
                Text("Key opacity").foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { draggingTint ?? tint }, set: { draggingTint = $0 }), in: 0...1,
                           onEditingChanged: { editing in
                               if !editing, let value = draggingTint {
                                   setTint(value)
                                   draggingTint = nil
                               }
                           })
                    .controlSize(.small)
                    Text("\(Int(((draggingTint ?? tint) * 100).rounded()))%")
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }
                .disabled(written == nil)
                .help("How strongly each key's colour covers the picture: 0% shows the picture alone, "
                      + "100% the colour alone.")
            }
        }
        .font(.callout)
    }

    private var name: String {
        guard let written else { return "None" }
        return ((written as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private func set(_ url: URL?) {
        choosing = false
        let value: String?
        if let url {
            // Under the tree's folder, by its path there; the Mac's own
            // pictures where they are; anything else copied beside the tree.
            if url.path.hasPrefix("/System/") || url.path.hasPrefix("/Library/") {
                value = url.path
            } else {
                do {
                    value = try IconFiles.place(url, besideTreeIn: folder, subfolder: "Backgrounds")
                } catch {
                    model.flash("Couldn't copy the picture beside the tree: \(error.localizedDescription)")
                    return
                }
            }
        } else {
            value = nil
        }
        model.edit(value == nil ? "Remove Background" : "Set Background") { document in
            document.setDefault(Self.backgroundKey, value)
            if value == nil { document.setDefault(Self.tintKey, nil) }
        }
    }

    private func setTint(_ value: Double) {
        let rounded = (value * 100).rounded() / 100
        model.edit("Change Key Opacity") { document in
            document.setDefault(Self.tintKey, rounded == DeckBackground.defaultTint ? nil : String(format: "%g", rounded))
        }
    }

    private func chooseFile() {
        choosing = false
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a picture to lay across the Stream Deck's keys"
        panel.prompt = "Use Picture"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        set(url)
    }
}

/// The Mac's own desktop pictures, the one in use marked, and a way to pick
/// any file.
private struct BackgroundChooser: View {
    let current: URL?
    let choose: (URL?) -> Void
    let chooseFile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mac Desktop Pictures").font(.subheadline.weight(.semibold))
            let pictures = DesktopPictures.installed
            if pictures.isEmpty {
                Text("None found on this Mac.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(112), spacing: 8), count: 3), spacing: 8) {
                        ForEach(pictures, id: \.self) { url in
                            Button { choose(url) } label: {
                                VStack(spacing: 3) {
                                    BackgroundSwatch(url: url)
                                        .frame(width: 112, height: 63)
                                        .overlay(RoundedRectangle(cornerRadius: 5)
                                            .strokeBorder(url.standardizedFileURL == current?.standardizedFileURL
                                                          ? Color.accentColor : .clear, lineWidth: 3))
                                    Text(url.deletingPathExtension().lastPathComponent)
                                        .font(.caption).lineLimit(1).truncationMode(.tail)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(url.deletingPathExtension().lastPathComponent)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            Divider()
            HStack {
                Button("Choose File…", action: chooseFile)
                Spacer()
                Button("None") { choose(nil) }.disabled(current == nil)
            }
        }
        .padding(12)
        .frame(width: 368)
    }
}

/// A small picture of a background, or an empty well for none.
private struct BackgroundSwatch: View {
    let url: URL?

    var body: some View {
        // The picture as an overlay, so it fills the frame it's given
        // rather than setting its size.
        Color.black.opacity(0.85)
            .overlay {
                if let url, let image = DesktopPictures.thumbnail(url) {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
        .contentShape(Rectangle())
    }
}

enum DesktopPictures {
    /// The still pictures the Mac has installed, with those added for every
    /// user: not the moving ones, nor those still to be downloaded.
    static let installed: [URL] = {
        let folders = ["/System/Library/Desktop Pictures", "/Library/Desktop Pictures"].map(URL.init(fileURLWithPath:))
        let types: Set<String> = ["heic", "jpg", "jpeg", "png", "tif", "tiff"]
        return folders.flatMap { folder -> [URL] in
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                      options: .skipsHiddenFiles)) ?? []
            return items.filter { types.contains($0.pathExtension.lowercased()) }
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }()

    nonisolated(unsafe) private static var thumbnails: [URL: CGImage] = [:]

    /// A small copy, made once, without decoding the whole picture.
    @MainActor
    static func thumbnail(_ url: URL) -> CGImage? {
        if let made = thumbnails[url] { return made }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 320,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        thumbnails[url] = image
        return image
    }
}
