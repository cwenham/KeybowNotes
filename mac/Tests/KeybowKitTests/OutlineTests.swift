import XCTest
@testable import KeybowKit

final class OutlineTests: XCTestCase {
    private func locate(_ name: String) -> OutlineConverter.AppMatch? {
        switch name.lowercased() {
        case "rider": return .init(name: "Rider", installed: true, isService: false, bundleIdentifier: "com.jetbrains.rider")
        case "discord": return .init(name: "Discord", installed: true, isService: true)
        default: return nil
        }
    }

    private func compile(_ text: String) -> (OutlineDocument, OutlineCompilation) {
        let (document, diagnostics) = OutlineParser.parse(text)
        XCTAssertEqual(diagnostics.filter { $0.severity == .error }, [], "unexpected errors")
        return (document, OutlineCompiler.compile(document, locateApp: locate))
    }

    // MARK: - Reading and writing

    private let full = """
    KeybowNotes template hierarchy

    1. Work [colour: 0060ff]
       1. Meeting [Calendar, 5 min alert, duration: 1h]
          1. Today
          3. Friday [when: "friday, 14:00"]
       4. Notes
          1. Work log [worklog.md]
    2. Project \\[old\\] notes

    # row 2
    1. Check-in [append, find.byName: Check-ins]
       1. Mood [@rating]

    # list rating
    1. Great
    2. Meh

    # contacts
    - Alex Example [phone: +15550100, email: alex@example.com]

    # projects
    - Website [path: ~/Code/website]

    # defaults
    - commitDelayMs: 800
    - dates.defaultTime: 08:30
    """

    func testParsesEverySection() {
        let (document, diagnostics) = OutlineParser.parse(full)
        XCTAssertEqual(diagnostics, [])
        XCTAssertEqual(document.preamble, ["KeybowNotes template hierarchy"])
        XCTAssertEqual(document.roots(.main)[0]?.label, "Work")
        XCTAssertEqual(document.roots(.main)[1]?.label, "Project [old] notes", "escaped brackets are literal")
        XCTAssertEqual(document.roots(.main)[0]?.children[0]?.annotations,
                       [.word("Calendar"), .word("5 min alert"), .pair(key: "duration", value: "1h")])
        XCTAssertEqual(document.roots(.main)[0]?.children[0]?.children[2]?.annotations,
                       [.pair(key: "when", value: "friday, 14:00")], "a quoted value may contain a comma")
        XCTAssertEqual(document.roots(.row2)[0]?.children[0]?.listReference, "rating")
        XCTAssertEqual(document.lists.map(\.name), ["rating"])
        XCTAssertEqual(document.contacts.first?.value("phone"), "+15550100")
        XCTAssertEqual(document.projects.first?.value("path"), "~/Code/website")
        XCTAssertEqual(document.defaults, [.pair(key: "commitDelayMs", value: "800"),
                                           .pair(key: "dates.defaultTime", value: "08:30")])
    }

    func testWritingThenReadingGivesTheSameDocument() {
        let (document, _) = OutlineParser.parse(full)
        let written = OutlineWriter.text(document)
        let (reread, diagnostics) = OutlineParser.parse(written)
        XCTAssertEqual(diagnostics, [])
        XCTAssertEqual(OutlineWriter.text(reread), written, "the written form is stable")
        XCTAssertEqual(reread.roots(.main)[1]?.label, "Project [old] notes")
        XCTAssertEqual(reread.roots(.main)[0]?.children[0]?.children[2]?.annotations,
                       [.pair(key: "when", value: "friday, 14:00")])
    }

    func testMistakesAreReportedAndReadingCarriesOn() {
        let (document, diagnostics) = OutlineParser.parse("""
        1. Fine
        5. Too far
           1. Child of a bad item
        1. Twice
        2. Also fine
        """)
        XCTAssertEqual(diagnostics.map(\.line), [2, 4])
        XCTAssertEqual(document.roots(.main)[0]?.label, "Fine")
        XCTAssertEqual(document.roots(.main)[1]?.label, "Also fine")
        XCTAssertFalse(document.roots(.main).contains { $0?.label == "Child of a bad item" },
                       "a bad item's children are skipped with it")
    }

    func testDepthIsCheckedPerTree() {
        let (_, diagnostics) = OutlineParser.parse("""
        # row 3
        1. A
           1. B
              1. Too deep
        """)
        XCTAssertEqual(diagnostics.first?.line, 4)
        XCTAssertTrue(diagnostics.first?.message.contains("2 levels") == true)
    }

    // MARK: - Compiling

    func testPairsBecomeFieldsOrValues() throws {
        let (document, compiled) = compile(full)
        let config = try XCTUnwrap(compiled.config, compiled.configError ?? "")
        let meeting = try XCTUnwrap(config.resolve(path: [0, 0, 0])?.action)
        XCTAssertEqual(meeting.string("duration"), "1h")
        XCTAssertEqual(meeting.fields["alertMinutes"], .number(5))
        XCTAssertEqual(config.resolve(path: [0, 0, 2])?.params["when"], "friday, 14:00")
        XCTAssertEqual(config.tree[0]?.colour, KeyColour(hex: "0060ff"))

        let roles = compiled.nodes[try XCTUnwrap(document.roots(.main)[0]?.children[0]?.id)]?.roles
        XCTAssertEqual(roles, [.actionType("calendar.createEvent"), .alert(minutes: 5), .field])
    }

    func testNestedFieldsAndLists() throws {
        let (_, compiled) = compile(full)
        let config = try XCTUnwrap(compiled.config, compiled.configError ?? "")
        let checkIn = try XCTUnwrap(config.resolve(tree: .row2, path: [0, 0, 1]))
        XCTAssertEqual(checkIn.pathDescription, "Check-in / Mood / Meh")
        XCTAssertEqual(checkIn.action?.type, "notes.append")
        guard case .object(let find)? = checkIn.action?.fields["find"] else { return XCTFail("no find") }
        XCTAssertEqual(find["byName"], .string("Check-ins"))
    }

    func testSectionsAndDefaults() throws {
        let (_, compiled) = compile(full)
        let config = try XCTUnwrap(compiled.config, compiled.configError ?? "")
        XCTAssertEqual(config.contacts["Alex Example"]?["email"], "alex@example.com")
        XCTAssertEqual(config.projects["Website"]?["path"], "~/Code/website")
        XCTAssertEqual(config.commitDelay, 0.8)
        XCTAssertEqual(config.dateRules.defaultHour, 8)
        XCTAssertEqual(config.dateRules.defaultMinute, 30)
    }

    func testTypeDefaultsKeepTheirDottedNames() throws {
        let (_, compiled) = compile("""
        1. Meeting [Calendar, when: tomorrow]

        # defaults
        - types.calendar.createEvent.duration: +1h
        """)
        let config = try XCTUnwrap(compiled.config, compiled.configError ?? "")
        XCTAssertEqual(config.resolve(path: [0])?.action?.string("duration"), "+1h")
    }

    func testMissingPeopleAreAddedEmptyAndReported() throws {
        let (_, compiled) = compile("""
        1. Message [Messages]
           1. Sam Sample

        # contacts
        - Alex Example [phone: +15550100]
        """)
        let config = try XCTUnwrap(compiled.config, compiled.configError ?? "")
        XCTAssertEqual(config.contacts["Sam Sample"]?["phone"], "")
        XCTAssertTrue(compiled.todo.contains { $0.contains("Sam Sample") && $0.contains("# contacts") })
    }

    func testEachNodeGetsItsDiagnostics() throws {
        let (document, compiled) = compile("""
        1. Discord [Discord]
           1. Server1 [offtopic]
        2. Oddity [whatever]
        """)
        let server = try XCTUnwrap(document.roots(.main)[0]?.children[0])
        let info = try XCTUnwrap(compiled.nodes[server.id])
        XCTAssertEqual(info.roles, [.target])
        XCTAssertTrue(info.diagnostics.contains { $0.message.contains("URL") })
        let oddity = try XCTUnwrap(document.roots(.main)[1])
        XCTAssertEqual(compiled.nodes[oddity.id]?.roles, [.unknown])
    }

    func testUnknownListIsAnError() {
        let (document, _) = OutlineParser.parse("1. A [@nope]")
        let compiled = OutlineCompiler.compile(document, locateApp: locate)
        XCTAssertTrue(compiled.diagnostics.contains { $0.severity == .error && $0.message.contains("nope") })
    }
}
