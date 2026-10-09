@testable import KeybowAI
import KeybowKit
import XCTest

/// Answers with a canned response and keeps the request: nothing leaves the Mac.
private final class StubTransport: HTTPTransport, @unchecked Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body: Any = ["content": [["type": "text", "text": "Hello"]], "stop_reason": "end_turn"]
    /// Answered in turn, before `body`.
    var bodies: [Any] = []
    var error: Error?
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if let error { throw error }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (try JSONSerialization.data(withJSONObject: bodies.isEmpty ? body : bodies.removeFirst()), response)
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

    // MARK: - Tools

    func testClaudeUsesItsToolsThenReplies() async throws {
        let (module, transport) = module()
        let thinking: [String: Any] = ["type": "thinking", "thinking": "", "signature": "sig-1"]
        transport.bodies = [
            ["content": [thinking, ["type": "tool_use", "id": "toolu_1", "name": "music_library",
                                    "input": ["list": "genres", "limit": 4]],
                         ["type": "tool_use", "id": "toolu_2", "name": "teleport", "input": [:]]],
             "stop_reason": "tool_use"],
            ["content": [["type": "text", "text": "Here's your tree."]], "stop_reason": "end_turn"],
        ]
        let heard = Heard()
        let tool = ClaudeModule.Tool(["name": "music_library", "description": "The library.",
                                      "input_schema": ["type": "object"]]) { input in
            heard.list = input["list"] as? String
            return "1. Jazz"
        }
        let reply = try await module.converse(system: "Design trees.", turns: [("user", "My top genres, please")],
                                              tools: [tool])
        XCTAssertEqual(reply, "Here's your tree.")
        XCTAssertEqual(heard.list, "genres")
        XCTAssertEqual(transport.requests.count, 2)

        let first = try sent(transport.requests[0])
        XCTAssertEqual((first["tools"] as? [[String: Any]])?.map { $0["name"] as? String }, ["music_library"])
        let messages = try XCTUnwrap(try sent(transport.requests[1])["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let turn = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(turn.first?["signature"] as? String, "sig-1", "its turn goes back as it came, thinking and all")
        let results = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(results.count, 2, "every answer in one turn")
        XCTAssertEqual(results[0]["tool_use_id"] as? String, "toolu_1")
        XCTAssertEqual(results[0]["content"] as? String, "1. Jazz")
        XCTAssertNil(results[0]["is_error"])
        XCTAssertEqual(results[1]["is_error"] as? Bool, true, "a tool it doesn't have is a failure it hears about")
    }

    func testAFailingToolIsToldOfAndAnEndlessOneStops() async throws {
        let (module, transport) = module()
        let use: [String: Any] = ["content": [["type": "tool_use", "id": "t", "name": "look", "input": [:]]],
                                  "stop_reason": "tool_use"]
        transport.body = use
        let tool = ClaudeModule.Tool(["name": "look", "description": "", "input_schema": ["type": "object"]]) { _ in
            throw ModuleError("The library can't be read")
        }
        do {
            _ = try await module.converse(system: "S", turns: [("user", "Hi")], tools: [tool])
            XCTFail("it can't go on for ever")
        } catch let error as ModuleError {
            XCTAssertEqual(error.message, "Claude kept looking things up without replying")
        }
        XCTAssertEqual(transport.requests.count, ClaudeModule.toolRounds)
        let messages = try XCTUnwrap(try sent(transport.requests[1])["messages"] as? [[String: Any]])
        let result = try XCTUnwrap((messages.last?["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(result["is_error"] as? Bool, true)
        XCTAssertEqual(result["content"] as? String, "The library can't be read")

        // Without tools, a reply is taken as it is.
        let (plain, quiet) = self.module()
        quiet.body = ["content": [["type": "text", "text": "Hello"]], "stop_reason": "end_turn"]
        let said = try await plain.converse(system: "S", turns: [("user", "Hi")])
        XCTAssertEqual(said, "Hello")
        XCTAssertNil(try sent(quiet.requests[0])["tools"])
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

    // MARK: - Privacy

    func testWhatsKeptFromClaudeIsRefused() {
        let host = MemoryModuleHost()
        let module = ClaudeModule(transport: StubTransport())
        module.start(host: host)
        XCTAssertEqual(module.sharing, ClaudeModule.Sharing(), "everything, until it's changed")
        XCTAssertNil(module.refusal(forBlock: "ai", using: ["selection", "clipboard", "location.latitude"]))

        var sharing = ClaudeModule.Sharing()
        sharing.selection = false
        sharing.location = false
        sharing.music = MusicSharing(.artists, playlists: false)
        for (key, value) in sharing.settings { host.set(value, for: key, of: ClaudeModule.id) }
        XCTAssertEqual(module.sharing, sharing, "as it was kept")
        XCTAssertEqual(module.refusal(forBlock: "ai", using: ["leaf", "location.latitude"]),
                       "This key would send {{location.latitude}} to Claude, and Settings → Privacy keeps where you are from it.")
        XCTAssertNotNil(module.refusal(forBlock: "ai", using: ["selection"]))
        XCTAssertNil(module.refusal(forBlock: "ai", using: ["clipboard", "leaf", "locations"]))

        for (key, value) in ClaudeModule.Sharing().settings {
            XCTAssertNil(value, "\(key): nothing kept while it's as it was to begin with")
        }
    }

    func testTheCalendarKeptFromClaudeIsRefused() {
        let host = MemoryModuleHost()
        let module = ClaudeModule(transport: StubTransport())
        module.start(host: host)
        XCTAssertNil(module.refusal(forBlock: "ai", using: ["event", "agenda.today", "reminder.due"]))

        var sharing = ClaudeModule.Sharing()
        sharing.calendar = false
        for (key, value) in sharing.settings { host.set(value, for: key, of: ClaudeModule.id) }
        XCTAssertEqual(module.sharing, sharing, "as it was kept")
        XCTAssertEqual(module.refusal(forBlock: "ai", using: ["event.attendees", "leaf"]),
                       "This key would send {{event.attendees}} to Claude, and Settings → Privacy keeps your calendar and reminders from it.")
        XCTAssertNotNil(module.refusal(forBlock: "ai", using: ["agenda"]))
        XCTAssertNotNil(module.refusal(forBlock: "ai", using: ["reminder.list"]))
        XCTAssertNil(module.refusal(forBlock: "ai", using: ["events", "date", "leaf", "selection"]))
    }

    func testImagesAndPDFsKeptFromClaudeArentSent() async {
        let transport = StubTransport()
        let host = MemoryModuleHost()
        host.set("sk-test", for: "apiKey", of: ClaudeModule.id, secret: true)
        let module = ClaudeModule(transport: transport)
        module.start(host: host)
        var sharing = ClaudeModule.Sharing()
        sharing.media = false
        for (key, value) in sharing.settings { host.set(value, for: key, of: ClaudeModule.id) }

        let image = MediaStore.shared.token(for: MediaItem(kind: .image, data: Data([1]), mediaType: "image/png",
                                                           summary: "image 1×1"))
        await assertFails(module, TemplateBlockCall(name: "ai", body: "What's in this? \(image)"),
                          message: "Images and PDFs aren't sent to Claude")
        XCTAssertTrue(transport.requests.isEmpty)
        _ = try? await module.reply(to: TemplateBlockCall(name: "ai", body: "Text is still sent"))
        XCTAssertEqual(transport.requests.count, 1)
    }
}

private final class Heard: @unchecked Sendable {
    var list: String?
}
