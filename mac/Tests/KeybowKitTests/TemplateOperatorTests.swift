@testable import KeybowKit
import XCTest

final class TemplateOperatorTests: XCTestCase {
    func testAnOperatorIsNamedWholeAttributesAndAll() {
        let names = Template.names(in: """
            {{quote file="quotes.md" heading="Note: {{leaf}}"}} — {{date:HH:mm}} {{selection|}}
            """)
        XCTAssertEqual(names, [#"quote file="quotes.md" heading="Note: {{leaf}}""#, "date", "selection"])
    }

    func testItsAttributesAreRead() throws {
        let call = try XCTUnwrap(Template.operatorCall(#"quote file='my quotes.md' order=sequential heading="{{leaf}}""#))
        XCTAssertEqual(call.name, "quote")
        XCTAssertEqual(call.attributes, ["file": "my quotes.md", "order": "sequential", "heading": "{{leaf}}"])
        XCTAssertNil(Template.operatorCall("quote"))
        XCTAssertNil(Template.operatorCall("contact.phone"))
    }

    func testItsValueAndFallback() {
        let name = #"quote file="a|b.txt""#
        let template = #"Today: {{quote file="a|b.txt"|nothing today}}"#
        XCTAssertEqual(Template.names(in: template), [name], "a | inside quotes isn't the fallback's")
        XCTAssertEqual(Template.expand(template, params: [name: "Carpe diem"]).text, "Today: Carpe diem")
        XCTAssertEqual(Template.expand(template, params: [:]).text, "Today: nothing today")
        let missing = Template.expand(#"{{quote file="x.txt"}}"#, params: [:])
        XCTAssertEqual(missing.missing, [#"quote file="x.txt""#])
    }

    func testClosingBracesInsideQuotesDontEndIt() {
        let template = #"{{quote file="q.md" heading="{{leaf}}"}} and {{leaf}}"#
        XCTAssertEqual(Template.names(in: template), [#"quote file="q.md" heading="{{leaf}}""#, "leaf"])
        let expanded = Template.expand(template, params: [#"quote file="q.md" heading="{{leaf}}""#: "Q", "leaf": "Stoics"])
        XCTAssertEqual(expanded.text, "Q and Stoics")
    }

    func testAnUnclosedQuoteIsReported() {
        let result = Template.expand(#"{{quote file="q.md}} rest"#, params: [:])
        XCTAssertEqual(result.problems, ["“{{quote” has no closing }} — check its quotes."])
    }

    func testPlainPlaceholdersReadAsBefore() {
        XCTAssertEqual(Template.expand("{{selection|don't know}} {{x}}", params: ["x": "y"]).text, "don't know y",
                       "an apostrophe in a fallback isn't a quote")
        XCTAssertEqual(Template.names(in: "{{contact.phone|none}} {{date:d MMM}}"), ["contact.phone", "date"])
        XCTAssertEqual(Template.expand(#"{{title|"five minutes"}}"#, params: [:]).text, "five minutes")
    }

    func testItsModuleIsFoundByTheFirstWord() {
        let registry = ModuleRegistry()
        final class Quotes: KeybowModule, @unchecked Sendable {
            let manifest = ModuleManifest(id: "quote", name: "Quotes", fetches: ["quote"])
            func start(host: ModuleHost) {}
            func summary(of request: ModuleRequest, now: Date) -> ModuleSummary { ModuleSummary(verb: "", subject: "") }
            func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome { .failure("") }
        }
        registry.register(Quotes(), host: MemoryModuleHost())
        XCTAssertEqual(registry.module(fetching: #"quote file="q.md""#)?.manifest.id, "quote")
        XCTAssertEqual(registry.module(fetching: "quote")?.manifest.id, "quote")
        XCTAssertNil(registry.module(fetching: "quotes"))
    }
}
