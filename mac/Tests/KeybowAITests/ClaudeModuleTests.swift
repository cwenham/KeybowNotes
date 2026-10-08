@testable import KeybowAI
import KeybowKit
import XCTest

/// Answers with a canned response and keeps the request: nothing leaves the Mac.
private final class StubTransport: HTTPTransport, @unchecked Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body: Any = ["content": [["type": "text", "text": "Hello"]], "stop_reason": "end_turn"]
    var error: Error?
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if let error { throw error }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (try JSONSerialization.data(withJSONObject: body), response)
    }
}

final class ClaudeModuleTests: XCTestCase {
    private func module(key: String? = "sk-test", model: String? = nil) -> (ClaudeModule, StubTransport) {
        let transport = StubTransport()
        let host = MemoryModuleHost()
        host.set(key, for: "apiKey", of: ClaudeModule.id, secret: true)
        host.set(model, for: "model", of: ClaudeModule.id)
        let module = ClaudeModule(transport: transport)
        module.start(host: host)
        return (module, transport)
    }

    private func sent(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func assertFails(_ module: ClaudeModule, _ call: TemplateBlockCall, message: String, detail: String? = nil,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await module.reply(to: call)
            XCTFail("expected “\(message)”", file: file, line: line)
        } catch let error as ModuleError {
            XCTAssertEqual(error.message, message, file: file, line: line)
            if let detail { XCTAssertEqual(error.detail, detail, file: file, line: line) }
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: - The request

    func testDefaultsToOpus55AtLowEffortWithFallbacks() async throws {
        let (module, transport) = module()
        let reply = try await module.reply(to: TemplateBlockCall(name: "ai", body: "  Summarise: the text  "))
        XCTAssertEqual(reply, "Hello")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")

        let body = try sent(request)
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 16_000)
        XCTAssertEqual((body["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertNil(body["thinking"], "thinking is left to the model")
        XCTAssertNil(body["temperature"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "user", "content": "Summarise: the text"]])
        XCTAssertNotNil(body["system"])
    }

    func testImagesAndPDFsGoAsThemselvesWhereTheyreWritten() async throws {
        let (module, transport) = module()
        let image = MediaStore.shared.token(for: MediaItem(kind: .image, data: Data([1, 2]), mediaType: "image/png",
                                                           summary: "image 4×3"))
        let pdf = MediaStore.shared.token(for: MediaItem(kind: .pdf, data: Data([3]), mediaType: "application/pdf",
                                                         summary: "PDF, 1 page"))
        _ = try await module.reply(to: TemplateBlockCall(name: "ai", body: "What's in this? \(image)\nAnd \(pdf)"))
        let messages = try XCTUnwrap(try sent(XCTUnwrap(transport.requests.first))["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "image", "text", "document"])
        XCTAssertEqual(content[0]["text"] as? String, "What's in this? ")
        let source = try XCTUnwrap(content[1]["source"] as? [String: String])
        XCTAssertEqual(source, ["type": "base64", "media_type": "image/png", "data": Data([1, 2]).base64EncodedString()])
        XCTAssertEqual((content[3]["source"] as? [String: String])?["media_type"], "application/pdf")
    }

    func testMediaThatCantGoIsRefused() async {
        let (module, _) = module()
        let long = MediaStore.shared.token(for: MediaItem(kind: .pdf, data: Data([3]), mediaType: "application/pdf",
                                                          summary: "PDF, 140 pages", problem: "Too long"))
        await assertFails(module, TemplateBlockCall(name: "ai", body: "Summarise \(long)"),
                          message: "Claude can't take that PDF", detail: "Too long")
        await assertFails(module, TemplateBlockCall(name: "ai", body: "Describe ⟦media:00000000⟧"),
                          message: "The image to send is no longer to hand")
    }

    func testAttributesAndSettingsChooseTheModel() async throws {
        let (module, transport) = module(model: "sonnet-5")
        _ = try await module.reply(to: TemplateBlockCall(name: "ai", body: "x"))
        _ = try await module.reply(to: TemplateBlockCall(name: "ai", attributes: ["model": "Haiku 4.5"], body: "x"))
        _ = try await module.reply(to: TemplateBlockCall(name: "ai", attributes: ["effort": "HIGH"], body: "y"))

        let bodies = try transport.requests.map(sent)
        XCTAssertEqual(bodies[0]["model"] as? String, "claude-sonnet-5", "the Settings window's choice")
        XCTAssertNil(bodies[0]["fallbacks"])
        XCTAssertEqual(bodies[1]["model"] as? String, "claude-haiku-4-5", "the block's own")
        XCTAssertNil(bodies[1]["output_config"], "Haiku 4.5 takes no effort")
        XCTAssertNil(transport.requests[1].value(forHTTPHeaderField: "anthropic-beta"))
        XCTAssertEqual((bodies[2]["output_config"] as? [String: String])?["effort"], "high")
    }

    func testModelNames() {
        XCTAssertEqual(ClaudeModule.model(named: "Opus 5.5")?.id, "claude-opus-5-5")
        XCTAssertEqual(ClaudeModule.model(named: "opus-5.5")?.id, "claude-opus-5-5")
        XCTAssertEqual(ClaudeModule.model(named: "claude-opus-5-5")?.id, "claude-opus-5-5")
        XCTAssertEqual(ClaudeModule.model(named: "opus")?.id, "claude-opus-5-5", "a family means its newest")
        XCTAssertEqual(ClaudeModule.model(named: "Opus 5")?.id, "claude-opus-5")
        XCTAssertEqual(ClaudeModule.model(named: "sonnet")?.id, "claude-sonnet-5")
        XCTAssertEqual(ClaudeModule.model(named: "claude-future-9")?.id, "claude-future-9", "passed through")
        XCTAssertNil(ClaudeModule.model(named: "gpt-5"))
    }

    // MARK: - What can go wrong before asking

    func testRefusesWhatItCantSend() async {
        await assertFails(module(key: nil).0, TemplateBlockCall(name: "ai", body: "x"), message: "Claude needs an API key")
        await assertFails(module().0, TemplateBlockCall(name: "ai", body: "   "), message: "A {{#ai}} block is empty")
        await assertFails(module().0, TemplateBlockCall(name: "ai", attributes: ["modle": "opus"], body: "x"),
                          message: "{{#ai}} doesn't know “modle”")
        await assertFails(module().0, TemplateBlockCall(name: "ai", attributes: ["model": "gpt-5"], body: "x"),
                          message: "“gpt-5” isn't a Claude model this knows")
        await assertFails(module().0, TemplateBlockCall(name: "ai", attributes: ["effort": "extreme"], body: "x"),
                          message: "“extreme” isn't an effort level")
        await assertFails(module().0, TemplateBlockCall(name: "ai", attributes: ["source": "other"], body: "x"),
                          message: "{{#ai}} can only ask Claude")
    }

    // MARK: - The reply

    func testOnlyTextBlocksAreTheReply() async throws {
        let (module, transport) = module()
        transport.body = ["stop_reason": "end_turn", "content": [
            ["type": "thinking", "thinking": ""],
            ["type": "text", "text": "  Line one.\n"],
            ["type": "text", "text": "Line two.  "],
        ]]
        let reply = try await module.reply(to: TemplateBlockCall(name: "ai", body: "x"))
        XCTAssertEqual(reply, "Line one.\nLine two.")
    }

    func testADeclineIsReportedNotInserted() async {
        let (module, transport) = module()
        transport.body = ["stop_reason": "refusal", "content": [],
                          "stop_details": ["type": "refusal", "category": "bio", "explanation": "Not able to help with that."]]
        await assertFails(module, TemplateBlockCall(name: "ai", body: "x"),
                          message: "Claude declined this request", detail: "Not able to help with that.")
    }

    func testACutOffReplyIsntUsed() async {
        let (module, transport) = module()
        transport.body = ["stop_reason": "max_tokens", "content": [["type": "text", "text": "Half a"]]]
        await assertFails(module, TemplateBlockCall(name: "ai", body: "x"), message: "Claude's reply was cut off")
    }

    func testErrorsSayWhatToDo() async {
        let (module, transport) = module()
        transport.status = 401
        transport.body = ["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]]
        await assertFails(module, TemplateBlockCall(name: "ai", body: "x"),
                          message: "Claude didn't accept the API key", detail: "Check it in Settings → Claude.")
        transport.status = 429
        transport.headers = ["retry-after": "20"]
        await assertFails(module, TemplateBlockCall(name: "ai", body: "x"),
                          message: "Too many requests to Claude just now", detail: "Try again in 20 seconds.")
        transport.status = 529
        transport.body = ["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]]
        await assertFails(module, TemplateBlockCall(name: "ai", body: "x"),
                          message: "Claude is busy or unavailable", detail: "Overloaded")
    }

    func testCancellingIsNotAnError() async {
        let (module, transport) = module()
        transport.error = URLError(.cancelled)
        do {
            _ = try await module.reply(to: TemplateBlockCall(name: "ai", body: "x"))
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
