@testable import KeybowKit
import XCTest

final class TemplateListsTests: XCTestCase {
    private let invoices = """
        Invoice,Client,Due,Amount,Paid
        A-3,Acme,2026-10-20,"1,200.00",no
        A-1,Bolt,2026-10-02,80.50,yes
        A-2,Crane,2026-10-09,300,no
        """

    private func expand(_ template: String, _ params: [String: String] = [:]) -> Template.Result {
        Template.expand(template, params: params)
    }

    func testEachRowWithHeaderAndFooter() {
        let template = """
            {{#each clipboard}}
            {{#header}}
            | Invoice | Amount |
            |---|---|
            {{/header}}
            | {{Invoice}} | {{Amount}} |
            {{#footer}}
            {{@count}} invoices, {{@sum.Amount}} in all.
            {{/footer}}
            {{/each}}
            """
        let result = expand(template, ["clipboard": invoices])
        XCTAssertEqual(result.text, """
            | Invoice | Amount |
            |---|---|
            | A-3 | 1,200.00 |
            | A-1 | 80.50 |
            | A-2 | 300 |
            3 invoices, 1580.50 in all.

            """)
        XCTAssertEqual(result.missing, [])
        XCTAssertEqual(result.problems, [])
    }

    func testTheLanguageReferencesExample() {
        let template = """
            {{#each clipboard where="Paid = no" sort="Due"}}
            {{#header}}
            | Invoice | Client | Due | Amount |
            |---|---|---|--:|
            {{/header}}
            | {{Invoice}} | {{Client}} | {{Due}} | {{Amount}} |
            {{#footer}}

            {{@count}} unpaid, £{{@sum.Amount}} in all.
            {{/footer}}
            {{#empty}}
            Everything's paid.
            {{/empty}}
            {{/each}}
            """
        let copied = "Invoice\tClient\tDue\tAmount\tPaid\nA-101\tAcme Ltd\t2026-10-20\t1,200.00\tno\n"
            + "A-102\tBolt & Co\t2026-10-02\t80.50\tyes\nA-103\tCrane plc\t2026-10-09\t300.00\tno\n"
        XCTAssertEqual(expand(template, ["clipboard": copied]).text, """
            | Invoice | Client | Due | Amount |
            |---|---|---|--:|
            | A-103 | Crane plc | 2026-10-09 | 300.00 |
            | A-101 | Acme Ltd | 2026-10-20 | 1,200.00 |

            2 unpaid, £1500.00 in all.

            """)
        XCTAssertEqual(expand(template, ["clipboard": "Invoice\tPaid\nA-1\tyes"]).text, "Everything's paid.\n")
    }

    func testWhereSortAndLimit() {
        let template = #"{{#each clipboard where="Paid = no" sort="Due desc" separator=", "}}{{Invoice}}{{/each}}"#
        XCTAssertEqual(expand(template, ["clipboard": invoices]).text, "A-3, A-2")
        XCTAssertEqual(expand(#"{{#each clipboard where="Amount > 100 and Client ~ cr"}}{{Invoice}}{{/each}}"#,
                              ["clipboard": invoices]).text, "A-2", "numbers compared as numbers; ~ is contains")
        XCTAssertEqual(expand("{{#each clipboard sort=Amount limit=2 separator=' '}}{{Invoice}}{{/each}}",
                              ["clipboard": invoices]).text, "A-1 A-2")
        XCTAssertEqual(expand("{{#each clipboard where='Client != acme' separator=' '}}{{Client}}{{/each}}",
                              ["clipboard": invoices]).text, "Bolt Crane", "= and != ignore case")
    }

    func testWhereTakesValuesFromTheKey() {
        let template = "{{#each clipboard where='Client = {{leaf}}'}}{{Invoice}}{{/each}}"
        XCTAssertEqual(expand(template, ["clipboard": invoices, "leaf": "Bolt"]).text, "A-1")
    }

    func testEmptyWhenNoRows() {
        let template = "{{#each clipboard where='Paid = maybe'}}{{#header}}H{{/header}}{{Invoice}}{{#empty}}None.{{/empty}}{{/each}}"
        XCTAssertEqual(expand(template, ["clipboard": invoices]).text, "None.")
        XCTAssertEqual(expand("[{{#each clipboard}}{{1}}{{/each}}]", ["clipboard": ""]).text, "[]")
    }

    func testRowNumbersAndTheWholeRow() {
        let template = "{{#each clipboard}}{{@number}}/{{@count}} {{@row}}\n{{/each}}"
        XCTAssertEqual(expand(template, ["clipboard": "a\tb\n1\t2\n3\t4"]).text, "1/2 1\t2\n2/2 3\t4\n")
        XCTAssertEqual(expand("{{#each clipboard}}{{#header}}{{@columns}}{{/header}}{{/each}}",
                              ["clipboard": "a\tb\n1\t2"]).text, "a\tb")
    }

    func testAggregates() {
        let rows = ["clipboard": "Day,Miles\nMon,3.5\nTue,\nWed,10"]
        XCTAssertEqual(expand("{{#each clipboard}}{{#footer}}{{@sum.Miles}} {{@average.Miles}} {{@min.Miles}} {{@max.Miles}}{{/footer}}{{/each}}",
                              rows).text, "13.5 6.75 3.5 10")
    }

    func testOuterValuesAndFallbacksInsideRows() {
        let template = "{{#each clipboard separator='; '}}{{Name}} for {{leaf}}: {{Note|none}}{{/each}}"
        XCTAssertEqual(expand(template, ["clipboard": "Name,Note\nAnn,\nBob,ok", "leaf": "Standup"]).text,
                       "Ann for Standup: none; Bob for Standup: ok")
    }

    func testAColumnNameNotThereIsMissing() {
        let result = expand("{{#each clipboard}}{{Nmae}}{{/each}}", ["clipboard": "Name\tAge\nAnn\t31"])
        XCTAssertEqual(result.missing, ["Nmae"])
    }

    func testAMissingSourceIsMissing() {
        let result = expand("[{{#each selection}}{{1}}{{#empty}}none{{/empty}}{{/each}}]")
        XCTAssertEqual(result.missing, ["selection"])
        XCTAssertEqual(result.text, "[]", "not {{#empty}}: there's nothing, not a list of none")
    }

    func testNestedListsFromJSON() {
        let json = #"[{"name": "Ann", "pets": [{"kind": "cat"}, {"kind": "dog"}]}, {"name": "Bob", "pets": []}]"#
        let template = "{{#each api.people.raw}}{{name}}: {{#each pets separator=', '}}{{kind}}{{#empty}}none{{/empty}}{{/each}}\n{{/each}}"
        XCTAssertEqual(expand(template, ["api.people.raw": json]).text, "Ann: cat, dog\nBob: none\n")
    }

    func testModuleRowsComeFirst() {
        let template = "{{#each api.issues separator=' '}}#{{number}}{{/each}}"
        let params = ["api.issues": "joined, as text", Template.rowsKey(for: "api.issues"): #"[{"number": 4}, {"number": 9}]"#]
        XCTAssertEqual(expand(template, params).text, "#4 #9")
    }

    func testColumnsAndFormat() {
        XCTAssertEqual(expand("{{#each clipboard columns='Who, Age' separator=' '}}{{Who}}{{/each}}",
                              ["clipboard": "Ann,31\nBob,40"]).text, "Ann Bob")
        XCTAssertEqual(expand("{{#each clipboard columns=none separator=' '}}{{2}}{{/each}}",
                              ["clipboard": "Ann\t31\nBob\t40"]).text, "31 40")
        XCTAssertEqual(expand("{{#each clipboard format=lines separator='|'}}{{1}}{{/each}}",
                              ["clipboard": "a,b\nc,d"]).text, "a,b|c,d")
    }

    func testUnreadableRowsAreAProblem() {
        let result = expand("{{#each clipboard format=json}}{{1}}{{/each}}", ["clipboard": "not json"])
        XCTAssertEqual(result.problems, ["{{clipboard}} can't be read as json: It isn't JSON that can be read."])
        let unknown = expand("{{#each clipboard where='Colour = red'}}{{1}}{{/each}}", ["clipboard": "Name\tAge\nAnn\t31"])
        XCTAssertEqual(unknown.problems, ["The rows of {{clipboard}} have no column “Colour” to choose by: they have Name, Age."])
    }

    func testTagsAloneOnTheirLinesTakeTheLine() {
        let template = "Team:\n  {{#each clipboard}}\n- {{1}}\n  {{/each}}\nEnd"
        XCTAssertEqual(expand(template, ["clipboard": "Ann\nBob"]).text, "Team:\n- Ann\n- Bob\nEnd")
        XCTAssertEqual(expand("x {{#each clipboard}}{{1}} {{/each}}y", ["clipboard": "Ann"]).text, "x Ann y",
                       "not when they share a line")
    }

    func testBlocksInsideRowsAreAskedForEachRow() {
        var asked: [String] = []
        let result = Template.expand("{{#each clipboard separator=' / '}}{{#ai}}Describe {{Name}}{{/ai}}{{/each}}",
                                     params: ["clipboard": "Name\tAge\nAnn\t31\nBob\t40"],
                                     standIn: { call in asked.append(call.body); return "‹\(call.body)›" })
        XCTAssertEqual(asked, ["Describe Ann", "Describe Bob"])
        XCTAssertEqual(result.text, "‹Describe Ann› / ‹Describe Bob›")
    }

    func testAListInsideABlockIsSentAsText() async throws {
        let template = "{{#ai}}Summarise:\n{{#each clipboard}}\n- {{1}}\n{{/each}}\n{{/ai}}"
        let replies = try await TemplateBlocks.resolve([template], params: ["clipboard": "Ann\nBob"]) { call in
            "reply to " + call.body
        }
        XCTAssertEqual(replies.values.first, "reply to Summarise:\n- Ann\n- Bob\n")
        XCTAssertEqual(Template.expand(template, params: ["clipboard": "Ann\nBob"], blocks: replies).text,
                       "reply to Summarise:\n- Ann\n- Bob\n")
    }

    func testValuesPlacedInALinkAreEncodedButNotTheTemplatesOwnText() {
        let result = Template.expand("https://x.test/?q={{#each clipboard separator='+'}}{{1}}{{/each}}",
                                     params: ["clipboard": "a b\nc&d"], encode: Template.linkEncoded)
        XCTAssertEqual(result.text, "https://x.test/?q=a%20b+c%26d")
    }

    func testPreviewsShowOneRowOfStandIns() {
        let template = "{{#each clipboard}}{{#header}}H{{/header}}{{Name}} {{leaf}} {{@number}}{{#footer}} {{@sum.Amount}}{{/footer}}{{/each}}"
        XCTAssertEqual(expand(template, ["clipboard": "‹clipboard›", "leaf": "Standup"]).text,
                       "H‹Name› Standup 1 ‹total of Amount›")
    }

    // MARK: - Reading the tag

    func testNamesIncludeTheSourceAndAttributes() {
        let template = "{{#each api.wikipedia term={{selection}} where='Owner = {{leaf}}'}}{{title}}{{/each}}"
        XCTAssertEqual(Template.names(in: template), ["api.wikipedia term={{selection}}", "leaf", "title"])
        XCTAssertEqual(Template.listSources(in: template), ["api.wikipedia term={{selection}}"])
        XCTAssertEqual(Template.listSources(in: "{{#each file='team.csv'}}{{/each}}"), ["file name='team.csv'"])
        XCTAssertEqual(TemplateBlocks.names(insideBlocks: "ai", in: "{{#ai}}{{#each clipboard}}{{x}}{{/each}}{{/ai}}"),
                       ["clipboard", "x"])
    }

    func testListsAreNotBlocks() {
        XCTAssertFalse(TemplateBlocks.contains("{{#each clipboard}}{{1}}{{/each}}"))
        XCTAssertEqual(TemplateBlocks.names(in: "{{#each clipboard}}{{#ai}}x{{/ai}}{{/each}}"), ["ai"])
    }

    func testProblemsWithTheTag() {
        XCTAssertEqual(TemplateBlocks.problems(in: "{{#each}}x{{/each}}"),
                       ["“{{#each}}” needs something to go through: {{#each clipboard}}, or {{#each file='rows.csv'}}."])
        XCTAssertEqual(TemplateBlocks.problems(in: "{{#each clipboard limit=lots}}{{/each}}"),
                       ["“{{#each}}”'s limit is a number of rows, not “lots”."])
        XCTAssertEqual(TemplateBlocks.problems(in: "{{#each clipboard format=xlsx}}{{/each}}"),
                       ["“{{#each}}”'s format is csv, tsv, json, markdown, lines, not “xlsx”."])
        XCTAssertEqual(TemplateBlocks.problems(in: "{{#header}}x{{/header}}"),
                       ["“{{#header}}” goes inside {{#each}}…{{/each}}.", "“{{/header}}” doesn't close anything."])
        XCTAssertEqual(TemplateBlocks.problems(in: "{{#each clipboard}}x"), ["“{{#each}}” is never closed with {{/each}}."])
        XCTAssertEqual(TemplateBlocks.problems(in: "{{#each a b}}{{/each}}"), ["“{{#each}}” goes through one thing: “a” or “b”?"])
    }

    func testEditorTags() {
        let text = "{{#each clipboard where='A = {{leaf}}'}}{{Name}}{{#footer}}{{@count}}{{/footer}}{{/each}}"
        let tags = TemplateSyntax.tags(in: text)
        let source = tags.first { $0.isListSource }
        XCTAssertEqual(source?.name, "clipboard")
        XCTAssertEqual(source.map { (text as NSString).substring(with: $0.range) }, "clipboard")
        XCTAssertEqual(tags.filter { $0.kind == .blockOpening }.map(\.name), ["each", "footer"])
        XCTAssertEqual(tags.filter { $0.kind == .value && !$0.isListSource }.map { "\($0.name) \($0.inList)" },
                       ["leaf false", "Name true", "@count true"])
    }
}

final class MarkdownTableTests: XCTestCase {
    func testATableForWhatsPastedOrShown() {
        let html = NotesHTML.from(markdown: "Team:\n| Name | Score |\n|:--|--:|\n| **Ann** | 3 |\n| Bob |\nAfter", tables: true)
        let cell = "border: 1px solid #b8b8b8; padding: 3px 8px; text-align: "
        XCTAssertEqual(html, "<div>Team:</div>"
            + "<table style=\"border-collapse: collapse\"><thead><tr><th style=\"\(cell)left\">Name</th>"
            + "<th style=\"\(cell)right\">Score</th></tr></thead><tbody>"
            + "<tr><td style=\"\(cell)left\"><b>Ann</b></td><td style=\"\(cell)right\">3</td></tr>"
            + "<tr><td style=\"\(cell)left\">Bob</td><td style=\"\(cell)right\"></td></tr></tbody></table>"
            + "<div>After</div>")
        XCTAssertTrue(PasteboardText.isFormatted(html))
    }

    func testNotesGetsTheLinesAsWritten() {
        XCTAssertEqual(NotesHTML.from(markdown: "| A |\n|---|\n| 1 |"), "<div>| A |</div><div>|---|</div><div>| 1 |</div>")
    }

    func testARuleWithoutBarsIsntATable() {
        XCTAssertFalse(NotesHTML.from(markdown: "a | b\n---", tables: true).contains("<table"))
    }
}

final class ListCheckingTests: XCTestCase {
    private let catalog = ValueCatalog(modules: [])

    private func messages(_ text: String, in place: TemplatePlace = .file) -> [String] {
        catalog.check(text, in: place).map(\.message)
    }

    func testColumnsArentFlaggedButTheSourceIs() {
        XCTAssertEqual(messages("{{#each clipboard}}{{Name}} {{@count}}{{/each}}"), [])
        XCTAssertEqual(messages("{{#each clipbord}}{{Name}}{{/each}}"), ["Nothing here gives {{clipbord}}, so it'll be missing."])
        XCTAssertEqual(messages("{{#each clipboard}}{{#each tags}}{{1}}{{/each}}{{/each}}"), [], "a column's list")
    }

    func testAListsOwnValues() {
        XCTAssertEqual(messages("{{@count}}"), ["{{@count}} is a list's own: it goes inside {{#each}}…{{/each}}."])
        XCTAssertEqual(messages("{{#each clipboard}}{{@sum.Amount}}{{@nmber}}{{/each}}").count, 1)
    }

    func testAttributesAndPlaces() {
        XCTAssertEqual(messages("{{#each clipboard order=Due}}{{/each}}"),
                       ["{{#each}} doesn't take “order”: it takes file, where, sort, limit, separator, columns and format."])
        XCTAssertEqual(messages("{{#each clipboard}}{{1}}{{/each}}", in: .field("url")), [], "a list isn't a reply")
        XCTAssertEqual(messages("{{#each clipboard}}{{1}}{{/each}}", in: .value),
                       ["A list in a value isn't filled in: it's kept as written."])
    }

    func testCompletionOffersAListsValues() {
        XCTAssertEqual(TemplateSyntax.partialName(in: "{{#each x}}{{@c", at: 15)?.range.length, 2)
        XCTAssertEqual(catalog.completions(for: "@c", block: false), ["@count", "@columns"])
        XCTAssertTrue(catalog.completions(for: "ea", block: true).contains("each"))
    }
}
