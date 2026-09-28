import XCTest
@testable import KeybowKit

final class NavigatorTests: XCTestCase {
    /// Work → Meeting → {1:1 → New note}, plus an early leaf on the top row.
    private func makeConfig(commitDelayMs: Int = 1000) throws -> KeybowConfig {
        try KeybowConfig.parse(Data("""
        {
          "defaults": { "commitDelayMs": \(commitDelayMs), "idleTimeoutMs": 10000, "longPressCancelMs": 1000 },
          "tree": [
            { "label": "Work", "children": [
                { "label": "Meeting", "children": [
                    { "label": "1:1", "children": [
                        { "label": "New note", "action": { "type": "notes.create" } }
                    ] }
                ] },
                { "label": "Task", "children": [
                    { "label": "Today", "action": { "type": "reminders.create" } }
                ] }
            ] },
            { "label": "Home", "children": [
                { "label": "Shopping", "action": { "type": "reminders.create" } }
            ] },
            { "label": "Journal", "key": 3, "action": { "type": "notes.append" } }
          ]
        }
        """.utf8))
    }

    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testWalksDownTheTreeAndFires() throws {
        var navigator = Navigator(config: try makeConfig(), now: start)

        XCTAssertEqual(navigator.keyDown(0, at: start), [.selectionChanged(navigator.selection)])
        XCTAssertEqual(navigator.path, [0])

        _ = navigator.keyDown(4, at: start)      // row 2, Meeting
        _ = navigator.keyDown(8, at: start)      // row 3, 1:1
        XCTAssertEqual(navigator.path, [0, 0, 0])

        let events = navigator.keyDown(12, at: start)   // row 4, New note
        guard case .pending(let pending)? = events.last else {
            return XCTFail("expected a pending action, got \(events)")
        }
        XCTAssertEqual(pending.pathDescription, "Work / Meeting / 1:1 / New note")
        XCTAssertEqual(pending.action?.type, "notes.create")

        // Nothing fires until the commit delay elapses.
        XCTAssertTrue(navigator.tick(at: start.addingTimeInterval(0.5)).isEmpty)

        let fired = navigator.tick(at: start.addingTimeInterval(1.0))
        XCTAssertEqual(fired, [.fire(pending, chosenAt: start), .cleared(reason: .completed)])
        XCTAssertEqual(navigator.path, [], "selection resets after firing")
    }

    func testHigherRowPressResetsRowsBelow() throws {
        var navigator = Navigator(config: try makeConfig(), now: start)
        _ = navigator.keyDown(0, at: start)      // Work
        _ = navigator.keyDown(4, at: start)      // Meeting
        _ = navigator.keyDown(8, at: start)      // 1:1
        XCTAssertEqual(navigator.path, [0, 0, 0])

        _ = navigator.keyDown(5, at: start)      // row 2, Task — resets rows 3 and 4
        XCTAssertEqual(navigator.path, [0, 1])
        XCTAssertEqual(navigator.selection?.pathDescription, "Work / Task")
    }

    func testChangingTheTopRowStartsAgain() throws {
        var navigator = Navigator(config: try makeConfig(), now: start)
        _ = navigator.keyDown(0, at: start)
        _ = navigator.keyDown(4, at: start)
        _ = navigator.keyDown(1, at: start)      // Home
        XCTAssertEqual(navigator.path, [1])
        XCTAssertEqual(navigator.selection?.pathDescription, "Home")
    }

    func testIgnoresPressesBelowTheCurrentRow() throws {
        var navigator = Navigator(config: try makeConfig(), now: start)
        XCTAssertEqual(navigator.keyDown(8, at: start), [.invalidPress(key: 8)])
        XCTAssertEqual(navigator.path, [])

        _ = navigator.keyDown(0, at: start)
        XCTAssertEqual(navigator.keyDown(12, at: start), [.invalidPress(key: 12)])
        XCTAssertEqual(navigator.path, [0])
    }

    func testIgnoresEmptyPositions() throws {
        var navigator = Navigator(config: try makeConfig(), now: start)
        // Only keys 0, 1 and 3 are occupied on the top row.
        XCTAssertEqual(navigator.keyDown(2, at: start), [.invalidPress(key: 2)])
    }

    func testBranchCanEndEarly() throws {
        var navigator = Navigator(config: try makeConfig(), now: start)
        let events = navigator.keyDown(3, at: start)     // Journal, a top-row leaf
        guard case .pending(let pending)? = events.last else {
            return XCTFail("expected pending, got \(events)")
        }
        XCTAssertEqual(pending.action?.type, "notes.append")
    }

    func testAnyPressDuringCommitWindowCancels() throws {
        var navigator = Navigator(config: try makeConfig(), now: start)
        _ = navigator.keyDown(3, at: start)
        let events = navigator.keyDown(0, at: start.addingTimeInterval(0.3))
        XCTAssertEqual(events, [.cleared(reason: .cancelled), .selectionChanged(nil)])
        XCTAssertEqual(navigator.path, [])
        // And the cancelled action never fires.
        XCTAssertTrue(navigator.tick(at: start.addingTimeInterval(2)).isEmpty)
    }

    func testZeroCommitDelayFiresImmediately() throws {
        var navigator = Navigator(config: try makeConfig(commitDelayMs: 0), now: start)
        let events = navigator.keyDown(3, at: start)
        XCTAssertEqual(events.count, 3)
        if case .fire = events[1] {} else { XCTFail("expected an immediate fire, got \(events)") }
    }

    func testLongPressClearsEverything() throws {
        var navigator = Navigator(config: try makeConfig(), now: start)
        _ = navigator.keyDown(0, at: start)
        _ = navigator.keyDown(4, at: start)

        XCTAssertTrue(navigator.tick(at: start.addingTimeInterval(0.5)).isEmpty)
        let events = navigator.tick(at: start.addingTimeInterval(1.1))
        XCTAssertEqual(events, [.cleared(reason: .longPress), .selectionChanged(nil)])
        XCTAssertEqual(navigator.path, [])

        // Holding on does not clear repeatedly.
        XCTAssertTrue(navigator.tick(at: start.addingTimeInterval(2.0)).isEmpty)
    }

    func testHoldingTheFinalKeyStillFires() throws {
        // The commit delay and the long-press threshold are both 1s in this
        // config. Holding the last key must run the action, not cancel it.
        var navigator = Navigator(config: try makeConfig(), now: start)
        _ = navigator.keyDown(3, at: start)          // Journal, still held
        let events = navigator.tick(at: start.addingTimeInterval(1.0))
        guard case .fire = events.first else {
            return XCTFail("a due action must win over the long press, got \(events)")
        }
    }

    func testIdleTimeoutClearsAnIncompleteSelection() throws {
        var navigator = Navigator(config: try makeConfig(), now: start)
        _ = navigator.keyDown(0, at: start)
        _ = navigator.keyUp(0, at: start)

        XCTAssertTrue(navigator.tick(at: start.addingTimeInterval(9)).isEmpty)
        let events = navigator.tick(at: start.addingTimeInterval(10.1))
        XCTAssertEqual(events, [.cleared(reason: .idleTimeout), .selectionChanged(nil)])
    }

    func testCurrentOptionsFollowTheSelection() throws {
        let config = try makeConfig()
        var navigator = Navigator(config: config, now: start)
        // Idle, every tree's first row is on offer at once, so there is no
        // single "current" row until the first press picks a tree.
        XCTAssertEqual(navigator.currentOptions.compactMap { $0?.label }, [])
        XCTAssertNil(navigator.currentRow)
        _ = navigator.keyDown(0, at: start)
        XCTAssertEqual(navigator.currentOptions.compactMap { $0?.label }, ["Meeting", "Task"])
        XCTAssertEqual(navigator.currentRow, 1)
    }

    func testLightingShowsChosenPathAndOptions() throws {
        let config = try makeConfig()
        var navigator = Navigator(config: config, now: start)
        let lighting = Lighting()

        let idle = lighting.colours(for: navigator, config: config)
        XCTAssertNotEqual(idle[0], KeyColour.off, "top row options should be lit")
        XCTAssertEqual(idle[2], KeyColour.off, "empty positions stay dark")
        XCTAssertEqual(idle[4], KeyColour.off, "rows not yet in play stay dark")

        _ = navigator.keyDown(0, at: start)
        let chosen = lighting.colours(for: navigator, config: config)
        XCTAssertNotEqual(chosen[0], KeyColour.off)
        XCTAssertNotEqual(chosen[4], KeyColour.off, "the next row is now offered")
        XCTAssertEqual(chosen[1], KeyColour.off, "unchosen siblings go dark")

        let flashed = lighting.colours(for: navigator, config: config, flashing: 9)
        XCTAssertEqual(flashed[9], lighting.invalidColour)
    }
}
