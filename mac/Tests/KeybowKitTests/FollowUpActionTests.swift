@testable import KeybowKit
import XCTest

/// A module type that takes text, like Display, noting what it was given.
private final class Shower: KeybowModule, @unchecked Sendable {
    let manifest = ModuleManifest(id: "shower", name: "Shower", actionTypes: [
        ModuleActionType(type: "shower", title: "Shower", keywords: ["Shower"], symbol: "eye", fields: [
            ModuleField(key: "ok", title: "On OK", kind: .action),
            ModuleField(key: "cancel", title: "On Cancel", kind: .action),
        ], takesText: true),
    ])
    func start(host: ModuleHost) {}
    func summary(of request: ModuleRequest, now: Date) -> ModuleSummary { ModuleSummary(verb: "", subject: "") }
    func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome { .quiet }
}

final class FollowUpActionTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        ModuleRegistry.shared.register(Shower(), host: MemoryModuleHost())
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("FollowUp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func compile(_ outline: String) throws -> (KeybowConfig, OutlineCompilation) {
        let (document, _) = OutlineParser.parse(outline)
        let compiled = OutlineCompiler.compile(document, locateApp: { _ in nil })
        return (try XCTUnwrap(compiled.config, compiled.configError ?? ""), compiled)
    }

    private func request(_ config: KeybowConfig, _ path: [Int], environment: [String: String] = [:]) throws -> ModuleRequest {
        let selection = try XCTUnwrap(config.resolve(path: path))
        var context = ActionContext(templatesDirectory: folder)
        context.environment = environment
        guard case .module(let request) = try ActionPlanner.plan(selection, config: config, context: context).plan else {
            throw XCTSkip("not a module plan")
        }
        return request
    }

    func testOKAndCancelHoldActionsOfTheirOwn() throws {
        let (config, compiled) = try compile("""
            1. Idea [Shower, text: "Hi", ok: Copy, ok.text: "{{displayed}}!", cancel.type: notes.append, cancel.find.byName: Inbox, cancel.createIfMissing: yes]
            """)
        XCTAssertTrue(compiled.warnings.isEmpty, "\(compiled.warnings)")
        let action = try XCTUnwrap(config.resolve(path: [0])?.action)
        let ok = try XCTUnwrap(action.nestedAction("ok"))
        XCTAssertEqual(ok.type, "clipboard.copy", "from its keyword")
        XCTAssertEqual(ok.fields["text"], .string("{{displayed}}!"))
        let cancel = try XCTUnwrap(action.nestedAction("cancel"))
        XCTAssertEqual(cancel.type, "notes.append")
        XCTAssertEqual(cancel.fields["createIfMissing"], .bool(true), "typed as its own action's field")
        XCTAssertEqual(cancel.fields["find"], .object(["byName": .string("Inbox")]), "nested as in an action of its own")
        XCTAssertNil(action.nestedAction("text"))
    }

    func testAFollowUpRunsForTheSameKeyWithTheValuesGiven() throws {
        let (config, _) = try compile(#"1. Idea [Shower, text: "Hi", ok: Copy, ok.text: "Kept: {{displayed}} ({{leaf}})"]"#)
        let selection = try XCTUnwrap(config.resolve(path: [0]))
        let next = try XCTUnwrap(selection.action?.nestedAction("ok"))
        var context = ActionContext(templatesDirectory: nil)
        context.environment["displayed"] = "Carpe diem"
        let plan = try ActionPlanner.plan(selection.with(action: next), config: config, context: context).plan
        XCTAssertEqual(plan, .copyToClipboard("Kept: Carpe diem (Idea)"))
    }

    func testAFollowUpsBlocksAndValuesWaitForIt() throws {
        // Worked out when OK is chosen, with {{answer}} — not when the key that
        // asks is pressed, before there's any answer to give Claude.
        let (config, _) = try compile("""
            1. Ask Claude [Shower, text: "What would you ask?", ok: Shower, ok.text: "{{#ai}}{{answer}}{{/ai}}"]
            2. Look up [Shower, text: "{{leaf}}?", ok: Shower, ok.text: "{{api.wikipedia term={{answer}}}}"]
            """)
        let context = ActionContext(templatesDirectory: nil)
        let asking = try XCTUnwrap(config.resolve(path: [0]))
        XCTAssertEqual(try ActionPlanner.blockTexts(for: asking, context: context), [])
        XCTAssertFalse(ActionPlanner.placeholders(for: asking, context: context).contains("answer"))
        let lookingUp = try XCTUnwrap(config.resolve(path: [1]))
        XCTAssertEqual(ActionPlanner.placeholders(for: lookingUp, context: context), ["leaf"])

        // Once it's the action running, they're its own.
        let next = try XCTUnwrap(asking.action?.nestedAction("ok"))
        XCTAssertEqual(try ActionPlanner.blockTexts(for: asking.with(action: next), context: context),
                       ["{{#ai}}{{answer}}{{/ai}}"])
        let lookup = try XCTUnwrap(lookingUp.action?.nestedAction("ok"))
        XCTAssertTrue(ActionPlanner.placeholders(for: lookingUp.with(action: lookup), context: context)
            .contains("api.wikipedia term={{answer}}"))
    }

    func testANoteWordNamesAnActionToo() throws {
        let (config, compiled) = try compile("1. Jot [Shower, ok: append, ok.find.byName: Inbox, ok.entry: \"{{answer}}\", cancel: new]")
        XCTAssertTrue(compiled.diagnostics.isEmpty, "\(compiled.diagnostics.map(\.message))")
        let action = try XCTUnwrap(config.resolve(path: [0])?.action)
        XCTAssertEqual(action.nestedAction("ok")?.type, "notes.append")
        XCTAssertEqual(action.nestedAction("cancel")?.type, "notes.create")
    }

    func testAnAnswerFillsTheFollowUp() throws {
        let (config, _) = try compile(#"1. Rename [Shower, ok: Insert, ok.text: "{{answer}} ({{leaf}})"]"#)
        let selection = try XCTUnwrap(config.resolve(path: [0]))
        var context = ActionContext(templatesDirectory: nil)
        context.environment["answer"] = "Grace Hopper"
        let next = try XCTUnwrap(selection.action?.nestedAction("ok"))
        XCTAssertEqual(try ActionPlanner.plan(selection.with(action: next), config: config, context: context).plan,
                       .insertText("Grace Hopper (Rename)"))
    }

    func testAnActionThatNothingRunsIsNoted() throws {
        let (_, compiled) = try compile("1. Idea [Shower, ok: Teleport]")
        let messages = compiled.diagnostics.map(\.message)
        XCTAssertTrue(messages.contains("Nothing here runs “Teleport” actions; ok does nothing."), "\(messages)")
    }

    func testABlockCantSteerAFollowUpEither() throws {
        let (_, compiled) = try compile(#"1. Idea [Shower, ok: Link, ok.url: "https://x.example/?q={{#ai}}pick{{/ai}}"]"#)
        XCTAssertTrue(compiled.diagnostics.contains { $0.message.hasPrefix("{{#ai}} can't go in ok.url") })
    }

    func testTheTextIsWholeTrimmedAndEscapedWhenItsHTML() throws {
        let (config, _) = try compile("""
            1. Show [Shower]
               1. Plain [text: "  Hello {{who}}  \\n"]
               2. Page [template: page.html]
               3. Notes [template: notes.md]
               4. Nothing
            """)
        try "<!DOCTYPE html><p>{{who}}</p>".write(to: folder.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        try "# {{who}}\n\n- one\n".write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let values = ["who": "A & <B>"]
        XCTAssertEqual(try request(config, [0, 0], environment: values).fields["text"], "Hello A & <B>")
        XCTAssertEqual(try request(config, [0, 1], environment: values).fields["text"],
                       "<!DOCTYPE html><p>A &amp; &lt;B&gt;</p>", "a value in HTML stays text")
        XCTAssertEqual(try request(config, [0, 2], environment: values).fields["text"], "# A & <B>\n\n- one")
        XCTAssertEqual(try request(config, [0, 3]).fields["text"], "Nothing", "the label, with nothing else")
    }

    func testWhatCountsAsAnHTMLDocument() {
        XCTAssertTrue(NotesHTML.isDocument("\n  <!doctype html><html></html>"))
        XCTAssertTrue(NotesHTML.isDocument("<HTML><body>x</body></HTML>"))
        XCTAssertTrue(NotesHTML.isDocument(#"<?xml version="1.0" encoding="UTF-8"?><html/>"#))
        XCTAssertTrue(NotesHTML.isDocument(#"<meta charset="utf-8"><p>x</p>"#))
        XCTAssertFalse(NotesHTML.isDocument("# Heading\n<b>bold</b>"))
        XCTAssertFalse(NotesHTML.isDocument("<p>A fragment</p>"))
    }

    func testLinksCanBeKept() {
        XCTAssertEqual(NotesHTML.from(markdown: "See [the docs](https://example.com/a?b=1&c=2)"),
                       "<div>See the docs (https://example.com/a?b=1&amp;c=2)</div>", "Notes keeps the address visible")
        XCTAssertEqual(NotesHTML.from(markdown: "See [the docs](https://example.com/a?b=1&c=2)", links: true),
                       #"<div>See <a href="https://example.com/a?b=1&amp;c=2">the docs</a></div>"#)
    }
}
