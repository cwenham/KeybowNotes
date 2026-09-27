import XCTest
@testable import KeybowKit

final class OutlineConverterTests: XCTestCase {
    /// A fixed set of "installed" apps, so the tests do not depend on the machine.
    private func locate(_ name: String) -> OutlineConverter.AppMatch? {
        switch name.lowercased().replacingOccurrences(of: " ", with: "") {
        case "rider": return .init(name: "Rider", installed: true, isService: false, bundleIdentifier: "com.jetbrains.rider")
        case "vscode": return .init(name: "Visual Studio Code", installed: true, isService: false)
        case "discord": return .init(name: "Discord", installed: true, isService: true)
        case "kicad": return .init(name: "KiCad", installed: false, isService: false)
        default: return nil
        }
    }

    private func convert(_ outline: String) throws -> (OutlineConverter.Result, KeybowConfig) {
        let result = try OutlineConverter.convert(outline, locateApp: locate)
        return (result, try KeybowConfig.parse(Data(result.json.utf8)))
    }

    private let sample = """
    KeybowNotes template hierarchy

    1. Work
       1. Immediate task
          1. Programming
             1. Project A [Rider]
             2. Project B [VSCode]
          3. Messaging [Messages]
             1. Alex Example
          4. Mail [Mail]
             1. Alex Example
       2. General Tasks
          1. Meeting [Calendar, 5 min alert]
             1. Today
             2. Tomorrow
          3. Project Documentation [AppendProjectDocs.md]
             1. New Project [NewProjectDocs.md]
             2. Project B
       3.
       4. Notes
          1. Work log [worklog.md]
    2. Personal
       4. Social
          2. Discord [Discord]
             1. Server1 [offtopic]
    4. Ideas
       3. Inventions
    """

    func testNumbersAreKeysAndGapsStayEmpty() throws {
        let (_, config) = try convert(sample)
        XCTAssertEqual(config.tree[0]?.label, "Work")
        XCTAssertEqual(config.tree[1]?.label, "Personal")
        XCTAssertNil(config.tree[2], "no item 3 at the top")
        XCTAssertEqual(config.tree[3]?.label, "Ideas")
        XCTAssertNil(config.node(at: [0, 2]), "\"3.\" with nothing after it is an empty key")
        XCTAssertEqual(config.node(at: [0, 3])?.label, "Notes")
        XCTAssertEqual(config.node(at: [3, 2])?.label, "Inventions")
    }

    func testAppAnnotationOpensTheLeafInThatApp() throws {
        let (result, config) = try convert(sample)
        let action = try XCTUnwrap(config.resolve(path: [0, 0, 0, 0])?.action)
        XCTAssertEqual(action.type, "app.open")
        XCTAssertEqual(action.string("app"), "Rider")
        XCTAssertEqual(action.string("bundleId"), "com.jetbrains.rider")
        XCTAssertTrue(result.todo.contains { $0.contains("Project A") && $0.contains("path") }, "project paths are left to fill in")
        XCTAssertTrue(result.inferences.contains { $0.contains("“VSCode” opens Visual Studio Code") })
    }

    func testCalendarBranchWithDatesAndAlert() throws {
        let (_, config) = try convert(sample)
        let tomorrow = try XCTUnwrap(config.resolve(path: [0, 1, 0, 1]))
        XCTAssertEqual(tomorrow.action?.type, "calendar.createEvent")
        XCTAssertEqual(tomorrow.action?.fields["alertMinutes"], .number(5))
        XCTAssertEqual(tomorrow.params["when"], "tomorrow")
        XCTAssertEqual(tomorrow.params["parent"], "Meeting")
    }

    func testPeopleBecomeSharedContacts() throws {
        let (result, config) = try convert(sample)
        XCTAssertNotNil(config.contacts["Alex Example"])
        XCTAssertEqual(config.contacts["Alex Example"]?.keys.sorted(), ["email", "phone"],
                       "one entry, holding what both Messages and Mail need")
        XCTAssertEqual(config.resolve(path: [0, 0, 2, 0])?.action?.type, "messages.compose")
        XCTAssertEqual(config.resolve(path: [0, 0, 3, 0])?.action?.type, "mail.compose")
        XCTAssertTrue(result.todo.contains { $0.contains("Alex Example") && $0.contains("phone and email") })
    }

    func testTemplateNamesSayAppendOrCreate() throws {
        let (result, config) = try convert(sample)
        XCTAssertEqual(config.resolve(path: [0, 1, 2, 0])?.action?.type, "notes.create")
        XCTAssertEqual(config.resolve(path: [0, 1, 2, 0])?.action?.string("template"), "NewProjectDocs.md")
        XCTAssertEqual(config.resolve(path: [0, 1, 2, 1])?.action?.type, "notes.append")
        XCTAssertEqual(config.resolve(path: [0, 1, 2, 1])?.action?.string("template"), "AppendProjectDocs.md")
        XCTAssertEqual(result.inferences.filter { $0.contains("template name") }.count, 2, "both guesses are reported")
    }

    func testTemplateAloneMeansANote() throws {
        let (_, config) = try convert(sample)
        let action = try XCTUnwrap(config.resolve(path: [0, 3, 0])?.action)
        XCTAssertEqual(action.type, "notes.create")
        XCTAssertEqual(action.string("template"), "worklog.md")
    }

    func testChannelInsideAServiceApp() throws {
        let (result, config) = try convert(sample)
        let action = try XCTUnwrap(config.resolve(path: [1, 3, 1, 0])?.action)
        XCTAssertEqual(action.type, "app.open")
        XCTAssertEqual(action.string("app"), "Discord")
        XCTAssertEqual(action.string("target"), "offtopic")
        XCTAssertTrue(result.todo.contains { $0.contains("Server1") && $0.contains("URL") })
    }

    func testBareLeafBecomesADefaultNote() throws {
        let (_, config) = try convert(sample)
        let selection = try XCTUnwrap(config.resolve(path: [3, 2]))
        XCTAssertEqual(selection.action?.type, "notes.create")
        XCTAssertEqual(selection.params["folderPath"], "Ideas/Inventions")
    }

    func testTopLevelBranchesGetDistinctColours() throws {
        let (_, config) = try convert(sample)
        let colours = [config.tree[0]?.colour, config.tree[1]?.colour, config.tree[3]?.colour].compactMap { $0 }
        XCTAssertEqual(Set(colours.map(\.hex)).count, 3)
        XCTAssertEqual(config.node(at: [0, 0, 0])?.colour, config.tree[0]?.colour, "children inherit")
    }

    func testHeadingsSelectSideTrees() throws {
        let (_, config) = try convert("""
        # My keypad
        1. Main thing
        # Row 2
        1. Quick
           1. Note
        # bottom tree
        2. Upward
        """)
        XCTAssertEqual(config.tree[0]?.label, "Main thing", "a heading that names no tree is a title")
        XCTAssertEqual(config.roots(.row2)[0]?.label, "Quick")
        XCTAssertEqual(config.roots(.bottom)[1]?.label, "Upward")
    }

    func testMissingAppIsAWarningNotAFailure() throws {
        let (result, config) = try convert("1. Board [KiCad]")
        XCTAssertEqual(config.resolve(path: [0])?.action?.string("app"), "KiCad")
        XCTAssertTrue(result.warnings.contains { $0.contains("KiCad isn't installed") })
    }

    func testUnknownLowercaseAnnotationIsKept() throws {
        let (result, config) = try convert("1. Thing [whatever]")
        XCTAssertEqual(config.resolve(path: [0])?.params["note"], "whatever")
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testKeyNumbersAreChecked() {
        XCTAssertThrowsError(try OutlineConverter.convert("5. Too far", locateApp: locate)) { error in
            XCTAssertTrue("\(error)".contains("line 1"), "\(error)")
            XCTAssertTrue("\(error)".contains("1 to 4"), "\(error)")
        }
        XCTAssertThrowsError(try OutlineConverter.convert("1. A\n1. B", locateApp: locate)) { error in
            XCTAssertTrue("\(error)".contains("line 2"), "\(error)")
        }
    }

    func testSplitAnnotations() {
        XCTAssertEqual(OutlineNode.split("Meeting [Calendar, 5 min alert]").label, "Meeting")
        XCTAssertEqual(OutlineNode.split("Meeting [Calendar, 5 min alert]").annotations,
                       [.word("Calendar"), .word("5 min alert")])
        XCTAssertEqual(OutlineNode.split("Pat O’Neill").label, "Pat O’Neill")
        XCTAssertEqual(OutlineNode.split("Pat O’Neill").annotations, [])
    }

    func testParenthesesAreNowJustText() throws {
        let (_, config) = try convert("1. Project (old) [Notes]")
        XCTAssertEqual(config.tree[0]?.label, "Project (old)")
        XCTAssertEqual(config.resolve(path: [0])?.action?.type, "notes.create")
    }
}
