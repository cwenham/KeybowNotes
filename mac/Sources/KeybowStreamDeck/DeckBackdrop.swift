import AppKit
import KeybowKit

/// A background picture laid across a Stream Deck's screen, cut into the
/// parts that show through each key.
///
/// The keys are windows onto one screen, with the frame between them, so the
/// picture fills the whole screen — cropped to its shape, not stretched — and
/// each key takes the square under it. What's under the frame is never seen,
/// so the picture lines up across the gaps as if behind glass.
public struct DeckBackdrop {
    public let background: DeckBackground
    public let model: StreamDeckModel
    /// The picture at the screen's size, upright.
    public let screen: CGImage
    private let slices: [CGImage]

    public init?(_ background: DeckBackground, model: StreamDeckModel, folder: URL?) {
        guard let url = background.fileURL(relativeTo: folder), let picture = ImageCache.shared.image(at: url),
              let screen = Self.fill(picture, width: model.screenWidth, height: model.screenHeight) else { return nil }
        self.background = background
        self.model = model
        self.screen = screen
        slices = (0..<model.keyCount).map { key in
            // CGImage cropping counts from the top left, as keyRect does.
            screen.cropping(to: model.keyRect(key)) ?? screen
        }
    }

    /// The same, kept from the last time it was made with the same picture
    /// file, unchanged on disk: for drawing it often, as the editor does.
    /// Only the tint may differ.
    public static func cached(_ background: DeckBackground, model: StreamDeckModel, folder: URL?) -> DeckBackdrop? {
        guard let url = background.fileURL(relativeTo: folder) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = CacheKey(path: url.standardizedFileURL.path, modified: modified, model: model)
        cacheLock.lock()
        let hit = cache[key]
        cacheLock.unlock()
        if let hit { return DeckBackdrop(hit, tint: background.tint) }
        guard let made = DeckBackdrop(background, model: model, folder: folder) else { return nil }
        cacheLock.lock()
        if cache.count > 8 { cache.removeAll() }
        cache[key] = made
        cacheLock.unlock()
        return made
    }

    private struct CacheKey: Hashable {
        let path: String
        let modified: Date?
        let model: StreamDeckModel
    }

    nonisolated(unsafe) private static var cache: [CacheKey: DeckBackdrop] = [:]
    private static let cacheLock = NSLock()

    private init(_ other: DeckBackdrop, tint: Double) {
        background = DeckBackground(image: other.background.image, tint: tint)
        model = other.model
        screen = other.screen
        slices = other.slices
    }

    /// The part of the picture under a key, upright.
    public func slice(_ key: Int) -> CGImage? {
        key >= 0 && key < slices.count ? slices[key] : nil
    }

    public var tint: Double { background.tint }

    /// The picture scaled to cover width × height, keeping its shape, the
    /// overflow cut evenly from both sides.
    static func fill(_ picture: NSImage, width: Int, height: Int) -> CGImage? {
        let natural = picture.size
        guard natural.width > 0, natural.height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = max(CGFloat(width) / natural.width, CGFloat(height) / natural.height)
        let drawn = CGSize(width: natural.width * scale, height: natural.height * scale)
        let rect = CGRect(x: (CGFloat(width) - drawn.width) / 2, y: (CGFloat(height) - drawn.height) / 2,
                          width: drawn.width, height: drawn.height)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        picture.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
