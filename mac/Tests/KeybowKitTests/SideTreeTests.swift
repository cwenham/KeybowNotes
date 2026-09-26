import XCTest
@testable import KeybowKit

final class SideTreeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// Something in every tree, each with its own colour.
    private func makeConfig() throws -> KeybowConfig {
        try KeybowConfig.parse(Data("""
        {
          "defaults": { "commitDelayMs": 1000 },
          "trees": {
            "main": [ { "label": "Work", "colour": "0000ff", "children": [
                { "label": "Meeting", "children": [ { "label": "Plan", "children": [ { "label": "Go" } ] } ] } ] } ],
            "row2": [ { "label": "Quick", "colour": "00ff00", "children": [
                { "label": "Note", "children": [ { "label": "Now" } ] } ] } ],
            "row3": [ { "label": "Timer", "colour": "ffff00", "children": [ { "label": "Five" } ] } ],
            "bottom": [ { "label": "Home", "colour": "ff00ff", "children": [
                { "label": "Lights", "children": [ { "label": "Kitchen", "children": [ { "label": "On" } ] } ] } ] } ]
          }
        }
        """.utf8))
    }

    private func key(row: Int, column: Int) -> Int {
        KeybowProtocol.key(row: row, column: column)
    }

    func testFirstPressPicksTheTree() throws {
        let config = try makeConfig()

        var navigator = Navigator(config: config, now: start)
        _ = navigator.keyDown(key(row: 1, column: 0), at: start)
        XCTAssertEqual(navigator.tree, .row2)
        XCTAssertEqual(navigator.currentRow, 2)

        navigator = Navigator(config: config, now: start)
        _ = navigator.keyDown(key(row: 2, column: 0), at: start)
        XCTAssertEqual(navigator.tree, .row3)

        navigator = Navigator(config: config, now: start)
        _ = navigator.keyDown(key(row: 3, column: 0), at: start)
        XCTAssertEqual(navigator.tree, .bottom)
        XCTAssertEqual(navigator.currentRow, 2, "the bottom tree climbs")
    }

    func testRowTwoTreeRunsDownToRowFour() throws {
        var navigator = Navigator(config: try makeConfig(), now: start)
        _ = navigator.keyDown(key(row: 1, column: 0), at: start)
        _ = navigator.keyDown(key(row: 2, column: 0), at: start)
        let events = navigator.keyDown(key(row: 3, column: 0), at: start)
        guard case .pending(let pending)? = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(pending.pathDescription, "Quick / Note / Now")
        XCTAssertEqual(pending.tree, .row2)
    }

    func testRowThreeTreeFiresInTwoPresses() throws {
        var navigator = Navigator(config: try makeConfig(), now: start)
        _ = navigator.keyDown(key(row: 2, column: 0), at: start)
        let events = navigator.keyDown(key(row: 3, column: 0), at: start)
        guard case .pending(let pending)? = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(pending.pathDescription, "Timer / Five")
    }

    func testBottomTreeClimbsToTheTopRow() throws {
        var navigator = Navigator(config: try makeConfig(), now: start)
        _ = navigator.keyDown(key(row: 3, column: 0), at: start)
        _ = navigator.keyDown(key(row: 2, column: 0), at: start)
        _ = navigator.keyDown(key(row: 1, column: 0), at: start)
        // Row 1 is the bottom tree's last level here, not an escape.
        let events = navigator.keyDown(key(row: 0, column: 0), at: start)
        guard case .pending(let pending)? = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(pending.pathDescription, "Home / Lights / Kitchen / On")
        XCTAssertEqual(pending.tree, .bottom)
    }

    func testNearerRowResetsInEitherDirection() throws {
        var navigator = Navigator(config: try makeConfig(), now: start)
        _ = navigator.keyDown(key(row: 3, column: 0), at: start)
        _ = navigator.keyDown(key(row: 2, column: 0), at: start)
        XCTAssertEqual(navigator.path, [0, 0])
        // Back on row 4 — the bottom tree's first row — starts it over.
        _ = navigator.keyDown(key(row: 3, column: 0), at: start)
        XCTAssertEqual(navigator.path, [0])
        XCTAssertEqual(navigator.tree, .bottom)
    }

    func testMidPathInTheMainTreeLowerRowsBelongToMain() throws {
        var navigator = Navigator(config: try makeConfig(), now: start)
        _ = navigator.keyDown(key(row: 0, column: 0), at: start)      // Work
        _ = navigator.keyDown(key(row: 1, column: 0), at: start)      // Meeting, not the row 2 tree
        XCTAssertEqual(navigator.tree, .main)
        XCTAssertEqual(navigator.path, [0, 0])
    }

    func testTopRowEscapesFromASideTree() throws {
        var navigator = Navigator(config: try makeConfig(), now: start)
        _ = navigator.keyDown(key(row: 1, column: 0), at: start)      // row 2 tree
        _ = navigator.keyDown(key(row: 0, column: 0), at: start)      // Work
        XCTAssertEqual(navigator.tree, .main)
        XCTAssertEqual(navigator.selection?.pathDescription, "Work")
    }

    func testOnlyTheTopRowEscapes() throws {
        var navigator = Navigator(config: try makeConfig(), now: start)
        _ = navigator.keyDown(key(row: 2, column: 0), at: start)      // row 3 tree
        // Row 2 is neither in the row 3 tree nor the top row.
        XCTAssertEqual(navigator.keyDown(key(row: 1, column: 0), at: start), [.invalidPress(key: 4)])
        XCTAssertEqual(navigator.tree, .row3)
    }

    func testTreeIsForgottenAfterFiring() throws {
        var navigator = Navigator(config: try makeConfig(), now: start)
        _ = navigator.keyDown(key(row: 2, column: 0), at: start)
        _ = navigator.keyDown(key(row: 3, column: 0), at: start)
        _ = navigator.tick(at: start.addingTimeInterval(1))
        XCTAssertNil(navigator.tree)
        // So the next press on row 4 starts the bottom tree afresh.
        _ = navigator.keyDown(key(row: 3, column: 0), at: start.addingTimeInterval(2))
        XCTAssertEqual(navigator.tree, .bottom)
    }

    func testIdleLightingOffersEveryTree() throws {
        let config = try makeConfig()
        let navigator = Navigator(config: config, now: start)
        let colours = Lighting().colours(for: navigator, config: config)
        for row in 0..<4 {
            XCTAssertNotEqual(colours[key(row: row, column: 0)], .off, "row \(row + 1) starts a tree")
            XCTAssertEqual(colours[key(row: row, column: 1)], .off, "nothing at column 2")
        }
    }

    func testSideTreeShowsTheEscapeFaintly() throws {
        let config = try makeConfig()
        var navigator = Navigator(config: config, now: start)
        _ = navigator.keyDown(key(row: 2, column: 0), at: start)      // row 3 tree
        let lighting = Lighting()
        let colours = lighting.colours(for: navigator, config: config)

        // Work's blue, at the faint escape level.
        let escape = colours[key(row: 0, column: 0)]
        XCTAssertEqual(escape, KeyColour(red: 0, green: 0, blue: UInt8((255 * lighting.escapeLevel).rounded())))
        XCTAssertEqual(colours[key(row: 2, column: 0)], KeyColour(hex: "ffff00"), "the chosen key at full strength")
        XCTAssertEqual(colours[key(row: 1, column: 0)], .off, "the row 2 tree is out of play")
    }
}
