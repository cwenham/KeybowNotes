@testable import KeybowDisplay
import KeybowKit
import XCTest

final class DisplayModuleTests: XCTestCase {
    private func module(answer: ModuleDisplay.Result = .dismissed) -> (DisplayModule, MemoryModuleHost) {
        let host = MemoryModuleHost()
        host.displayResult = answer
        let display = DisplayModule()
        display.start(host: host)
        return (display, host)
    }

    private func request(_ fields: [String: String], leaf: String = "Quote") -> ModuleRequest {
        ModuleRequest(type: DisplayModule.type, fields: fields, labels: ["Show", leaf])
    }

    func testItShowsMarkdownAndFadesByItself() async throws {
        let (display, host) = module()
        let outcome = await display.run(request(["text": "*Carpe* diem", "fade": "15 sec"]), now: Date())
        XCTAssertEqual(outcome, .quiet, "it showed itself: nothing more for the overlay")
        let shown = try XCTUnwrap(host.displayed.first)
        XCTAssertEqual(shown, ModuleDisplay(content: .markdown("*Carpe* diem"), buttons: [], fadeAfter: 15))
    }

    func testAnHTMLDocumentIsShownAsOne() async throws {
        let (display, host) = module()
        let page = "<!DOCTYPE html><html><body><p>Hi &amp; bye</p></body></html>"
        _ = await display.run(request(["text": page]), now: Date())
        XCTAssertEqual(host.displayed.first?.content, .html(page))
    }

    func testWithoutAFadeItStaysLongEnoughToRead() {
        XCTAssertEqual(DisplayModule.readingTime("Carpe diem"), 6, "at least six seconds")
        XCTAssertEqual(DisplayModule.readingTime(Array(repeating: "word", count: 60).joined(separator: " ")), 20)
        XCTAssertEqual(DisplayModule.readingTime(Array(repeating: "word", count: 600).joined(separator: " ")), 60,
                       "a minute at most")
    }

    func testOKAndCancelRunTheirActions() async {
        let (display, _) = module(answer: .ok)
        let ok = await display.run(request(["text": "Keep it?", "button": "okCancel"]), now: Date())
        XCTAssertEqual(ok, .then("ok", values: ["displayed": "Keep it?"], text: "{{displayed}}"),
                       "{{displayed}}, and what Copy or Insert use with no text of their own")

        let (cancelling, _) = module(answer: .cancel)
        let cancel = await cancelling.run(request(["text": "Keep it?", "button": "okCancel"]), now: Date())
        XCTAssertEqual(cancel.followUp, "cancel")

        let (closing, host) = module(answer: .dismissed)
        let closed = await closing.run(request(["text": "Keep it?", "button": "ok"]), now: Date())
        XCTAssertEqual(closed, .quiet, "closed some other way: nothing runs")
        XCTAssertEqual(host.displayed.first?.buttons, [.ok])
    }

    func testTheButtonsAsWritten() {
        XCTAssertEqual(DisplayModule.buttons("ok"), [.ok])
        XCTAssertEqual(DisplayModule.buttons("Cancel"), [.cancel])
        XCTAssertEqual(DisplayModule.buttons("okCancel"), [.cancel, .ok], "Cancel on the left, OK on the right")
        XCTAssertEqual(DisplayModule.buttons("OK cancel"), [.cancel, .ok])
        XCTAssertEqual(DisplayModule.buttons("both"), [.cancel, .ok])
        XCTAssertEqual(DisplayModule.buttons(nil), [])
        XCTAssertNil(DisplayModule.buttons("yes"))
    }

    func testFadeTimes() {
        XCTAssertEqual(DisplayModule.seconds("15sec"), 15)
        XCTAssertEqual(DisplayModule.seconds("15 s"), 15)
        XCTAssertEqual(DisplayModule.seconds("15"), 15, "seconds, when it doesn't say")
        XCTAssertEqual(DisplayModule.seconds("1.5 min"), 90)
        XCTAssertEqual(DisplayModule.seconds("2M"), 120)
        XCTAssertNil(DisplayModule.seconds("soon"))
        XCTAssertNil(DisplayModule.seconds("0"))
        XCTAssertNil(DisplayModule.seconds("2 hours"))
    }

    func testMistakesAreCaughtBeforeItRuns() {
        let (display, _) = module()
        XCTAssertEqual(display.problem(with: request(["button": "yes"])), "Buttons are ok, cancel or okCancel, not “yes”.")
        XCTAssertEqual(display.problem(with: request(["fade": "soon"])),
                       "“soon” isn't a time to fade after: write it like 15 sec or 2 min.")
        XCTAssertNil(display.problem(with: request(["button": "okCancel", "fade": "10s"])))
    }

    func testWhatThePreviewSays() {
        let (display, _) = module()
        let summary = display.summary(of: request(["text": "‹a quote from quotes.md›\nmore", "button": "ok"]), now: Date())
        XCTAssertEqual(summary.verb, "Show")
        XCTAssertEqual(summary.subject, "‹a quote from quotes.md›")
        XCTAssertEqual(summary.details, ["OK"])
        XCTAssertEqual(display.summary(of: request(["template": "today.md", "fade": "20 sec"]), now: Date()).details,
                       ["for 20 s"])
        XCTAssertEqual(display.summary(of: request([:], leaf: "Stoics"), now: Date()).subject, "Stoics")
    }

    func testTheTextShownReadsPlainly() {
        XCTAssertEqual(DisplayModule.plainText("*Just* Markdown"), "*Just* Markdown")
        XCTAssertEqual(DisplayModule.plainText("""
            <!DOCTYPE html><html><head><style>p { color: red }</style><script>x()</script></head>
            <body><h1>Title</h1><p>One &amp; two<br>three</p></body></html>
            """), "Title\nOne & two\nthree")
    }
}
