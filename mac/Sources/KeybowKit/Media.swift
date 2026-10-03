import AppKit
import ImageIO
import UniformTypeIdentifiers

/// An image or a PDF, carried through templates by reference.
///
/// Values are text, so an image on the clipboard can't go into {{clipboard}}
/// as itself. It's kept in `MediaStore`, and the value is a token that stands
/// for it — `⟦media:3F2A9C1B⟧`. What can take an image, a Claude block, swaps
/// the token for it; anywhere else, filling in a template puts a description
/// in its place: "[image 1568×980]".
public struct MediaItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case image, pdf }

    public let kind: Kind
    public let data: Data
    /// "image/png", "image/jpeg", "application/pdf".
    public let mediaType: String
    /// What it is, in words: "image 1568×980", "PDF, 12 pages".
    public let summary: String
    /// Why it can't be sent, when it can't: a PDF too long for Claude.
    public let problem: String?

    public init(kind: Kind, data: Data, mediaType: String, summary: String, problem: String? = nil) {
        self.kind = kind
        self.data = data
        self.mediaType = mediaType
        self.summary = summary
        self.problem = problem
    }
}

/// The media tokens stand for, in memory only: never written down or logged.
/// A press's media is needed only while its action runs, so just the newest
/// few are kept.
public final class MediaStore: @unchecked Sendable {
    public static let shared = MediaStore()
    static let kept = 8

    private let lock = NSLock()
    private var items: [String: MediaItem] = [:]
    private var order: [String] = []

    public init() {}

    /// Keeps an item, and says the token that stands for it.
    public func token(for item: MediaItem) -> String {
        let id = String(format: "%08X", UInt32.random(in: .min ... .max))
        lock.lock()
        defer { lock.unlock() }
        items[id] = item
        order.append(id)
        while order.count > Self.kept { items.removeValue(forKey: order.removeFirst()) }
        return MediaToken.make(id)
    }

    public func item(_ id: String) -> MediaItem? {
        lock.lock()
        defer { lock.unlock() }
        return items[id]
    }
}

/// Tokens in text: finding them, and swapping them for what they stand for.
public enum MediaToken {
    public enum Part: Equatable, Sendable {
        case text(String)
        case media(MediaItem)
        /// A token for something no longer kept.
        case missing
    }

    static func make(_ id: String) -> String { "⟦media:\(id)⟧" }

    private static let pattern = try! NSRegularExpression(pattern: "⟦media:([0-9A-F]{8})⟧")

    public static func contains(_ text: String) -> Bool { text.contains("⟦media:") }

    /// The text and the media in it, in order.
    public static func parts(of text: String, store: MediaStore = .shared) -> [Part] {
        guard contains(text) else { return [.text(text)] }
        let whole = text as NSString
        var parts: [Part] = []
        var start = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
            if match.range.location > start {
                parts.append(.text(whole.substring(with: NSRange(location: start, length: match.range.location - start))))
            }
            let id = whole.substring(with: match.range(at: 1))
            parts.append(store.item(id).map(Part.media) ?? .missing)
            start = match.range.location + match.range.length
        }
        if start < whole.length { parts.append(.text(whole.substring(from: start))) }
        return parts
    }

    /// Each token replaced by what it stands for, in words.
    public static func describe(_ text: String, store: MediaStore = .shared) -> String {
        guard contains(text) else { return text }
        return parts(of: text, store: store).map { part in
            switch part {
            case .text(let text): return text
            case .media(let item): return "[\(item.summary)]"
            case .missing: return "[an image no longer available]"
            }
        }.joined()
    }
}

/// Images and PDFs on the clipboard, for {{clipboard}}: copied files, or an
/// image copied as itself — a screenshot, from Preview, Copy Image in a
/// browser. Text wins when there's text worth having, since that's what
/// {{clipboard}} has always been.
public enum ClipboardMedia {
    /// The long edge Claude works best at; bigger images cost more and are
    /// scaled down there anyway.
    static let longestEdge = 1568
    /// An image's limit, less room for base64 to grow it by a third.
    static let largestImage = 3_750_000
    /// Claude's limits for a PDF.
    static let mostPages = 100
    static let largestPDF = 30_000_000
    static let mostFiles = 5

    /// Tokens for the clipboard's images or PDFs, a line each; nil when it
    /// has none, or has text instead.
    public static func tokens(from pasteboard: NSPasteboard, store: MediaStore = .shared) -> String? {
        // Files copied in the Finder: the images and PDFs among them. The
        // Finder adds each file's name as text, and its icon as an image,
        // so files are looked at first.
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            let items = files.prefix(mostFiles).compactMap(item(fromFile:))
            return items.isEmpty ? nil : items.map(store.token).joined(separator: "\n")
        }
        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty, !isJustALink(text) {
            return nil
        }
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier)]
        for type in imageTypes {
            if let data = pasteboard.data(forType: type), let item = image(data) { return store.token(for: item) }
        }
        if let data = pasteboard.data(forType: .pdf), let item = pdf(data) { return store.token(for: item) }
        return nil
    }

    /// "Copy Image" in a browser puts the image's address beside it.
    static func isJustALink(_ text: String) -> Bool {
        !text.contains(where: \.isWhitespace) && ["http://", "https://", "file://"].contains { text.lowercased().hasPrefix($0) }
    }

    static func item(fromFile url: URL) -> MediaItem? {
        guard let type = UTType(filenameExtension: url.pathExtension),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 100_000_000,
              let data = try? Data(contentsOf: url) else { return nil }
        if type.conforms(to: .pdf) { return pdf(data) }
        if type.conforms(to: .image) { return image(data) }
        return nil
    }

    /// An image as Claude takes it: no longer than `longestEdge` on its long
    /// side, as PNG — or JPEG, should a PNG be too big.
    public static func image(_ data: Data) -> MediaItem? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestEdge,
        ]
        guard let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        var encoded = encode(picture, as: .png)
        var mediaType = "image/png"
        if (encoded?.count ?? .max) > largestImage {
            encoded = encode(picture, as: .jpeg, quality: 0.85)
            mediaType = "image/jpeg"
        }
        guard let encoded else { return nil }
        return MediaItem(kind: .image, data: encoded, mediaType: mediaType,
                         summary: "image \(picture.width)×\(picture.height)")
    }

    /// A PDF as it is, with a problem when it's beyond Claude's limits.
    public static func pdf(_ data: Data) -> MediaItem? {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { return nil }
        let pages = document.numberOfPages
        var problem: String?
        if pages > mostPages {
            problem = "Claude takes PDFs of up to \(mostPages) pages, and this has \(pages)"
        } else if data.count > largestPDF {
            problem = "Claude takes PDFs of up to \(largestPDF / 1_000_000) MB, and this is \(data.count / 1_000_000) MB"
        }
        return MediaItem(kind: .pdf, data: data, mediaType: "application/pdf",
                         summary: "PDF, \(pages) page\(pages == 1 ? "" : "s")", problem: problem)
    }

    private static func encode(_ picture: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let properties = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, picture, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
