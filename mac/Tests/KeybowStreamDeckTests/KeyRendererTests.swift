import AppKit
@testable import KeybowKit
@testable import KeybowStreamDeck
import XCTest

final class KeyRendererTests: XCTestCase {
    private let renderer = KeyRenderer(size: 72)

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let rep = NSBitmapImageRep(cgImage: image)
        let colour = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return (UInt8(colour.redComponent * 255), UInt8(colour.greenComponent * 255), UInt8(colour.blueComponent * 255))
    }

    func testAnEmptyKeyIsDark() throws {
        let image = try XCTUnwrap(renderer.image(nil))
        XCTAssertEqual(image.width, 72)
        let (r, g, b) = pixel(image, 36, 36)
        XCTAssertEqual([r, g, b], [0, 0, 0])
    }

    func testTheBackgroundIsTheKeysColour() throws {
        let face = KeyFace(colour: KeyColour(red: 0, green: 0, blue: 200), caption: "Hi")
        let image = try XCTUnwrap(renderer.image(face))
        let (r, g, b) = pixel(image, 2, 2)
        // Colour management shifts it a little when read back.
        XCTAssertLessThan(r, 20)
        XCTAssertLessThan(g, 60)
        XCTAssertGreaterThan(b, 180)
    }

    func testTheJPEGIsTurnedHalfATurn() throws {
        // A light top-left corner, as drawn upright, ends up bottom-right.
        let face = KeyFace(colour: .off, icon: .symbol("arrow.up.left"), caption: nil)
        let jpeg = try XCTUnwrap(renderer.jpeg(face))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "a JPEG")
        let image = try XCTUnwrap(NSBitmapImageRep(data: jpeg)?.cgImage)
        let upright = try XCTUnwrap(renderer.image(face))
        func brightness(_ image: CGImage, _ x: Int, _ y: Int) -> Int {
            let (r, g, b) = pixel(image, x, y)
            return Int(r) + Int(g) + Int(b)
        }
        // The arrow's tip: top left upright (y counts down in the bitmap).
        XCTAssertGreaterThan(brightness(upright, 14, 14), brightness(upright, 57, 57))
        XCTAssertGreaterThan(brightness(image, 57, 57), brightness(image, 14, 14))
    }

    func testInkIsReadableOnLightAndDark() {
        XCTAssertEqual(KeyRenderer.ink(on: KeyColour(red: 255, green: 255, blue: 255)), NSColor(white: 0.08, alpha: 1))
        XCTAssertEqual(KeyRenderer.ink(on: KeyColour(red: 0, green: 0, blue: 120)), .white)
    }

    /// Writes a picture of a whole deck to look at: KEYBOW_DECK_PREVIEW=/path/to.png.
    func testPreviewSheet() throws {
        guard let path = ProcessInfo.processInfo.environment["KEYBOW_DECK_PREVIEW"] else { return }
        let faces: [KeyFace?] = [
            KeyFace(node: "Work", colour: "0060ff", icon: .symbol("briefcase.fill"), emphasis: .chosen),
            KeyFace(node: "Meeting notes", colour: "0060ff", icon: .text("📝"), emphasis: .chosen),
            nil, nil,
            KeyFace(colour: FolderLayout.controlColour, icon: .symbol("xmark"), caption: "Cancel", emphasis: .control),
            KeyFace(node: "Standup", colour: "002266", icon: .symbol("person.3.fill")),
            KeyFace(node: "Call Mum", colour: "005522", icon: .text("📞")),
            KeyFace(node: "A long label for a key", colour: "553300"),
            KeyFace(node: nil, colour: "ffd000", icon: .text("Hi")),
            KeyFace(colour: FolderLayout.controlColour, icon: .symbol("chevron.backward"), caption: "Back",
                    emphasis: .control),
            KeyFace(node: "Timers", colour: "1a0d26", icon: .symbol("timer")),
            KeyFace(node: "Missing", colour: "330000", icon: .file("/nonexistent.png")),
            KeyFace(colour: KeyColour(red: 10, green: 10, blue: 10), caption: "CPU",
                    reading: LiveKeyReading(value: "23%", caption: "CPU", level: 0.23)),
            KeyFace(colour: KeyColour(red: 10, green: 10, blue: 10), caption: "CPU",
                    reading: LiveKeyReading(value: "91%", caption: "CPU", level: 0.91)),
            KeyFace(colour: FolderLayout.controlColour, icon: .symbol("chevron.down"), caption: "Bottom",
                    emphasis: .control),
        ]
        let key = 72, gap = 12
        let sheet = NSImage(size: NSSize(width: 5 * key + 6 * gap, height: 3 * key + 4 * gap))
        sheet.lockFocus()
        NSColor(white: 0.15, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (index, face) in faces.enumerated() {
            guard let image = renderer.image(face) else { continue }
            let column = index % 5, row = index / 5
            let rect = NSRect(x: gap + column * (key + gap), y: Int(sheet.size.height) - (gap + row * (key + gap)) - key,
                              width: key, height: key)
            NSImage(cgImage: image, size: rect.size).draw(in: rect)
        }
        sheet.unlockFocus()
        let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}

private extension KeyFace {
    init(node caption: String?, colour hex: String, icon: KeyIcon? = nil, emphasis: Emphasis = .normal) {
        self.init(colour: KeyColour(hex: hex)!, icon: icon, caption: caption, emphasis: emphasis)
    }
}
