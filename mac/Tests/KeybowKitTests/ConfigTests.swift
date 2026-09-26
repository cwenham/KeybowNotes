import XCTest
@testable import KeybowKit

final class ConfigTests: XCTestCase {
    private func parse(_ json: String) throws -> KeybowConfig {
        try KeybowConfig.parse(Data(json.utf8))
    }

    private func assertThrows(_ json: String, containing text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(json), file: file, line: line) { error in
            XCTAssertTrue("\(error)".contains(text), "expected \"\(text)\" in: \(error)", file: file, line: line)
        }
    }

    // MARK: - Basics

    func testParsesASmallTree() throws {
        let config = try parse("""
        {
          "version": 2,
          "defaults": { "colour": "101010", "commitDelayMs": 500 },
          "trees": { "main": [
            { "label": "Work", "colour": "0060ff", "params": { "area": "work" },
              "children": [
                { "label": "Note", "params": { "kind": "note" },
                  "action": { "type": "notes.create", "folder": "Work" } }
              ] }
          ] }
        }
        """)

        XCTAssertEqual(config.defaultColour, KeyColour(hex: "101010"))
        XCTAssertEqual(config.commitDelay, 0.5)
        XCTAssertEqual(config.tree[0]?.label, "Work")
        XCTAssertNil(config.tree[1])

        let selection = try XCTUnwrap(config.resolve(path: [0, 0]))
        XCTAssertEqual(selection.labels, ["Work", "Note"])
        XCTAssertEqual(selection.action?.type, "notes.create")
        XCTAssertEqual(selection.action?.string("folder"), "Work")
        // Parameters are inherited down the path.
        XCTAssertEqual(selection.params["area"], "work")
        XCTAssertEqual(selection.params["kind"], "note")
    }

    func testVersionOneSingleTreeStillLoads() throws {
        let config = try parse("""
        { "version": 1, "tree": [ { "label": "A", "action": { "type": "x" } } ] }
        """)
        XCTAssertEqual(config.resolve(path: [0])?.action?.type, "x")
    }

    func testComputedParameters() throws {
        let config = try parse("""
        { "tree": [ { "label": "Projects", "children": [ { "label": "Fiction", "children": [
            { "label": "Characters", "children": [ { "label": "The Detective" } ] } ] } ] } ] }
        """)
        let params = try XCTUnwrap(config.resolve(path: [0, 0, 0, 0])).params
        XCTAssertEqual(params["leaf"], "The Detective")
        XCTAssertEqual(params["parent"], "Characters")
        XCTAssertEqual(params["level2"], "Fiction")
        XCTAssertEqual(params["path"], "Projects / Fiction / Characters / The Detective")
        XCTAssertEqual(params["folderPath"], "Projects/Fiction/Characters/The Detective")
        XCTAssertEqual(params["parentPath"], "Projects/Fiction/Characters")
        XCTAssertEqual(params["tree"], "main")
    }

    func testSlashInALabelDoesNotAddAFolderLevel() throws {
        let config = try parse("""
        { "tree": [ { "label": "Q3/Q4", "children": [ { "label": "Plan" } ] } ] }
        """)
        XCTAssertEqual(config.resolve(path: [0, 0])?.params["folderPath"], "Q3-Q4/Plan")
    }

    func testDeeperParametersWin() throws {
        let config = try parse("""
        { "tree": [ { "label": "A", "params": { "who": "outer", "keep": "yes" },
            "children": [ { "label": "B", "params": { "who": "inner" },
              "action": { "type": "x" } } ] } ] }
        """)
        let params = try XCTUnwrap(config.resolve(path: [0, 0])).params
        XCTAssertEqual(params["who"], "inner")
        XCTAssertEqual(params["keep"], "yes")
    }

    func testExplicitKeyLeavesGaps() throws {
        let config = try parse("""
        { "tree": [ { "label": "Last", "key": 3, "action": { "type": "x" } } ] }
        """)
        XCTAssertNil(config.tree[0])
        XCTAssertEqual(config.tree[3]?.label, "Last")
    }

    func testColourIsInherited() throws {
        let config = try parse("""
        { "tree": [ { "label": "A", "colour": "ff0000", "children": [
            { "label": "B", "children": [ { "label": "C", "colour": "00ff00" } ] } ] } ] }
        """)
        XCTAssertEqual(config.node(at: [0, 0])?.colour, KeyColour(hex: "ff0000"))
        XCTAssertEqual(config.node(at: [0, 0, 0])?.colour, KeyColour(hex: "00ff00"))
    }

    // MARK: - Action inheritance

    func testActionOnABranchIsInheritedByItsLeaves() throws {
        // "Meeting (Calendar, 5 min alert)" with Today… beneath it.
        let config = try parse("""
        { "tree": [ { "label": "Meeting",
            "action": { "type": "calendar.createEvent", "alertMinutes": 5 },
            "children": [ { "label": "Today", "params": { "when": "today" } } ] } ] }
        """)
        let selection = try XCTUnwrap(config.resolve(path: [0, 0]))
        let action = try XCTUnwrap(selection.action)
        XCTAssertEqual(action.type, "calendar.createEvent")
        XCTAssertEqual(action.fields["alertMinutes"], .number(5))
        // Built-in defaults for the type fill in the rest.
        XCTAssertEqual(action.string("title"), "{{parent}}")
        XCTAssertEqual(action.string("start"), "{{when}}")
        XCTAssertEqual(action.fields["show"], .bool(true))
        XCTAssertEqual(selection.params["parent"], "Meeting")
        XCTAssertEqual(selection.params["when"], "today")
    }

    func testBranchesHaveNoActionOfTheirOwn() throws {
        let config = try parse("""
        { "tree": [ { "label": "A", "action": { "type": "x" }, "children": [ { "label": "B" } ] } ] }
        """)
        XCTAssertNil(config.resolve(path: [0])?.action, "only leaves act")
        XCTAssertEqual(config.resolve(path: [0, 0])?.action?.type, "x")
    }

    func testChangingTypeStartsAfresh() throws {
        // "Project Documentation (AppendProjectDocs.md)" → "New Project (NewProjectDocs.md)"
        let config = try parse("""
        { "tree": [ { "label": "Docs",
            "action": { "type": "notes.append", "template": "Append.md", "createIfMissing": false },
            "children": [
              { "label": "New", "action": { "type": "notes.create", "template": "New.md" } },
              { "label": "Existing" } ] } ] }
        """)
        let created = try XCTUnwrap(config.resolve(path: [0, 0])?.action)
        XCTAssertEqual(created.type, "notes.create")
        XCTAssertEqual(created.string("template"), "New.md")
        XCTAssertNil(created.fields["createIfMissing"], "append settings must not leak into a create")

        let appended = try XCTUnwrap(config.resolve(path: [0, 1])?.action)
        XCTAssertEqual(appended.type, "notes.append")
        XCTAssertEqual(appended.string("template"), "Append.md")
        XCTAssertEqual(appended.fields["createIfMissing"], .bool(false), "the node's value beats the built-in default")
    }

    func testBareLeafFallsBackToTheDefaultAction() throws {
        let config = try parse("""
        { "tree": [ { "label": "Ideas", "children": [ { "label": "Inventions" } ] } ] }
        """)
        let action = try XCTUnwrap(config.resolve(path: [0, 0])?.action)
        XCTAssertEqual(action.type, "notes.create")
        XCTAssertEqual(action.string("folder"), "{{folderPath}}")
    }

    func testTypelessFieldsLayerOntoTheDefaultAction() throws {
        // "Work log (worklog.md)": a template, but no type.
        let config = try parse("""
        { "tree": [ { "label": "Work log", "action": { "template": "worklog.md" } } ] }
        """)
        let action = try XCTUnwrap(config.resolve(path: [0])?.action)
        XCTAssertEqual(action.type, "notes.create")
        XCTAssertEqual(action.string("template"), "worklog.md")
        XCTAssertEqual(action.string("folder"), "{{folderPath}}")
    }

    func testConfigCanReplaceTheDefaults() throws {
        let config = try parse("""
        { "defaults": {
            "action": { "type": "notes.append", "folder": "Inbox" },
            "types": { "calendar.createEvent": { "duration": "+1h" } } },
          "tree": [
            { "label": "Bare" },
            { "label": "Event", "action": { "type": "calendar.createEvent" } } ] }
        """)
        let bare = try XCTUnwrap(config.resolve(path: [0])?.action)
        XCTAssertEqual(bare.type, "notes.append")
        XCTAssertEqual(bare.string("folder"), "Inbox")

        let event = try XCTUnwrap(config.resolve(path: [1])?.action)
        XCTAssertEqual(event.string("duration"), "+1h")
        XCTAssertEqual(event.string("start"), "{{when}}", "built-in type defaults not overridden are kept")
    }

    func testDefaultActionMustHaveAType() {
        assertThrows("""
        { "defaults": { "action": { "folder": "x" } }, "tree": [] }
        """, containing: "must have a \"type\"")
    }

    // MARK: - Lists

    func testListReferenceExpands() throws {
        let config = try parse("""
        { "lists": { "when": [ { "label": "Today", "params": { "when": "today" } },
                               { "label": "Tomorrow", "params": { "when": "tomorrow" } } ] },
          "tree": [
            { "label": "Meeting", "action": { "type": "calendar.createEvent" }, "children": "@when" },
            { "label": "Deploy", "action": { "type": "calendar.createEvent" }, "children": "@when" } ] }
        """)
        XCTAssertEqual(config.resolve(path: [0, 1])?.pathDescription, "Meeting / Tomorrow")
        XCTAssertEqual(config.resolve(path: [1, 0])?.params["when"], "today")
        XCTAssertEqual(config.resolve(path: [1, 0])?.params["parent"], "Deploy")
    }

    func testUnknownListIsAnError() {
        assertThrows("""
        { "tree": [ { "label": "A", "children": "@missing" } ] }
        """, containing: "no list called \"missing\"")
    }

    func testListThatIncludesItselfIsCaught() {
        assertThrows("""
        { "lists": { "loop": [ { "label": "Again", "children": "@loop" } ] },
          "tree": [ { "label": "A", "children": "@loop" } ] }
        """, containing: "too deep")
    }

    // MARK: - Contacts and projects

    func testContactFoundByLabel() throws {
        let config = try parse("""
        { "contacts": { "Alex Example": { "phone": "+15550001", "email": "alex@example.com" } },
          "tree": [ { "label": "Messaging", "action": { "type": "messages.compose" },
                      "children": [ { "label": "Alex Example" } ] } ] }
        """)
        let selection = try XCTUnwrap(config.resolve(path: [0, 0]))
        XCTAssertEqual(selection.params["contact.name"], "Alex Example")
        XCTAssertEqual(selection.params["contact.phone"], "+15550001")
        XCTAssertEqual(selection.action?.string("to"), "{{contact.phone}}")
    }

    func testProjectCanBeNamedExplicitly() throws {
        let config = try parse("""
        { "projects": { "Alpha": { "path": "~/Code/alpha" } },
          "tree": [ { "label": "Frontend", "params": { "project": "Alpha" },
                      "action": { "type": "app.open", "app": "Rider" } } ] }
        """)
        let selection = try XCTUnwrap(config.resolve(path: [0]))
        XCTAssertEqual(selection.params["project.path"], "~/Code/alpha")
    }

    // MARK: - Side trees

    func testSideTreesLoad() throws {
        let config = try parse("""
        { "trees": {
            "main": [ { "label": "M" } ],
            "row 2": [ { "label": "Two" } ],
            "row3": [ { "label": "Three" } ],
            "bottom": [ { "label": "Up" } ] } }
        """)
        XCTAssertEqual(config.roots(.row2)[0]?.label, "Two")
        XCTAssertEqual(config.roots(.row3)[0]?.label, "Three")
        XCTAssertEqual(config.resolve(tree: .bottom, path: [0])?.params["tree"], "bottom")
    }

    func testSideTreesAreShallower() {
        // Row 3 downwards has only rows 3 and 4 to work with.
        assertThrows("""
        { "trees": { "row3": [ { "label": "A", "children": [ { "label": "B", "children": [ { "label": "C" } ] } ] } ] } }
        """, containing: "row3 tree has only 2 levels")
    }

    func testUnknownTreeNameIsAnError() {
        assertThrows("""
        { "trees": { "sideways": [] } }
        """, containing: "expected main, row2, row3 or bottom")
    }

    // MARK: - Structural errors

    func testRejectsTooManyNodes() {
        assertThrows("""
        { "tree": [ {"label":"1"}, {"label":"2"}, {"label":"3"}, {"label":"4"}, {"label":"5"} ] }
        """, containing: "at most 4")
    }

    func testRejectsDuplicateKeys() {
        assertThrows("""
        { "tree": [ {"label":"A","key":1}, {"label":"B","key":1} ] }
        """, containing: "both claim key 1")
    }

    func testRejectsBadColourWithLocation() {
        XCTAssertThrowsError(try parse("""
        { "tree": [ { "label": "A", "colour": "nope" } ] }
        """)) { error in
            XCTAssertTrue("\(error)".contains("not an rrggbb colour"), "\(error)")
            XCTAssertTrue("\(error)".contains("\"A\""), "error should name the node: \(error)")
        }
    }

    func testRejectsFutureVersion() {
        assertThrows("""
        { "version": 99, "tree": [] }
        """, containing: "newer than this app")
    }

    func testShippedExampleConfigIsValid() throws {
        // The example is the starting point for a real config, so it must parse.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KeybowKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // mac
            .appendingPathComponent("config.example.json")
        let config = try KeybowConfig.load(from: url)
        XCTAssertEqual(config.version, 2)
        XCTAssertNotNil(config.tree[0])
        XCTAssertFalse(config.roots(.bottom).allSatisfy { $0 == nil }, "the example should show a side tree")
    }
}
