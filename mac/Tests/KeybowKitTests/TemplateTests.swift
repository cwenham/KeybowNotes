import XCTest
@testable import KeybowKit

final class TemplateTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    /// Saturday 26 September 2026, 14:07.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 14, minute: 7))!
    }

    private func expand(_ text: String, _ params: [String: String] = [:]) -> Template.Result {
        Template.expand(text, params: params, now: now, calendar: calendar, locale: Locale(identifier: "en_GB"))
    }

    func testParameters() {
        XCTAssertEqual(expand("{{leaf}} in {{ parent }}", ["leaf": "Milk", "parent": "Groceries"]).text, "Milk in Groceries")
    }

    func testMissingValuesAreReportedOnce() {
        let result = expand("to {{contact.phone}} and {{contact.phone}}", ["contact.name": "Alex"])
        XCTAssertEqual(result.text, "to  and ")
        XCTAssertEqual(result.missing, ["contact.phone"])
    }

    func testEmptyCountsAsMissing() {
        XCTAssertEqual(expand("{{contact.phone}}", ["contact.phone": ""]).missing, ["contact.phone"])
    }

    func testFallbacks() {
        XCTAssertEqual(expand("{{clipboard|New task}}").text, "New task")
        let empty = expand("[{{project.path|}}]")
        XCTAssertEqual(empty.text, "[]")
        XCTAssertEqual(empty.missing, [], "an empty fallback means missing is fine")
    }

    func testDateBuiltIns() {
        XCTAssertEqual(expand("{{date}}").text, "26 Sep 2026")
        XCTAssertEqual(expand("{{date:yyyy-MM-dd}}").text, "2026-09-26")
        XCTAssertEqual(expand("{{time}}").text, "14:07")
        XCTAssertEqual(expand("{{weekday}}").text, "Saturday")
        XCTAssertEqual(expand("week {{isoWeek}}").text, "week 39")
    }

    func testUnclosedBraceIsLeftAlone() {
        XCTAssertEqual(expand("a {{b").text, "a {{b")
    }

    // MARK: - Summaries

    private func summary(_ json: String, path: [Int], tree: TreeKind = .main) throws -> ActionSummary {
        let config = try KeybowConfig.parse(Data(json.utf8))
        let selection = try XCTUnwrap(config.resolve(tree: tree, path: path))
        return ActionSummary(selection: selection, config: config, now: now, calendar: calendar)
    }

    func testEventSummaryResolvesTheDate() throws {
        let result = try summary("""
        { "tree": [ { "label": "Meeting", "action": { "type": "calendar.createEvent", "alertMinutes": 5 },
                      "children": [ { "label": "Tomorrow", "params": { "when": "tomorrow" } } ] } ] }
        """, path: [0, 0])
        XCTAssertEqual(result.verb, "New event")
        XCTAssertEqual(result.subject, "Meeting")
        XCTAssertEqual(result.details, ["Sun 27 Sep, 09:00", "alert 5 min before"])
        XCTAssertEqual(result.missing, [])
    }

    func testNoteSummaryShowsTheFolder() throws {
        let result = try summary("""
        { "tree": [ { "label": "Ideas", "children": [ { "label": "Inventions" } ] } ] }
        """, path: [0, 0])
        XCTAssertEqual(result.verb, "New note")
        XCTAssertEqual(result.subject, "Inventions — 26 Sep 2026")
        XCTAssertEqual(result.details, ["in Ideas/Inventions"])
    }

    func testMessageSummaryFlagsAMissingNumber() throws {
        let result = try summary("""
        { "contacts": { "Sam Sample": { "phone": "", "email": "sam@example.com" } },
          "tree": [ { "label": "Message", "action": { "type": "messages.compose" },
                      "children": [ { "label": "Sam Sample" } ] } ] }
        """, path: [0, 0])
        XCTAssertEqual(result.subject, "Sam Sample")
        XCTAssertEqual(result.missing, ["contact.phone"])
    }

    func testShortcutNameFromThePath() throws {
        let result = try summary("""
        { "trees": { "bottom": [ { "label": "Home", "action": { "type": "shortcut", "name": "{{level2}} {{level3}} {{leaf}}" },
            "children": [ { "label": "Lights", "children": [ { "label": "Kitchen", "children": [ { "label": "Off" } ] } ] } ] } ] } }
        """, path: [0, 0, 0, 0], tree: .bottom)
        XCTAssertEqual(result.verb, "Run shortcut")
        XCTAssertEqual(result.subject, "Lights Kitchen Off")
    }
}
