import KeybowKit
import XCTest

final class TimerMapsMusicTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    /// Sunday 27 September 2026, 14:07.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 14, minute: 7))!
    }

    private func plan(_ outline: String, path: [Int], environment: [String: String] = [:]) throws -> ActionPlan {
        let (document, _) = OutlineParser.parse(outline)
        let compiled = OutlineCompiler.compile(document, locateApp: { _ in nil })
        let config = try XCTUnwrap(compiled.config, compiled.configError ?? "")
        let selection = try XCTUnwrap(config.resolve(path: path))
        return try ActionPlanner.plan(selection, config: config, context: ActionContext(
            templatesDirectory: nil, now: now, calendar: calendar, environment: environment)).plan
    }

    private func assertRefused(_ outline: String, path: [Int], with expected: ActionPlanError,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try plan(outline, path: path), file: file, line: line) {
            XCTAssertEqual($0 as? ActionPlanError, expected, file: file, line: line)
        }
    }

    // MARK: - Timer lengths

    func testLengths() {
        func length(_ text: String) -> TimeInterval? {
            DateExpression.timerLength(text, now: now, calendar: calendar)
        }
        XCTAssertEqual(length("5 Minutes"), 300)
        XCTAssertEqual(length("+25m"), 1500)
        XCTAssertEqual(length("1h 30m"), 5400)
        XCTAssertEqual(length("1 hour and 30 minutes"), 5400)
        XCTAssertEqual(length("90s"), 90)
        XCTAssertEqual(length("2.5 min"), 150)
        XCTAssertNil(length("Tea"))
    }

    func testATimeOfDayRunsUntilThen() {
        XCTAssertEqual(DateExpression.timerLength("16:30", now: now, calendar: calendar), 2 * 3600 + 23 * 60)
        XCTAssertEqual(DateExpression.timerLength("today at 14:37", now: now, calendar: calendar), 30 * 60)
        XCTAssertEqual(DateExpression.timerLength("9:00", now: now, calendar: calendar), 18 * 3600 + 53 * 60,
                       "a time that has passed means tomorrow's")
    }

    func testDescribingLengths() {
        XCTAssertEqual(DateExpression.describe(seconds: 300), "5 min")
        XCTAssertEqual(DateExpression.describe(seconds: 5400), "1 h 30 min")
        XCTAssertEqual(DateExpression.describe(seconds: 45), "45 s")
        XCTAssertEqual(DateExpression.describe(seconds: 3600), "1 h")
    }

    // MARK: - Timers

    func testATimerFromItsLabel() throws {
        let outline = """
        1. Timer [Timer]
           1. 5 Minutes
           2. Tea
        """
        XCTAssertEqual(try plan(outline, path: [0, 0]), .startTimer(seconds: 300, shortcut: "KeybowNotes Timer"))
        assertRefused(outline, path: [0, 1], with: .notALength("Tea"))
    }

    func testAReminderBranchSwitchedToTimerKeepsItsDueTimes() throws {
        let outline = #"""
        1. Timer [Timer]
           1. Short [due: +5m, title: "{{selection|\"5 minute timer\"}}"]
           2. Tea [duration: 4 min, shortcut: My Timer]
        """#
        XCTAssertEqual(try plan(outline, path: [0, 0]), .startTimer(seconds: 300, shortcut: "KeybowNotes Timer"))
        XCTAssertEqual(try plan(outline, path: [0, 1]), .startTimer(seconds: 240, shortcut: "My Timer"))
    }

    func testTimersStopAtADay() {
        assertRefused("1. Long [Timer, duration: 25h]", path: [0], with: .timerTooLong("25h"))
    }

    // MARK: - Maps and Music

    func testMapsSearchesForTheLabelOrAQuery() throws {
        let outline = """
        1. Places [Maps]
           1. Coffee
           2. Here [query: "{{selection}} near me"]
        """
        XCTAssertEqual(try plan(outline, path: [0, 0]), .searchMaps("Coffee"))
        XCTAssertEqual(try plan(outline, path: [0, 1], environment: ["selection": "Tea & cake"]),
                       .searchMaps("Tea & cake near me"))
    }

    func testMusicPlaysAPlaylistByDefault() throws {
        let outline = """
        1. Music [Music]
           1. Focus
           2. Party [shuffle: yes]
           3. Kind of Blue [album: Kind of Blue, artist: Miles Davis]
        """
        XCTAssertEqual(try plan(outline, path: [0, 0]), .playPlaylist("Focus", shuffle: nil))
        XCTAssertEqual(try plan(outline, path: [0, 1]), .playPlaylist("Party", shuffle: true))
        XCTAssertEqual(try plan(outline, path: [0, 2]), .playAlbum("Kind of Blue", artist: "Miles Davis"))
    }

    func testTheEditorWritesTheKeywords() throws {
        var document = OutlineDocument()
        document.trees[.main] = [OutlineNode(label: "Thing"), nil, nil, nil]
        let id = try XCTUnwrap(document.roots(.main)[0]?.id)
        for (type, word) in [("clock.timer", "Timer"), ("maps.search", "Maps"), ("music.play", "Music")] {
            try document.setType(id, type)
            XCTAssertEqual(document.node(id)?.annotations, [.word(word)])
        }
    }

    // MARK: - Fallbacks

    func testAQuotedFallbackLosesItsQuotes() {
        XCTAssertEqual(Template.expand(#"{{selection|"5 minute timer"}}"#, params: [:]).text, "5 minute timer")
        XCTAssertEqual(Template.expand("{{selection|\u{201C}tea\u{201D}}}", params: [:]).text, "tea")
        XCTAssertEqual(Template.expand(#"{{selection|say "hi"}}"#, params: [:]).text, #"say "hi""#)
    }
}
