import XCTest
@testable import KeybowKit

final class ConfigTests: XCTestCase {
    private func parse(_ json: String) throws -> KeybowConfig {
        try KeybowConfig.parse(Data(json.utf8))
    }

    func testParsesASmallTree() throws {
        let config = try parse("""
        {
          "version": 1,
          "defaults": { "colour": "101010", "commitDelayMs": 500 },
          "tree": [
            { "label": "Work", "colour": "0060ff", "params": { "area": "work" },
              "children": [
                { "label": "Note", "params": { "kind": "note" },
                  "action": { "type": "notes.create", "folder": "Work" } }
              ] }
          ]
        }
        """)

        XCTAssertEqual(config.defaultColour, KeyColour(hex: "101010"))
        XCTAssertEqual(config.commitDelay, 0.5)
        XCTAssertEqual(config.tree[0]?.label, "Work")
        XCTAssertNil(config.tree[1])

        let selection = config.resolve(path: [0, 0])
        XCTAssertEqual(selection?.labels, ["Work", "Note"])
        XCTAssertEqual(selection?.action?.type, "notes.create")
        XCTAssertEqual(selection?.action?.string("folder"), "Work")
        // Parameters are inherited down the path.
        XCTAssertEqual(selection?.params, ["area": "work", "kind": "note"])
    }

    func testDeeperParametersWin() throws {
        let config = try parse("""
        { "tree": [ { "label": "A", "params": { "who": "outer", "keep": "yes" },
            "children": [ { "label": "B", "params": { "who": "inner" },
              "action": { "type": "x" } } ] } ] }
        """)
        XCTAssertEqual(config.resolve(path: [0, 0])?.params, ["who": "inner", "keep": "yes"])
    }

    func testExplicitKeyLeavesGaps() throws {
        let config = try parse("""
        { "tree": [ { "label": "Last", "key": 3, "action": { "type": "x" } } ] }
        """)
        XCTAssertNil(config.tree[0])
        XCTAssertEqual(config.tree[3]?.label, "Last")
    }

    func testRejectsTooManyNodes() {
        XCTAssertThrowsError(try parse("""
        { "tree": [ {"label":"1","action":{"type":"x"}}, {"label":"2","action":{"type":"x"}},
                    {"label":"3","action":{"type":"x"}}, {"label":"4","action":{"type":"x"}},
                    {"label":"5","action":{"type":"x"}} ] }
        """)) { error in
            XCTAssertTrue("\(error)".contains("at most 4"), "\(error)")
        }
    }

    func testRejectsDuplicateKeys() {
        XCTAssertThrowsError(try parse("""
        { "tree": [ {"label":"A","key":1,"action":{"type":"x"}},
                    {"label":"B","key":1,"action":{"type":"x"}} ] }
        """)) { error in
            XCTAssertTrue("\(error)".contains("both claim key 1"), "\(error)")
        }
    }

    func testRejectsNodeWithBothChildrenAndAction() {
        XCTAssertThrowsError(try parse("""
        { "tree": [ { "label": "A", "action": { "type": "x" },
            "children": [ { "label": "B", "action": { "type": "y" } } ] } ] }
        """)) { error in
            XCTAssertTrue("\(error)".contains("one or the other"), "\(error)")
        }
    }

    func testRejectsDeadEnd() {
        XCTAssertThrowsError(try parse("""
        { "tree": [ { "label": "A" } ] }
        """)) { error in
            XCTAssertTrue("\(error)".contains("neither children nor an action"), "\(error)")
        }
    }

    func testRejectsBadColourWithLocation() {
        XCTAssertThrowsError(try parse("""
        { "tree": [ { "label": "A", "colour": "nope", "action": { "type": "x" } } ] }
        """)) { error in
            XCTAssertTrue("\(error)".contains("not an rrggbb colour"), "\(error)")
            XCTAssertTrue("\(error)".contains("\"A\""), "error should name the node: \(error)")
        }
    }

    func testRejectsActionWithoutType() {
        XCTAssertThrowsError(try parse("""
        { "tree": [ { "label": "A", "action": { "folder": "Work" } } ] }
        """)) { error in
            XCTAssertTrue("\(error)".contains("no \"type\""), "\(error)")
        }
    }

    func testRejectsFutureVersion() {
        XCTAssertThrowsError(try parse("""
        { "version": 99, "tree": [] }
        """)) { error in
            XCTAssertTrue("\(error)".contains("newer than this app"), "\(error)")
        }
    }

    func testShippedExampleConfigIsValid() throws {
        // The example is the starting point for a real config, so it must parse.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KeybowKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // mac
            .appendingPathComponent("config.example.json")
        let config = try KeybowConfig.load(from: url)
        XCTAssertEqual(config.tree[0]?.label, "Work")
        XCTAssertEqual(config.resolve(path: [0, 0, 0, 0])?.action?.type, "notes.create")
        // A branch that ends early: Journal is a leaf on the top row.
        XCTAssertEqual(config.resolve(path: [3])?.action?.type, "notes.append")
    }
}
