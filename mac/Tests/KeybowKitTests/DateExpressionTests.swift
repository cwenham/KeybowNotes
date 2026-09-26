import XCTest
@testable import KeybowKit

final class DateExpressionTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    /// Saturday 26 September 2026, 14:07.
    private var now: Date {
        date(2026, 9, 26, 14, 7)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func resolve(_ text: String, rules: DateRules = DateRules()) -> Date? {
        DateExpression.resolve(text, now: now, rules: rules, calendar: calendar)
    }

    // The defaults agreed for the calendar leaves.

    func testTodayIsHalfAnHourAwayRoundedUp() {
        XCTAssertEqual(resolve("today"), date(2026, 9, 26, 14, 40))    // 14:37 → 14:40
        XCTAssertEqual(resolve("Today"), date(2026, 9, 26, 14, 40), "case does not matter")
    }

    func testOtherDaysStartAtNine() {
        XCTAssertEqual(resolve("tomorrow"), date(2026, 9, 27, 9, 0))
        XCTAssertEqual(resolve("next week"), date(2026, 10, 3, 9, 0))
        XCTAssertEqual(resolve("next month"), date(2026, 10, 26, 9, 0))
    }

    // Everything else.

    func testTimesCanBeGiven() {
        XCTAssertEqual(resolve("tomorrow 14:30"), date(2026, 9, 27, 14, 30))
        XCTAssertEqual(resolve("tomorrow at 2:30pm"), date(2026, 9, 27, 14, 30))
        XCTAssertEqual(resolve("today 16:15"), date(2026, 9, 26, 16, 15))
        XCTAssertEqual(resolve("16:15"), date(2026, 9, 26, 16, 15), "a time alone means today")
    }

    func testWeekdaysMeanTheNextOneAfterToday() {
        XCTAssertEqual(resolve("friday"), date(2026, 10, 2, 9, 0))
        XCTAssertEqual(resolve("next fri"), date(2026, 10, 2, 9, 0))
        // Today is Saturday: "saturday" is next week's, never today's.
        XCTAssertEqual(resolve("saturday"), date(2026, 10, 3, 9, 0))
        XCTAssertEqual(resolve("monday 10:00"), date(2026, 9, 28, 10, 0))
    }

    func testOffsets() {
        XCTAssertEqual(resolve("+90m"), date(2026, 9, 26, 15, 37), "exact, not rounded")
        XCTAssertEqual(resolve("+2h"), date(2026, 9, 26, 16, 7))
        XCTAssertEqual(resolve("+2d"), date(2026, 9, 28, 9, 0))
        XCTAssertEqual(resolve("+1w 11:00"), date(2026, 10, 3, 11, 0))
    }

    func testIsoDates() {
        XCTAssertEqual(resolve("2026-10-01"), date(2026, 10, 1, 9, 0))
        XCTAssertEqual(resolve("2026-10-01 18:45"), date(2026, 10, 1, 18, 45))
        XCTAssertNil(resolve("2026-02-30"), "no such day")
    }

    func testNow() {
        XCTAssertEqual(resolve("now"), now)
    }

    func testNonsense() {
        XCTAssertNil(resolve(""))
        XCTAssertNil(resolve("someday"))
        XCTAssertNil(resolve("next fortnight"))
        XCTAssertNil(resolve("tomorrow 25:00"), "a bad time is not silently dropped")
    }

    func testRulesAreConfigurable() {
        var rules = DateRules()
        rules.todayOffset = 60 * 60
        rules.rounding = 15 * 60
        rules.defaultHour = 8
        rules.defaultMinute = 30
        XCTAssertEqual(resolve("today", rules: rules), date(2026, 9, 26, 15, 15))    // 15:07 → 15:15
        XCTAssertEqual(resolve("tomorrow", rules: rules), date(2026, 9, 27, 8, 30))
    }

    func testRulesComeFromTheConfig() throws {
        let config = try KeybowConfig.parse(Data("""
        { "defaults": { "dates": { "todayOffsetMinutes": 45, "defaultTime": "08:15" } }, "tree": [] }
        """.utf8))
        XCTAssertEqual(config.dateRules.todayOffset, 45 * 60)
        XCTAssertEqual(config.dateRules.defaultHour, 8)
        XCTAssertEqual(config.dateRules.defaultMinute, 15)
    }

    func testDurations() {
        XCTAssertEqual(DateExpression.duration("+30m"), 1800)
        XCTAssertEqual(DateExpression.duration("30 min"), 1800)
        XCTAssertEqual(DateExpression.duration("1h"), 3600)
        XCTAssertEqual(DateExpression.duration("2 hours"), 7200)
        XCTAssertNil(DateExpression.duration("soon"))
    }

    func testClock() {
        XCTAssertEqual(DateExpression.parseClock("9:05")?.hour, 9)
        XCTAssertEqual(DateExpression.parseClock("9:05")?.minute, 5)
        XCTAssertEqual(DateExpression.parseClock("12am")?.hour, 0)
        XCTAssertEqual(DateExpression.parseClock("12pm")?.hour, 12)
        XCTAssertEqual(DateExpression.parseClock("2:30pm")?.hour, 14)
        XCTAssertNil(DateExpression.parseClock("9"), "a bare number is ambiguous")
        XCTAssertNil(DateExpression.parseClock("24:00"))
        XCTAssertNil(DateExpression.parseClock("9:5"))
        XCTAssertNil(DateExpression.parseClock("13pm"))
    }
}
