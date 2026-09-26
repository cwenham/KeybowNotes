import XCTest
@testable import KeybowKit

final class ActionPlanTests: XCTestCase {
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

    private var templates: URL!

    override func setUpWithError() throws {
        templates = FileManager.default.temporaryDirectory.appendingPathComponent("keybow-templates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        try "# Standup — {{date}}\n\n## Yesterday\n- \n\n## Today\n- ".write(
            to: templates.appendingPathComponent("standup.md"), atomically: true, encoding: .utf8)
        try "**{{time}}** — {{parent}}: {{leaf}}".write(
            to: templates.appendingPathComponent("entry.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: templates)
    }

    private func plan(_ json: String, path: [Int], tree: TreeKind = .main) throws -> PlannedAction {
        let config = try KeybowConfig.parse(Data(json.utf8))
        let selection = try XCTUnwrap(config.resolve(tree: tree, path: path))
        return try ActionPlanner.plan(selection, config: config,
                                      context: ActionContext(templatesDirectory: templates, now: now, calendar: calendar))
    }

    private func assertPlanFails(_ json: String, path: [Int], with expected: ActionPlanError,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try plan(json, path: path), file: file, line: line) { error in
            XCTAssertEqual(error as? ActionPlanError, expected, file: file, line: line)
        }
    }

    // MARK: - Markdown

    func testMarkdownBlocks() {
        let html = NotesHTML.from(markdown: "# Title\n## Part\nText\n\n- one\n- two\n1. first\nafter")
        XCTAssertEqual(html, "<div><h1>Title</h1></div><div><h2>Part</h2></div><div>Text</div><div><br></div>"
                       + "<ul><li>one</li><li>two</li></ul><ol><li>first</li></ol><div>after</div>")
    }

    func testMarkdownInline() {
        XCTAssertEqual(NotesHTML.from(markdown: "**bold**, *it*, _also_ and [a link](https://example.com/?a=1&b=2)"),
                       "<div><b>bold</b>, <i>it</i>, <i>also</i> and a link (https://example.com/?a=1&amp;b=2)</div>")
    }

    func testMarkdownEscapesHTML() {
        XCTAssertEqual(NotesHTML.from(markdown: "a < b & \"c\""), "<div>a &lt; b &amp; &quot;c&quot;</div>")
        XCTAssertEqual(NotesHTML.title("<script>"), "<div><h1>&lt;script&gt;</h1></div>")
    }

    func testSnakeCaseIsNotItalic() {
        XCTAssertEqual(NotesHTML.from(markdown: "file_name_here"), "<div>file_name_here</div>")
    }

    // MARK: - Notes

    func testBareLeafMakesANoteInFoldersMirroringThePath() throws {
        let planned = try plan("""
        { "tree": [ { "label": "Ideas", "children": [ { "label": "Inventions" } ] } ] }
        """, path: [0, 0])
        guard case .createNote(let location, let title, let html) = planned.plan else { return XCTFail("\(planned)") }
        XCTAssertEqual(location.folders, ["Ideas", "Inventions"])
        XCTAssertEqual(location.account, "")
        XCTAssertEqual(title, "Inventions — 26 Sep 2026")
        XCTAssertEqual(html, "<div><h1>Inventions — 26 Sep 2026</h1></div>")
    }

    func testTemplateHeadingBecomesTheTitle() throws {
        let planned = try plan("""
        { "tree": [ { "label": "Standup", "action": { "template": "standup.md", "title": "", "folder": "Work" } } ] }
        """, path: [0])
        guard case .createNote(let location, let title, let html) = planned.plan else { return XCTFail("\(planned)") }
        XCTAssertEqual(location.folders, ["Work"])
        XCTAssertEqual(title, "Standup — 26 Sep 2026")
        XCTAssertTrue(html.hasPrefix("<div><h1>Standup — 26 Sep 2026</h1></div>"))
        XCTAssertTrue(html.contains("<div><h2>Yesterday</h2></div>"))
    }

    func testMissingTemplateIsReported() {
        XCTAssertThrowsError(try plan("""
        { "tree": [ { "label": "X", "action": { "template": "nope.md" } } ] }
        """, path: [0])) { error in
            guard case .templateNotFound(let path)? = error as? ActionPlanError else { return XCTFail("\(error)") }
            XCTAssertTrue(path.hasSuffix("nope.md"))
        }
    }

    func testAppendUsesItsTemplateAndGuards() throws {
        let planned = try plan("""
        { "tree": [ { "label": "Check-in", "action": { "type": "notes.append",
              "find": { "byName": "Check-ins — {{date:MMMM yyyy}}" }, "folder": "Journal",
              "template": "entry.md", "guards": { "maxBodyBytes": 1000 } },
            "children": [ { "label": "Mood", "children": [ { "label": "Great" } ] } ] } ] }
        """, path: [0, 0, 0])
        guard case .appendToNote(let location, let name, let entry, let titleHTML, let create, let guards) = planned.plan
        else { return XCTFail("\(planned)") }
        XCTAssertEqual(location.folders, ["Journal"])
        XCTAssertEqual(name, "Check-ins — September 2026")
        XCTAssertEqual(entry, "<div><br></div><div><b>14:07</b> — Mood: Great</div>")
        XCTAssertEqual(titleHTML, "<div><h1>Check-ins — September 2026</h1></div>")
        XCTAssertTrue(create)
        XCTAssertEqual(guards, AppendGuards(maxCharacters: 1000, refuseInlineImages: true))
    }

    func testAppendDefaultsToTheParentFolderAndLeafName() throws {
        let planned = try plan("""
        { "tree": [ { "label": "Docs", "action": { "type": "notes.append" },
            "children": [ { "label": "Website" } ] } ] }
        """, path: [0, 0])
        guard case .appendToNote(let location, let name, _, _, _, _) = planned.plan else { return XCTFail("\(planned)") }
        XCTAssertEqual(location.folders, ["Docs"])
        XCTAssertEqual(name, "Website")
    }

    // MARK: - Calendar and reminders

    func testEventFromADateLeaf() throws {
        let planned = try plan("""
        { "tree": [ { "label": "Meeting", "action": { "type": "calendar.createEvent", "alertMinutes": 5, "calendar": "Home" },
            "children": [ { "label": "Tomorrow", "params": { "when": "tomorrow" } } ] } ] }
        """, path: [0, 0])
        XCTAssertEqual(planned.plan, .createEvent(title: "Meeting", start: date(2026, 9, 27, 9, 0), duration: 1800,
                                                  alertMinutes: 5, calendarID: "", calendarName: "Home",
                                                  notes: "", show: true))
    }

    func testEventWithoutADateIsRefused() {
        assertPlanFails("""
        { "tree": [ { "label": "Meeting", "action": { "type": "calendar.createEvent" },
            "children": [ { "label": "Someday" } ] } ] }
        """, path: [0, 0], with: .missing(["when"], for: "event's date"))
    }

    func testTimerReminder() throws {
        let planned = try plan("""
        { "tree": [ { "label": "Timer", "action": { "type": "reminders.create", "title": "Timer: {{leaf}}" },
            "children": [ { "label": "25 min", "action": { "due": "+25m" } } ] } ] }
        """, path: [0, 0])
        XCTAssertEqual(planned.plan, .createReminder(title: "Timer: 25 min", notes: "",
                                                     due: date(2026, 9, 26, 14, 32), list: ""))
    }

    func testUnreadableDueDate() {
        assertPlanFails("""
        { "tree": [ { "label": "X", "action": { "type": "reminders.create", "due": "whenever" } } ] }
        """, path: [0], with: .unreadableDate("whenever"))
    }

    // MARK: - People, apps, shortcuts

    func testMessageNeedsAPhoneNumber() {
        assertPlanFails("""
        { "contacts": { "Sam Sample": { "phone": "" } },
          "tree": [ { "label": "Message", "action": { "type": "messages.compose" },
                      "children": [ { "label": "Sam Sample" } ] } ] }
        """, path: [0, 0], with: .missing(["contact.phone"], for: "message recipient"))
    }

    func testMessageToAContact() throws {
        let planned = try plan("""
        { "contacts": { "Alex Example": { "phone": "+15550100" } },
          "tree": [ { "label": "Message", "action": { "type": "messages.compose", "body": "Running late" },
                      "children": [ { "label": "Alex Example" } ] } ] }
        """, path: [0, 0])
        XCTAssertEqual(planned.plan, .composeMessage(to: "+15550100", body: "Running late"))
    }

    func testMailWithoutAnAddressStillOpensADraft() throws {
        let planned = try plan("""
        { "tree": [ { "label": "Mail", "action": { "type": "mail.compose" }, "children": [ { "label": "Nobody" } ] } ] }
        """, path: [0, 0])
        XCTAssertEqual(planned.plan, .composeMail(to: "", subject: "", body: ""))
        XCTAssertFalse(planned.warnings.isEmpty)
    }

    func testAppOpensTheProjectPath() throws {
        let planned = try plan("""
        { "projects": { "Website": { "path": "~/Code/website" } },
          "tree": [ { "label": "Website", "action": { "type": "app.open", "app": "Visual Studio Code" } } ] }
        """, path: [0])
        guard case .openApp(let name, _, let open) = planned.plan else { return XCTFail("\(planned)") }
        XCTAssertEqual(name, "Visual Studio Code")
        XCTAssertEqual(open, (("~/Code/website") as NSString).expandingTildeInPath)
    }

    func testAppWithAChannelButNoURLJustOpens() throws {
        let planned = try plan("""
        { "tree": [ { "label": "Server1", "action": { "type": "app.open", "app": "Discord", "target": "offtopic" } } ] }
        """, path: [0])
        XCTAssertEqual(planned.plan, .openApp(name: "Discord", bundleID: "", open: ""))
        XCTAssertTrue(planned.warnings.contains { $0.contains("offtopic") })
    }

    func testShortcutName() throws {
        let planned = try plan("""
        { "trees": { "bottom": [ { "label": "Home", "action": { "type": "shortcut", "name": "{{level2}} {{leaf}}" },
            "children": [ { "label": "Lights", "children": [ { "label": "Off" } ] } ] } ] } }
        """, path: [0, 0, 0], tree: .bottom)
        XCTAssertEqual(planned.plan, .runShortcut(name: "Lights Off", input: ""))
    }

    func testUnknownType() {
        assertPlanFails("""
        { "tree": [ { "label": "X", "action": { "type": "teleport" } } ] }
        """, path: [0], with: .unsupported("teleport"))
    }
}
