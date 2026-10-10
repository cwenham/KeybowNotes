@testable import KeybowKit
import XCTest

/// A template's tags, where they are, and what's wrong with them: what the
/// tree editor colours, explains and marks.
final class TemplateSyntaxTests: XCTestCase {
    private let catalog = ValueCatalog(modules: [Checked()])

    private func text(_ range: NSRange, of text: String) -> String {
        (text as NSString).substring(with: range)
    }

    // MARK: - Tags

    func testEachTagWhereItIs() {
        let template = "Hi {{ leaf }}, {{date:EEEE|today}} {{#ai model=sonnet-5}}Sum up {{selection}}{{/ai}}"
        let tags = TemplateSyntax.tags(in: template)
        XCTAssertEqual(tags.map(\.kind), [.value, .value, .blockOpening, .value, .blockClosing])
        XCTAssertEqual(tags.map(\.name), ["leaf", "date", "ai", "selection", "ai"])
        XCTAssertEqual(tags.map { text($0.range, of: template) },
                       ["{{ leaf }}", "{{date:EEEE|today}}", "{{#ai model=sonnet-5}}", "{{selection}}", "{{/ai}}"])
        XCTAssertEqual(tags.map { text($0.nameRange, of: template) }, ["leaf", "date", "ai", "selection", "ai"])
        XCTAssertEqual(tags[1].format, "EEEE")
        XCTAssertEqual(tags[1].fallback, "today")
        XCTAssertNil(tags[0].fallback)
        XCTAssertEqual(tags[2].attributes, ["model": "sonnet-5"])
    }

    func testTagsInsideACallsAttributes() {
        let template = "{{api.wikipedia term={{selection}}|none}}"
        let tags = TemplateSyntax.tags(in: template)
        XCTAssertEqual(tags.map(\.kind), [.call, .value])
        XCTAssertEqual(tags[0].name, "api.wikipedia")
        XCTAssertEqual(tags[0].attributes, ["term": "{{selection}}"])
        XCTAssertEqual(tags[0].fallback, "none")
        XCTAssertEqual(text(tags[0].range, of: template), template)
        XCTAssertEqual(text(tags[1].range, of: template), "{{selection}}")
    }

    func testPlacesCountAsTextViewsDo() {
        let template = "🙂 ünïcode {{leaf}}"
        let tag = TemplateSyntax.tags(in: template)[0]
        XCTAssertEqual(tag.range, NSRange(location: 11, length: 8), "in UTF-16, as NSString counts")
        XCTAssertEqual(text(tag.nameRange, of: template), "leaf")
    }

    func testProblemsWhereTheyAre() {
        let template = "{{#ai}}never closed, and {{/reply}}"
        let problems = TemplateSyntax.problems(in: template)
        XCTAssertEqual(problems.map { text($0.range, of: template) }, ["{{/reply}}", "{{#ai}}"])
        XCTAssertEqual(problems.map(\.severity), [.error, .error])
        XCTAssertEqual(TemplateSyntax.problems(in: "{{quote file='q.md}} and on").map { text($0.range, of: "{{quote file='q.md}} and on") },
                       ["{{quote file='q.md}} and on"], "quotes left open, to the end")
    }

    // MARK: - Checking

    private func check(_ text: String, _ place: TemplatePlace = .field("title"), in catalog: ValueCatalog? = nil)
        -> [String] {
        (catalog ?? self.catalog).check(text, in: place).map { "\($0.severity == .error ? "error" : "warning"): \($0.message)" }
    }

    func testWhatsRightPasses() {
        XCTAssertEqual(check("{{leaf}} at {{time:HH:mm}}, {{contact.phone|none}} {{#reply}}{{selection}}{{/reply}}"), [])
        XCTAssertEqual(check("no tags at all"), [])
    }

    func testANameNothingGives() {
        XCTAssertEqual(check("{{lefa}}"), ["warning: Nothing here gives {{lefa}}, so it'll be missing."])
        XCTAssertEqual(check("{{lefa|}}"), ["warning: Nothing here gives {{lefa}}, so its fallback is always used."])
        let issue = catalog.check("Hi {{ lefa }}", in: .value)[0]
        XCTAssertEqual(text(issue.range, of: "Hi {{ lefa }}"), "lefa", "the name, marked")
    }

    func testWhereBlocksMayGo() {
        let blocked = "error: A block can't go in url: a reply mustn't choose a link, a number or an app."
        XCTAssertEqual(check("https://x.com/?q={{#reply}}{{leaf}}{{/reply}}", .field("url")), [blocked])
        XCTAssertEqual(check("{{#reply}}x{{/reply}}", .field("ok.url")),
                       ["error: A block can't go in ok.url: a reply mustn't choose a link, a number or an app."])
        XCTAssertEqual(check("{{#reply}}x{{/reply}}", .value), ["warning: A block in a value doesn't run: it's kept as written."])
        XCTAssertEqual(check("{{#reply}}x{{/reply}}", .file), [])
        XCTAssertEqual(check("{{#ask}}x{{/ask}}"), ["error: Nothing here replies to {{#ask}}."])
    }

    func testWhatACallTakes() {
        XCTAssertEqual(check("{{lines order=random}}"), ["error: {{lines}} needs file=…."])
        XCTAssertEqual(check("{{lines}}"), ["error: {{lines}} needs file=…."], "even written as a name")
        XCTAssertEqual(check("{{lines file=q.md colour=red}}"),
                       ["warning: {{lines}} doesn't take “colour”: it takes file and order."])
        XCTAssertEqual(check("{{#reply tone=dry}}x{{/reply}}"), ["warning: {{#reply}} doesn't take “tone”: it takes nothing."])
    }

    func testFormatsAreForDates() {
        XCTAssertEqual(check("{{date:EEEE}} {{datetime:yyyy}}"), [])
        XCTAssertEqual(check("{{leaf:EEEE}}"),
                       ["warning: Only dates and times take a format: {{leaf:…}} is read as a name of its own, and missing."])
    }

    func testAFamilyListedByNameKnowsOnlyItsMembers() {
        XCTAssertEqual(check("{{test.weather}} {{test.weather.raw}}"), [])
        XCTAssertEqual(check("{{test.wether}}"), ["warning: Nothing here gives {{test.wether}}, so it'll be missing."])
        XCTAssertEqual(check("{{test.wether.raw}}"), ["warning: Nothing here gives {{test.wether.raw}}, so it'll be missing."])
    }

    func testProblemsComeFirstInPlace() {
        XCTAssertEqual(check("{{lefa}} {{#reply}}open"), [
            "warning: Nothing here gives {{lefa}}, so it'll be missing.",
            "error: “{{#reply}}” is never closed with {{/reply}}.",
        ])
    }

    // MARK: - At a key

    func testABranchKnowsWhatItsKeysSet() throws {
        let outline = """
            1. Meeting [Calendar, start: "{{when}}"]
               1. Today [when: today]
               2. Tomorrow [when: tomorrow]
               3. Later [@later]
            # list later
            1. Friday [when: friday]
            2. Next week [when: next week]
            """
        let config = try XCTUnwrap(OutlineCompiler.compile(OutlineParser.parse(outline).0, locateApp: { _ in nil }).config)
        let meeting = catalog.atKey(try XCTUnwrap(config.resolve(path: [0])), config: config)
        let when = try XCTUnwrap(meeting.entry(named: "when"))
        XCTAssertEqual(when.group, "Set below")
        XCTAssertTrue(when.help.hasPrefix("Set on keys under it: "), when.help)
        XCTAssertTrue(when.help.hasSuffix(" and 2 more. Each key has its own."), "a list's keys too: \(when.help)")
        XCTAssertEqual(meeting.check("{{when}}", in: .field("start")), [])
        XCTAssertNotEqual(catalog.check("{{when}}", in: .field("start")), [], "nowhere else")
    }
}

/// A block, a call that needs a file, and a family whose members are listed.
private final class Checked: KeybowModule, @unchecked Sendable {
    let manifest = ModuleManifest(
        id: "test", name: "Checked", blocks: [ModuleBlockType(name: "reply", title: "Test")], fetches: ["test"],
        values: [
            ValueEntry("reply", title: "Reply", help: "", kind: .block),
            ValueEntry("lines", title: "Lines", help: "", kind: .call,
                       attributes: [ValueAttribute("file", help: "", required: true), ValueAttribute("order", help: "")]),
            ValueEntry("test.<source>", title: "Any", help: "", fetched: true, membersListed: true),
            ValueEntry("test.<source>.raw", title: "Raw", help: "", fetched: true, membersListed: true),
        ])

    func start(host: ModuleHost) {}
    func summary(of request: ModuleRequest, now: Date) -> ModuleSummary { ModuleSummary(verb: "", subject: "") }
    func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome { .failure("") }
    func namedValues() -> [ValueEntry] { [ValueEntry("test.weather", title: "weather", help: "", fetched: true)] }
}
