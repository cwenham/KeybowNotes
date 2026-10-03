import AppKit
@testable import KeybowKit
import XCTest

/// Images and PDFs from the clipboard, carried by token, described wherever
/// they can't go as themselves; and text copied formatted.
final class MediaTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var folder: URL!

    override func setUpWithError() throws {
        // A pasteboard of its own: the clipboard is left alone.
        pasteboard = NSPasteboard(name: NSPasteboard.Name("keybow-tests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: folder)
    }

    /// A PNG of a plain picture, this size.
    private func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    }

    private func pdf(pages: Int) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    // MARK: Tokens

    func testTokensStandForMediaAndAreDescribedElsewhere() {
        let store = MediaStore()
        let item = MediaItem(kind: .image, data: Data([1, 2, 3]), mediaType: "image/png", summary: "image 4×3")
        let token = store.token(for: item)
        XCTAssertEqual(MediaToken.parts(of: "Look: \(token) here", store: store),
                       [.text("Look: "), .media(item), .text(" here")])
        XCTAssertEqual(MediaToken.describe("Look: \(token)", store: store), "Look: [image 4×3]")
        XCTAssertEqual(MediaToken.parts(of: "⟦media:00000000⟧", store: store), [.missing])
        XCTAssertEqual(MediaToken.parts(of: "no media", store: store), [.text("no media")])
    }

    func testOnlyABlockKeepsTheMediaItself() throws {
        let item = MediaItem(kind: .image, data: Data([1]), mediaType: "image/png", summary: "image 4×3")
        let token = MediaStore.shared.token(for: item)
        let template = "Look: {{clipboard}} — {{#ai}}Describe {{clipboard}}{{/ai}}"
        let first = Template.expand(template, params: ["clipboard": token])
        let call = try XCTUnwrap(first.unresolved.first)
        XCTAssertTrue(call.body.contains(token), "Claude gets the image")
        let done = Template.expand(template, params: ["clipboard": token], blocks: [call: "A blue square."])
        XCTAssertEqual(done.text, "Look: [image 4×3] — A blue square.", "anywhere else, a description")
    }

    // MARK: The clipboard

    func testAnImageCopiedAsItselfIsScaledToSize() throws {
        pasteboard.clearContents()
        pasteboard.setData(png(width: 3000, height: 2000), forType: .png)
        let store = MediaStore()
        let token = try XCTUnwrap(ClipboardMedia.tokens(from: pasteboard, store: store))
        guard case .media(let item) = MediaToken.parts(of: token, store: store).first else { return XCTFail() }
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.mediaType, "image/png")
        XCTAssertEqual(item.summary, "image 1568×1045", "the long edge Claude works best at")
        XCTAssertNil(item.problem)
    }

    func testTextWinsUnlessItsJustTheImagesAddress() {
        pasteboard.clearContents()
        pasteboard.setString("Some words", forType: .string)
        pasteboard.setData(png(width: 10, height: 10), forType: .png)
        XCTAssertNil(ClipboardMedia.tokens(from: pasteboard, store: MediaStore()), "text is what it's always been")

        pasteboard.clearContents()
        pasteboard.setString("https://example.com/picture.png", forType: .string)
        pasteboard.setData(png(width: 10, height: 10), forType: .png)
        XCTAssertNotNil(ClipboardMedia.tokens(from: pasteboard, store: MediaStore()), "Copy Image's address beside it")

        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)
        XCTAssertNil(ClipboardMedia.tokens(from: pasteboard, store: MediaStore()))
    }

    func testCopiedFilesTheImagesAndPDFsAmongThem() throws {
        let picture = folder.appendingPathComponent("picture.png")
        let document = folder.appendingPathComponent("report.pdf")
        let notes = folder.appendingPathComponent("notes.txt")
        try png(width: 40, height: 30).write(to: picture)
        try pdf(pages: 3).write(to: document)
        try Data("hello".utf8).write(to: notes)

        pasteboard.clearContents()
        pasteboard.writeObjects([picture, notes, document] as [NSURL])
        let store = MediaStore()
        let tokens = try XCTUnwrap(ClipboardMedia.tokens(from: pasteboard, store: store))
        XCTAssertEqual(MediaToken.describe(tokens, store: store), "[image 40×30]\n[PDF, 3 pages]", "not the text file")

        pasteboard.clearContents()
        pasteboard.writeObjects([notes] as [NSURL])
        XCTAssertNil(ClipboardMedia.tokens(from: pasteboard, store: store), "no images or PDFs: its name, as text")
    }

    func testAPDFBeyondClaudesLimitsSaysSo() throws {
        let item = try XCTUnwrap(ClipboardMedia.pdf(pdf(pages: 101)))
        XCTAssertEqual(item.summary, "PDF, 101 pages")
        XCTAssertEqual(item.problem, "Claude takes PDFs of up to 100 pages, and this has 101")
    }

    // MARK: Formatted text

    @MainActor
    func testMarkdownGoesOnTheClipboardFormattedToo() {
        let formatted = PasteboardText("# Notes\n- **one**\n- two", format: .auto)
        XCTAssertEqual(formatted.plain, "# Notes\n- **one**\n- two", "the Markdown, for a plain field")
        XCTAssertTrue(formatted.html?.contains("<h1>Notes</h1>") == true)
        XCTAssertTrue(formatted.html?.contains("<b>one</b>") == true)
        XCTAssertNotNil(formatted.rtf, "for Pages and TextEdit")

        XCTAssertNil(PasteboardText("Just a sentence.", format: .auto).html, "nothing to format: left plain")
        XCTAssertNil(PasteboardText("**bold**", format: .plain).html)
        XCTAssertNotNil(PasteboardText("Just a sentence.", format: .rich).html)
        XCTAssertNil(PasteboardText("snake_case_name", format: .auto).html, "underscores in a word aren't italics")
    }
}
