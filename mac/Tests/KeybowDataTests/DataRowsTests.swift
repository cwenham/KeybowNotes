@testable import KeybowData
import KeybowKit
import XCTest

/// A data source's findings as rows, for `{{#each api.issues}}`.
final class DataRowsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let issues = #"{"total": 2, "items": [{"number": 7, "title": "Fix login", "user": {"login": "ann"}},"#
        + #" {"number": 9, "title": "Ship it", "user": {"login": "bob"}}]}"#

    private func source(_ rule: ExtractionRule?) -> DataSource {
        var source = DataSource(name: "issues", url: "https://api.example.com/issues")
        source.rule = rule
        source.wanted = "Each open issue"
        return source
    }

    private func registry(_ rule: ExtractionRule?, body: String, contentType: String = "application/json")
        -> (ModuleRegistry, StubDataTransport) {
        let transport = StubDataTransport()
        transport.body = Data(body.utf8)
        transport.contentType = contentType
        let data = DataModule(fetcher: DataFetcher(transport: transport))
        data.openWindow = nil
        let registry = ModuleRegistry()
        registry.register(data, host: MemoryModuleHost())
        data.save(source(rule))
        return (registry, transport)
    }

    func testEachThingTheRuleFindsIsARow() async throws {
        let (registry, transport) = registry(ExtractionRule(kind: .jsonPath, expression: "$.items[*]"), body: issues)
        let template = "{{#each api.issues separator='; '}}#{{number}} {{title}} ({{user.login}}){{/each}}, {{api.issues.raw|}}"
        let names = registry.fetchedNames(in: Template.names(in: template))
        XCTAssertEqual(names, ["api.issues", "api.issues.raw"])
        let values = try await registry.fetch(names, params: [:], now: now, rows: Template.listSources(in: template))
        XCTAssertEqual(transport.requests.count, 1, "one response, for the rows and the raw value")
        let text = Template.expand("{{#each api.issues separator='; '}}#{{number}} {{title}} ({{user.login}}){{/each}}",
                                   params: values).text
        XCTAssertEqual(text, "#7 Fix login (ann); #9 Ship it (bob)")
    }

    func testFindingNothingIsAnEmptyListNotABrokenRule() async throws {
        let (registry, _) = registry(ExtractionRule(kind: .jsonPath, expression: "$.items[*]"), body: #"{"items": []}"#)
        let values = try await registry.fetch(["api.issues"], params: [:], now: now, rows: ["api.issues"])
        XCTAssertEqual(Template.expand("{{#each api.issues}}x{{#empty}}No issues.{{/empty}}{{/each}}", params: values).text,
                       "No issues.")
        let data = try XCTUnwrap(registry.module(id: DataModule.id) as? DataModule)
        XCTAssertNil(data.source(named: "issues")?.broken)
    }

    func testXMLElementsAreRowsOfTheirChildrenAndAttributes() throws {
        let feed = #"<rss><channel><item id="1"><title>One</title><link>https://a.test/1</link></item>"#
            + #"<item id="2"><title>Two</title><link>https://a.test/2</link></item></channel></rss>"#
        let rows = try ExtractionRule(kind: .xPath, expression: "//item").rows(in: Data(feed.utf8), contentType: "application/xml")
        let table = try DataTable.read(rows)
        XCTAssertEqual(table.columns, ["id", "link", "title"])
        XCTAssertEqual(table.rows.map(\.cells), [["1", "https://a.test/1", "One"], ["2", "https://a.test/2", "Two"]])
    }

    func testRegularExpressionGroupsAreColumns() throws {
        let text = "Paris 21C\nOslo 9C"
        let rows = try ExtractionRule(kind: .regex, expression: #"(?<city>\w+) (\d+)C"#).rows(in: Data(text.utf8))
        let table = try DataTable.read(rows)
        XCTAssertEqual(table.cell(1, "city"), "Oslo")
        XCTAssertEqual(table.cell(0, "2"), "21")
        let plain = try DataTable.read(try ExtractionRule(kind: .regex, expression: #"\d+"#).rows(in: Data(text.utf8)))
        XCTAssertEqual(plain.rows.map(\.cells), [["21"], ["9"]])
    }

    func testARawResponseIsReadAsRowsWithoutARule() async throws {
        let (registry, _) = registry(nil, body: "name,age\nAnn,31\nBob,40", contentType: "text/csv")
        let values = try await registry.fetch(["api.issues.raw"], params: [:], now: now, rows: ["api.issues.raw"])
        XCTAssertEqual(Template.expand("{{#each api.issues.raw separator=' '}}{{name}}{{/each}}", params: values).text,
                       "Ann Bob")
    }
}
