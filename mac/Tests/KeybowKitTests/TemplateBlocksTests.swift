@testable import KeybowKit
import XCTest

/// Counts how many replies are in flight at once.
private actor Flight {
    private(set) var now = 0
    private(set) var most = 0
    private(set) var calls: [String] = []

    func begin(_ body: String) {
        now += 1
        most = max(most, now)
        calls.append(body)
    }

    func end() { now -= 1 }
}

final class TemplateBlocksTests: XCTestCase {
    private func calls(in template: String, params: [String: String] = [:]) -> [TemplateBlockCall] {
        var seen: [TemplateBlockCall] = []
        _ = Template.expand(template, params: params, standIn: { seen.append($0); return "" })
        return seen
    }

    // MARK: - Reading blocks

    func testAttributesAndBody() {
        let call = calls(in: #"{{#ai model="opus 5.5" effort=low short}}Hi {{name}}{{/ai}}"#, params: ["name": "Ann"])
        XCTAssertEqual(call, [TemplateBlockCall(name: "ai", attributes: ["model": "opus 5.5", "effort": "low", "short": ""],
                                                body: "Hi Ann")])
    }

    func testClosingBracesInsideQuotesDontEndTheTag() {
        XCTAssertEqual(calls(in: #"{{#ai note="}}"}}x{{/ai}}"#).first?.attributes, ["note": "}}"])
    }

    func testProblemsAreReported() {
        XCTAssertEqual(TemplateBlocks.problems(in: "{{#ai}}never closed"), ["“{{#ai}}” is never closed with {{/ai}}."])
        XCTAssertEqual(TemplateBlocks.problems(in: "stray {{/ai}}"), ["“{{/ai}}” doesn't close anything."])
        XCTAssertEqual(TemplateBlocks.problems(in: "{{#a}}{{#b}}x{{/a}}{{/b}}"),
                       ["“{{/a}}” comes where “{{/b}}” was expected.", "“{{#a}}” is never closed with {{/a}}."])
        XCTAssertEqual(TemplateBlocks.problems(in: #"{{#ai model="x}}y{{/ai}}"#),
                       ["“{{#ai” has no closing }} — check its quotes."])
        XCTAssertEqual(TemplateBlocks.problems(in: "{{leaf}} and {{#ai}}fine{{/ai}}"), [])
    }

    func testPlaceholdersKeepTheirOrderAroundBlocks() {
        let result = Template.expand("{{b}} {{#t}}{{a}}{{/t}} {{c}}", params: [:], standIn: { _ in "" })
        XCTAssertEqual(result.missing, ["b", "a", "c"])
    }

    func testNamesIncludeThoseInsideBlocks() {
        XCTAssertEqual(Template.names(in: "{{#ai}}Summarise {{selection}}{{/ai}} for {{leaf}}"), ["selection", "leaf"])
    }

    func testDeepNestingNeedsNoStack() {
        let depth = 20_000
        let template = String(repeating: "{{#t}}", count: depth) + "x" + String(repeating: "{{/t}}", count: depth)
        XCTAssertEqual(TemplateBlocks.problems(in: template), [])
        var count = 0
        let result = Template.expand(template, params: [:], standIn: { call in
            count += 1
            return "(\(call.body))"
        })
        XCTAssertEqual(count, depth)
        XCTAssertTrue(result.text.hasPrefix("(((("))
        XCTAssertEqual(result.text.count, 1 + 2 * depth)
    }

    // MARK: - Working them out

    func testInnermostFirstThenOutward() async throws {
        let flight = Flight()
        let template = "{{#t}}A{{#t}}B{{/t}}C{{/t}}"
        let replies = try await TemplateBlocks.resolve([template], params: [:]) { call in
            await flight.begin(call.body)
            await flight.end()
            return "[\(call.body)]"
        }
        let order = await flight.calls
        XCTAssertEqual(order, ["B", "A[B]C"])
        XCTAssertEqual(Template.expand(template, params: [:], blocks: replies).text, "[A[B]C]")
    }

    func testSiblingsGoTogetherAndRepeatsOnce() async throws {
        let flight = Flight()
        let template = "{{#t}}x{{/t}}, {{#t}}x{{/t}} and {{#t}}y{{/t}}"
        let replies = try await TemplateBlocks.resolve([template], params: [:]) { call in
            await flight.begin(call.body)
            try await Task.sleep(for: .milliseconds(80))
            await flight.end()
            return call.body.uppercased()
        }
        let (calls, most) = await (flight.calls, flight.most)
        XCTAssertEqual(calls.sorted(), ["x", "y"], "the same block is asked for once")
        XCTAssertEqual(most, 2, "both asked for together")
        XCTAssertEqual(Template.expand(template, params: [:], blocks: replies).text, "X, X and Y")
    }

    func testDeepNestingResolvesRoundByRound() async throws {
        let depth = 40
        let template = String(repeating: "{{#t}}", count: depth) + "x" + String(repeating: "{{/t}}", count: depth)
        let replies = try await TemplateBlocks.resolve([template], params: [:], limit: depth) { "(\($0.body))" }
        XCTAssertEqual(replies.count, depth)
        XCTAssertEqual(Template.expand(template, params: [:], blocks: replies).text,
                       String(repeating: "(", count: depth) + "x" + String(repeating: ")", count: depth))
    }

    func testRepliesAreNeverReadAsTemplates() async throws {
        let template = "Reply: {{#t}}go{{/t}}"
        let replies = try await TemplateBlocks.resolve([template], params: [:]) { _ in "{{secret}} {{#t}}again{{/t}}" }
        let result = Template.expand(template, params: ["secret": "leaked"], blocks: replies)
        XCTAssertEqual(result.text, "Reply: {{secret}} {{#t}}again{{/t}}")
        XCTAssertEqual(replies.count, 1)
    }

    func testTooManyIsRefusedBeforeAsking() async {
        let template = (1...30).map { "{{#t}}\($0){{/t}}" }.joined()
        do {
            _ = try await TemplateBlocks.resolve([template], params: [:]) { _ in
                XCTFail("nothing should be asked")
                return ""
            }
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? TemplateBlocks.Failure, .tooMany(limit: TemplateBlocks.maximumCalls))
        }
    }

    func testCancellingStopsEveryRequest() async {
        let task = Task {
            try await TemplateBlocks.resolve(["{{#t}}a{{/t}}{{#t}}b{{/t}}"], params: [:]) { _ in
                try await Task.sleep(for: .seconds(30))
                return ""
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        let started = Date()
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        guard case .failure(let error) = result else { return XCTFail("expected cancellation") }
        XCTAssertTrue(error is CancellationError)
    }

    func testEncodingAppliesOutsideBlocksOnly() async throws {
        let template = "https://x/?q={{#t}}{{q}}{{/t}}"
        let replies = try await TemplateBlocks.resolve([template], params: ["q": "a b"]) { call in
            XCTAssertEqual(call.body, "a b", "the prompt gets the value as it is")
            return call.body
        }
        let result = Template.expand(template, params: ["q": "a b"], encode: Template.linkEncoded, blocks: replies)
        XCTAssertEqual(result.text, "https://x/?q=a%20b")
    }

    // MARK: - In actions

    private func tree(_ outline: String) throws -> KeybowConfig {
        let (document, _) = OutlineParser.parse(outline)
        let compiled = OutlineCompiler.compile(document, locateApp: { _ in nil })
        return try XCTUnwrap(compiled.config, compiled.configError ?? "")
    }

    func testBlocksAreRefusedWhereTheReplyCouldSteer() throws {
        let config = try tree("""
        1. Search [Link, url: "https://duckduckgo.com/?q={{#ai}}pick a topic{{/ai}}"]
        2. Ring [Call, to: "{{#ai}}who should I call{{/ai}}"]
        """)
        for (path, field) in [([0], "url"), ([1], "to")] {
            let selection = try XCTUnwrap(config.resolve(path: path))
            let context = ActionContext(templatesDirectory: nil)
            XCTAssertThrowsError(try ActionPlanner.blockTexts(for: selection, context: context)) {
                XCTAssertEqual($0 as? ActionPlanError, .blockNotAllowed(field: field, block: "ai"))
            }
            XCTAssertThrowsError(try ActionPlanner.plan(selection, config: config, context: context))
        }
    }

    func testRepliesFillTheActionIn() async throws {
        let config = try tree(#"1. Doc [Copy, text: "Summary: {{#ai}}Summarise {{leaf}}{{/ai}}"]"#)
        let selection = try XCTUnwrap(config.resolve(path: [0]))
        var context = ActionContext(templatesDirectory: nil)

        let texts = try ActionPlanner.blockTexts(for: selection, context: context)
        XCTAssertEqual(texts, ["Summary: {{#ai}}Summarise {{leaf}}{{/ai}}"])
        XCTAssertThrowsError(try ActionPlanner.plan(selection, config: config, context: context)) {
            XCTAssertEqual($0 as? ActionPlanError, .blockNotWorkedOut("ai"), "not before it's worked out")
        }

        context.blockReplies = try await TemplateBlocks.resolve(
            texts, params: ActionPlanner.values(for: selection, context: context), now: context.now) { call in
            XCTAssertEqual(call.body, "Summarise Doc")
            return "It's a document."
        }
        XCTAssertEqual(try ActionPlanner.plan(selection, config: config, context: context).plan,
                       .copyToClipboard("Summary: It's a document."))
    }

    func testTemplateFilesAreIncluded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keybow-blocks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# {{leaf}}\n\n{{#ai}}Notes on {{selection}}{{/ai}}".write(
            to: folder.appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
        try "{{#ai}}never closed".write(to: folder.appendingPathComponent("broken.md"), atomically: true, encoding: .utf8)
        let config = try tree("""
        1. Brief [Notes, brief.md]
        2. Broken [Notes, broken.md]
        """)
        let context = ActionContext(templatesDirectory: folder)
        XCTAssertEqual(try ActionPlanner.blockTexts(for: try XCTUnwrap(config.resolve(path: [0])), context: context).count, 1)
        XCTAssertThrowsError(try ActionPlanner.blockTexts(for: try XCTUnwrap(config.resolve(path: [1])), context: context)) {
            XCTAssertEqual($0 as? ActionPlanError, .templateProblem("broken.md: “{{#ai}}” is never closed with {{/ai}}."))
        }
    }

    func testTheEditorFlagsBlocksItWontRun() {
        let (document, _) = OutlineParser.parse("""
        1. Search [Link, url: "https://x/?q={{#ai}}pick{{/ai}}"]
        2. Note [title: "{{#ai}}never closed"]
        3. Value [topic: "{{#ai}}pick{{/ai}}"]
        """)
        let compiled = OutlineCompiler.compile(document, locateApp: { _ in nil })
        let messages = compiled.diagnostics.map(\.message)
        XCTAssertTrue(messages.contains("{{#ai}} can't go in url: a reply there could change where the action goes."))
        XCTAssertTrue(messages.contains("“{{#ai}}” is never closed with {{/ai}}."))
        XCTAssertTrue(messages.contains("{{#ai}} only works in an action's fields and templates; in topic it's kept as written."))
    }

    func testPreviewsShowAStandInAndSpendNothing() throws {
        let config = try tree(#"1. Doc [Copy, text: "{{#ai}}Summarise {{leaf}}{{/ai}}"]"#)
        let summary = ActionSummary(selection: try XCTUnwrap(config.resolve(path: [0])), config: config)
        XCTAssertEqual(summary.details.count, 1)
        XCTAssertTrue(summary.details[0].contains("‹"), "a stand-in, not a request: \(summary.details)")
    }
}
