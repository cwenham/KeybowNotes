import AppKit
import KeybowKit
import UniformTypeIdentifiers

/// Draws a key's face — its colour, icon and caption — as a square picture.
public struct KeyRenderer {
    public let size: Int
    /// Where image files named without a full path are: the tree file's folder.
    public var iconFolder: URL?

    public init(size: Int, iconFolder: URL? = nil) {
        self.size = size
        self.iconFolder = iconFolder
    }

    /// The face, upright. Nil face: a dark key.
    public func image(_ face: KeyFace?) -> CGImage? {
        let side = CGFloat(size)
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let face else { return context.makeImage() }

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        let background = NSColor(srgbRed: CGFloat(face.colour.red) / 255, green: CGFloat(face.colour.green) / 255,
                                 blue: CGFloat(face.colour.blue) / 255, alpha: 1)
        background.setFill()
        CGRect(x: 0, y: 0, width: side, height: side).fill()
        if face.emphasis == .chosen {
            // On the path: a white edge, as well as the full colour.
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let edge = NSBezierPath(rect: CGRect(x: 1.5, y: 1.5, width: side - 3, height: side - 3))
            edge.lineWidth = 3
            edge.stroke()
        }
        let ink = Self.ink(on: face.colour)

        let margin = side * 0.07
        let caption = face.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCaption = !(caption ?? "").isEmpty
        let iconBox: CGRect
        if hasCaption && face.icon != nil {
            // Icon above, a line of caption below.
            iconBox = CGRect(x: margin, y: side * 0.30, width: side - 2 * margin, height: side * 0.62)
        } else {
            iconBox = CGRect(x: margin, y: margin, width: side - 2 * margin, height: side - 2 * margin)
        }

        if let icon = face.icon {
            draw(icon, in: iconBox, ink: ink)
        }
        if let caption, hasCaption {
            if face.icon != nil {
                drawText(caption, in: CGRect(x: 2, y: side * 0.04, width: side - 4, height: side * 0.26), ink: ink,
                         largest: side * 0.17, smallest: side * 0.12, lines: 1)
            } else {
                drawText(caption, in: iconBox, ink: ink, largest: side * 0.24, smallest: side * 0.13, lines: 3)
            }
        }
        return context.makeImage()
    }

    /// The face as the Stream Deck wants it: JPEG, turned half a turn.
    public func jpeg(_ face: KeyFace?) -> Data? {
        guard let upright = image(face),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let side = CGFloat(size)
        context.translateBy(x: side, y: side)
        context.rotate(by: .pi)
        context.draw(upright, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let rotated = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, rotated,
                                   [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// White on dark colours, near-black on light ones.
    static func ink(on colour: KeyColour) -> NSColor {
        func linear(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(colour.red) + 0.7152 * linear(colour.green) + 0.0722 * linear(colour.blue)
        return luminance > 0.4 ? NSColor(white: 0.08, alpha: 1) : .white
    }

    private func draw(_ icon: KeyIcon, in box: CGRect, ink: NSColor) {
        switch icon {
        case .symbol(let name):
            let configuration = NSImage.SymbolConfiguration(pointSize: box.height * 0.72, weight: .medium)
                .applying(.init(paletteColors: [ink]))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else {
                drawText("?", in: box, ink: ink, largest: box.height * 0.6, smallest: 8, lines: 1)
                return
            }
            drawFitted(image, in: box)
        case .file:
            guard let url = icon.fileURL(relativeTo: iconFolder), let image = ImageCache.shared.image(at: url) else {
                drawText("?", in: box, ink: ink, largest: box.height * 0.6, smallest: 8, lines: 1)
                return
            }
            drawFitted(image, in: box)
        case .text(let text):
            drawText(text, in: box, ink: ink, largest: box.height * 0.8, smallest: box.height * 0.2, lines: 2)
        }
    }

    /// Scaled to fit, keeping its shape, centred.
    private func drawFitted(_ image: NSImage, in box: CGRect) {
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return }
        let scale = min(box.width / natural.width, box.height / natural.height)
        let drawn = CGSize(width: natural.width * scale, height: natural.height * scale)
        let rect = CGRect(x: box.midX - drawn.width / 2, y: box.midY - drawn.height / 2,
                          width: drawn.width, height: drawn.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Centred in the box: the largest size from `largest` down that fits in
    /// `lines` lines, else the smallest, cut short with an ellipsis.
    private func drawText(_ text: String, in box: CGRect, ink: NSColor, largest: CGFloat, smallest: CGFloat,
                          lines: Int) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        var size = largest
        func attributes(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: ink,
             .paragraphStyle: paragraph]
        }
        func measure(_ size: CGFloat) -> CGRect {
            NSAttributedString(string: text, attributes: attributes(size))
                .boundingRect(with: CGSize(width: box.width - 2, height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        // Fits when no word is broken across lines and it isn't too tall.
        func fits(_ size: CGFloat) -> Bool {
            let font = NSFont.systemFont(ofSize: size, weight: .semibold)
            let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
            let longestWord = text.split(whereSeparator: \.isWhitespace).map {
                NSAttributedString(string: String($0), attributes: attributes(size)).size().width
            }.max() ?? 0
            let bounds = measure(size)
            return longestWord <= box.width - 2 && ceil(bounds.height) + 2 <= box.height
                && bounds.height <= lineHeight * CGFloat(lines) + 0.5
        }
        while size > smallest, !fits(size) { size -= 0.5 }
        size = max(size, smallest)
        if !fits(size) { paragraph.lineBreakMode = .byTruncatingTail }
        let bounds = measure(size)
        // Rounded up, or the last line can be dropped as not quite fitting.
        let height = min(ceil(bounds.height) + 2, box.height)
        let rect = CGRect(x: box.minX, y: box.midY - height / 2, width: box.width, height: height)
        NSAttributedString(string: text, attributes: attributes(size)).draw(in: rect)
    }
}

/// Image files, read once each until they change on disk.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let lock = NSLock()
    private var images: [URL: (modified: Date?, image: NSImage)] = [:]

    func image(at url: URL) -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        lock.lock()
        defer { lock.unlock() }
        if let cached = images[url], cached.modified == modified { return cached.image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images[url] = (modified, image)
        return image
    }
}
