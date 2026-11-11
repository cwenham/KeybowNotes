import AppKit
@testable import KeybowKit
@testable import KeybowStreamDeck
import XCTest

final class DeckBackdropTests: XCTestCase {
    private let model = StreamDeckModel.all[0]

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        let colour = NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return (Int(colour.redComponent * 255), Int(colour.greenComponent * 255), Int(colour.blueComponent * 255))
    }

    /// A picture the screen's shape: red on the left half, blue on the right.
    private func halves() throws -> URL {
        let image = NSImage(size: NSSize(width: 480, height: 272), flipped: false) { rect in
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: rect.width / 2, height: rect.height).fill()
            NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).setFill()
            CGRect(x: rect.width / 2, y: 0, width: rect.width / 2, height: rect.height).fill()
            return true
        }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("halves-\(UUID()).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheSettingIsReadFromDefaults() {
        let set = DeckBackground(defaults: ["streamDeck": .object(["background": .string("Images/sky.jpg"),
                                                                   "tint": .string("40%")])])
        XCTAssertEqual(set?.image, "Images/sky.jpg")
        XCTAssertEqual(set?.tint ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(DeckBackground(defaults: ["streamDeck": .object(["background": .string("a.png")])])?.tint,
                       DeckBackground.defaultTint)
        XCTAssertNil(DeckBackground(defaults: ["streamDeck": .object(["background": .string("none")])]))
        XCTAssertNil(DeckBackground(defaults: [:]))
    }

    func testKeysSitOnTheScreenWithGapsBetween() {
        XCTAssertEqual(model.keyRect(0), CGRect(x: 11, y: 3, width: 72, height: 72))
        XCTAssertEqual(model.keyRect(1).minX - model.keyRect(0).maxX, 25)
        XCTAssertEqual(model.keyRect(14), CGRect(x: 399, y: 197, width: 72, height: 72))
        XCTAssertEqual(model.screenWidth - Int(model.keyRect(14).maxX), 9)
        XCTAssertEqual(model.screenHeight - Int(model.keyRect(14).maxY), 3)
    }

    func testEachKeyGetsThePartOfThePictureUnderIt() throws {
        let url = try halves()
        let backdrop = try XCTUnwrap(DeckBackdrop(DeckBackground(image: url.path), model: model, folder: nil))
        let left = try XCTUnwrap(backdrop.slice(0))
        let right = try XCTUnwrap(backdrop.slice(4))
        XCTAssertEqual(left.width, 72)
        XCTAssertGreaterThan(pixel(left, 36, 36).0, 200)
        XCTAssertGreaterThan(pixel(right, 36, 36).2, 200)
        // The middle column straddles the halves (205…277 across 240).
        let middle = try XCTUnwrap(backdrop.slice(2))
        XCTAssertGreaterThan(pixel(middle, 5, 36).0, 200)
        XCTAssertGreaterThan(pixel(middle, 66, 36).2, 200)
    }

    func testTheKeysColourTintsThePictureRatherThanCoveringIt() throws {
        let url = try halves()
        let backdrop = try XCTUnwrap(DeckBackdrop(DeckBackground(image: url.path, tint: 0.5), model: model,
                                                  folder: nil))
        let face = KeyFace(colour: KeyColour(red: 0, green: 255, blue: 0), caption: nil)
        let image = try XCTUnwrap(KeyRenderer(size: 72).image(face, behind: backdrop.slice(0), tint: 0.5))
        let (r, g, b) = pixel(image, 2, 2)
        XCTAssertGreaterThan(r, 90, "the red picture shows through")
        XCTAssertGreaterThan(g, 90, "the green colour lies over it")
        XCTAssertLessThan(b, 40)
        // A key with nothing on it shows the picture alone.
        let bare = try XCTUnwrap(KeyRenderer(size: 72).image(nil, behind: backdrop.slice(0), tint: 0.5))
        XCTAssertGreaterThan(pixel(bare, 36, 36).0, 200)
    }

    /// Draws a whole deck over a picture as it would look, into a PNG, for
    /// judging by eye: KEYBOW_BACKDROP_PREVIEW=<out.png>, with
    /// KEYBOW_DECK_PICTURE=<image> and KEYBOW_DECK_TINT=<0…1>.
    func testWritePreviewWhenAsked() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let out = environment["KEYBOW_BACKDROP_PREVIEW"], let picture = environment["KEYBOW_DECK_PICTURE"] else {
            throw XCTSkip("set KEYBOW_BACKDROP_PREVIEW and KEYBOW_DECK_PICTURE to draw a preview")
        }
        let tint = environment["KEYBOW_DECK_TINT"].flatMap(Double.init) ?? DeckBackground.defaultTint
        let backdrop = try XCTUnwrap(DeckBackdrop(DeckBackground(image: picture, tint: tint), model: model,
                                                  folder: nil))
        let blue = KeyColour(red: 0, green: 96, blue: 255), orange = KeyColour(red: 255, green: 140, blue: 0)
        let green = KeyColour(red: 30, green: 180, blue: 80), grey = KeyColour(red: 90, green: 90, blue: 90)
        let faces: [KeyFace?] = [
            KeyFace(colour: blue, icon: .symbol("briefcase.fill"), caption: "Work", emphasis: .chosen),
            KeyFace(colour: blue, icon: .symbol("person.2.fill"), caption: "Meeting"),
            KeyFace(colour: blue, icon: .symbol("calendar"), caption: "Plan"),
            nil,
            KeyFace(colour: grey, icon: .symbol("xmark"), caption: "Cancel"),
            KeyFace(colour: orange, icon: .symbol("music.note"), caption: "Music"),
            KeyFace(colour: orange, icon: .text("📞"), caption: "Alex"),
            KeyFace(colour: green, icon: .symbol("house.fill"), caption: "Home"),
            nil,
            KeyFace(colour: grey, icon: .symbol("chevron.left"), caption: "Back"),
            KeyFace(colour: green, icon: .symbol("book.fill"), caption: "Journal"),
            nil, nil,
            KeyFace(colour: green, icon: .symbol("timer"), caption: "Timer"),
            KeyFace(colour: KeyColour(red: 40, green: 40, blue: 40), caption: "CPU",
                    reading: LiveKeyReading(value: "23%", level: 0.23)),
        ]
        let renderer = KeyRenderer(size: 72)
        let width = model.screenWidth, height = model.screenHeight
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // The frame between the keys, as on the device.
        context.setFillColor(CGColor(gray: 0.06, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for key in 0..<model.keyCount {
            let image = try XCTUnwrap(renderer.image(faces[key], behind: backdrop.slice(key), tint: tint))
            var rect = model.keyRect(key)
            rect.origin.y = CGFloat(height) - rect.maxY  // CG draws from the bottom left.
            context.saveGState()
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 9, cornerHeight: 9, transform: nil))
            context.clip()
            context.draw(image, in: rect)
            context.restoreGState()
        }
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out))
    }
}
