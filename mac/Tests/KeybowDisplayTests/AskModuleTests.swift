@testable import KeybowDisplay
import KeybowKit
import XCTest

final class AskModuleTests: XCTestCase {
    private func module(answer: ModuleDisplay.Result) -> (AskModule, MemoryModuleHost) {
        let host = MemoryModuleHost()
        host.displayResult = answer
        let ask = AskModule()
        ask.start(host: host)
        return (ask, host)
    }

    private func request(_ fields: [String: String], leaf: String = "Search") -> ModuleRequest {
        ModuleRequest(type: AskModule.type, fields: fields, labels: ["Look up", leaf])
    }

    func testTheAnswerGoesToTheOKAction() async throws {
        let (ask, host) = module(answer: .entered("Grace Hopper"))
        let outcome = await ask.run(request(["text": "Search for what?", "initial": "Ada", "hint": "a name"]), now: Date())
        XCTAssertEqual(outcome, .then("ok", values: ["answer": "Grace Hopper"], text: "{{answer}}"),
                       "{{answer}}, and what Copy or Insert use with no text of their own")
        let shown = try XCTUnwrap(host.displayed.first)
        XCTAssertEqual(shown.content, .markdown("Search for what?"))
        XCTAssertEqual(shown.buttons, [.cancel, .ok])
        XCTAssertEqual(shown.field, ModuleDisplay.Field(initial: "Ada", hint: "a name", multiline: false))
    }

    func testCancelRunsItsOwnAction() async {
        let (ask, _) = module(answer: .cancel)
        let outcome = await ask.run(request(["text": "Search for what?"]), now: Date())
        XCTAssertEqual(outcome.followUp, "cancel")
        XCTAssertEqual(outcome.values, ["answer": ""])
    }

    func testReplacedOrClosedRunsNothing() async {
        let (ask, _) = module(answer: .dismissed)
        let outcome = await ask.run(request([:]), now: Date())
        XCTAssertEqual(outcome, .quiet)
    }

    func testTheQuestionAndTheField() async throws {
        let (ask, host) = module(answer: .dismissed)
        _ = await ask.run(request(["multiline": "true", "initial": ""]), now: Date())
        let shown = try XCTUnwrap(host.displayed.first)
        XCTAssertEqual(shown.content, .markdown("Search"), "with no question, the label asks")
        XCTAssertEqual(shown.field?.multiline, true)

        let page = "<!DOCTYPE html><p>Which <b>one</b>?</p>"
        _ = await ask.run(request(["text": page]), now: Date())
        XCTAssertEqual(host.displayed.first?.content, .html(page))
    }

    func testWhatThePreviewSays() {
        let (ask, _) = module(answer: .dismissed)
        let summary = ask.summary(of: request(["text": "**Search** for what?\nOr not"]), now: Date())
        XCTAssertEqual(summary.verb, "Ask")
        XCTAssertEqual(summary.subject, "**Search** for what?")
        XCTAssertEqual(ask.summary(of: request([:], leaf: "Jot"), now: Date()).subject, "Jot")
    }

    func testItsOKAndCancelHoldActions() throws {
        let fields = try XCTUnwrap(AskModule().manifest.actionTypes.first?.fields)
        XCTAssertEqual(fields.filter { $0.kind == .action }.map(\.key), ["ok", "cancel"])
        XCTAssertEqual(AskModule().manifest.actionTypes.first?.takesText, true)
    }
}
