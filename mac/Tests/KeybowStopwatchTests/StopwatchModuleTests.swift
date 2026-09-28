import KeybowKit
@testable import KeybowStopwatch
import XCTest

/// Keeps a module's saved state in memory.
private final class MemoryHost: ModuleHost, @unchecked Sendable {
    var stored: [String: Data] = [:]
    var changes = 0

    func load(_ key: String, for module: String) -> Data? { stored["\(module).\(key)"] }
    func save(_ data: Data?, as key: String, for module: String) { stored["\(module).\(key)"] = data }
    func statusChanged() { changes += 1 }
}

final class StopwatchModuleTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func fresh() -> (StopwatchModule, MemoryHost) {
        let host = MemoryHost()
        let stopwatch = StopwatchModule()
        stopwatch.start(host: host)
        return (stopwatch, host)
    }

    // MARK: - The stopwatch

    func testStartStopCarriesOn() {
        let (stopwatch, host) = fresh()
        XCTAssertEqual(stopwatch.perform(.start, at: at(0)).message, "Stopwatch started")
        XCTAssertEqual(stopwatch.perform(.stop, at: at(72)).message, "Stopwatch stopped at 1:12")
        XCTAssertEqual(stopwatch.perform(.toggle, at: at(500)).detail, "Carrying on from 1:12")
        XCTAssertEqual(stopwatch.reading(at: at(510)).elapsed, 82, "time stopped isn't counted")
        XCTAssertEqual(host.changes, 3)
    }

    func testLapsAndReset() {
        let (stopwatch, _) = fresh()
        stopwatch.perform(.start, at: at(0))
        XCTAssertEqual(stopwatch.perform(.lap, at: at(65)).message, "Lap 1: 1:05")
        XCTAssertEqual(stopwatch.perform(.lap, at: at(125)).message, "Lap 2: 1:00")
        XCTAssertEqual(stopwatch.values(now: at(130))["stopwatch.laps"], "1:05, 2:05")
        XCTAssertEqual(stopwatch.perform(.reset, at: at(130)).detail, "It had 2:10")
        XCTAssertEqual(stopwatch.reading(at: at(200)), .init(elapsed: 0, isRunning: false, laps: []))
        XCTAssertNil(stopwatch.status(now: at(200)), "nothing to show once reset")
    }

    func testStopWhenStoppedSaysSo() {
        let (stopwatch, _) = fresh()
        XCTAssertEqual(stopwatch.perform(.stop, at: at(0)).message, "The stopwatch isn't running")
        XCTAssertEqual(stopwatch.perform(.lap, at: at(0)).message, "The stopwatch isn't running")
    }

    func testStateSurvivesARestart() {
        let (stopwatch, host) = fresh()
        stopwatch.perform(.start, at: at(0))
        stopwatch.perform(.lap, at: at(30))
        let reopened = StopwatchModule()
        reopened.start(host: host)
        XCTAssertEqual(reopened.reading(at: at(100)), .init(elapsed: 100, isRunning: true, laps: [30]))
    }

    func testStatusCountsFromAFixedMoment() throws {
        let (stopwatch, _) = fresh()
        stopwatch.perform(.start, at: at(0))
        stopwatch.perform(.stop, at: at(60))
        stopwatch.perform(.start, at: at(100))
        let running = try XCTUnwrap(stopwatch.status(now: at(110)))
        XCTAssertEqual(running.countingFrom, at(40), "as though it had run without a break")
        XCTAssertTrue(running.lightsKeys)
        XCTAssertEqual(stopwatch.status(now: at(120)), running, "unchanged while it runs")
        stopwatch.perform(.stop, at: at(130))
        let stopped = try XCTUnwrap(stopwatch.status(now: at(500)))
        XCTAssertNil(stopped.countingFrom)
        XCTAssertEqual(stopped.text, "1:30")
        XCTAssertEqual(stopped.detail, "stopped")
        XCTAssertFalse(stopped.lightsKeys)
    }

    func testFormat() {
        XCTAssertEqual(StopwatchModule.format(0), "0:00")
        XCTAssertEqual(StopwatchModule.format(192.7), "3:12")
        XCTAssertEqual(StopwatchModule.format(3723), "1:02:03")
    }

    func testCommandsFromLabels() {
        XCTAssertEqual(StopwatchModule.Command(word: "Start/Stop"), .toggle)
        XCTAssertEqual(StopwatchModule.Command(word: "Pause"), .stop)
        XCTAssertEqual(StopwatchModule.Command(word: "Split"), .lap)
        XCTAssertNil(StopwatchModule.Command(word: "Tea"))
    }

    // MARK: - Through the module interface

    private func registered() -> StopwatchModule {
        let stopwatch = StopwatchModule()
        ModuleRegistry.shared.register(stopwatch, host: MemoryHost())
        return stopwatch
    }

    private func config(_ outline: String) throws -> KeybowConfig {
        let (document, _) = OutlineParser.parse(outline)
        let compiled = OutlineCompiler.compile(document, locateApp: { _ in nil })
        return try XCTUnwrap(compiled.config, compiled.configError ?? "")
    }

    func testTheOutlineReachesTheModule() async throws {
        let stopwatch = registered()
        let tree = try config("""
        # row 3
        1. Stopwatch [Stopwatch]
           1. Start
           2. Lap
           3. Focus [do: reset]
        """)
        let start = try XCTUnwrap(tree.resolve(tree: .row3, path: [0, 0]))
        let pressed = Date().addingTimeInterval(-0.25)
        let planned = try ActionPlanner.plan(start, config: tree, context: ActionContext(templatesDirectory: nil,
                                                                                         now: pressed))
        XCTAssertEqual(planned.plan, .module(ModuleRequest(type: "stopwatch", fields: [:],
                                                           labels: ["Stopwatch", "Start"], time: pressed)))
        let outcome = await ActionRunner.run(planned.plan)
        XCTAssertEqual(outcome.message, "Stopwatch started")
        XCTAssertEqual(stopwatch.status(now: pressed)?.countingFrom, pressed, "timed from the press, not the run")

        let reset = try XCTUnwrap(tree.resolve(tree: .row3, path: [0, 2]))
        XCTAssertEqual(ActionSummary(selection: reset, config: tree).verb, "Reset stopwatch")
    }

    func testAnUnknownCommandIsRefusedBeforeRunning() throws {
        _ = registered()
        let tree = try config("1. Stopwatch [Stopwatch, do: explode]")
        let selection = try XCTUnwrap(tree.resolve(path: [0]))
        XCTAssertThrowsError(try ActionPlanner.plan(selection, config: tree, context: ActionContext(templatesDirectory: nil))) {
            XCTAssertEqual(($0 as? ActionPlanError)?.description,
                           "“explode” isn't something the stopwatch does: toggle, start, stop, lap or reset.")
        }
    }

    func testOtherActionsCanUseItsTime() throws {
        let stopwatch = registered()
        stopwatch.perform(.start, at: Date().addingTimeInterval(-192))
        let tree = try config(#"1. Log [Notes, title: "Worked {{stopwatch}}"]"#)
        let selection = try XCTUnwrap(tree.resolve(path: [0]))
        XCTAssertEqual(ActionSummary(selection: selection, config: tree).subject, "Worked 3:12")
    }

    // MARK: - Running at once

    private func events(pressing keys: [Int], in tree: KeybowConfig) -> [NavigatorEvent] {
        var navigator = Navigator(config: tree, now: Date(timeIntervalSinceReferenceDate: 0))
        return keys.flatMap { navigator.keyDown($0, at: Date(timeIntervalSinceReferenceDate: 0)) }
    }

    private func fired(_ events: [NavigatorEvent]) -> Bool {
        events.contains { if case .fire = $0 { return true }; return false }
    }

    func testStartStopAndLapFireOnThePress() throws {
        _ = registered()
        let tree = try config("""
        1. Stopwatch [Stopwatch]
           1. Start
           2. Lap
           3. Reset
           4. Careful start [do: start, instant: false]
        2. Snippet [Copy, instant: true]
        3. Note
        """)
        XCTAssertTrue(fired(events(pressing: [0, 4], in: tree)), "start: no time to cancel")
        XCTAssertTrue(fired(events(pressing: [0, 5], in: tree)), "lap: no time to cancel")
        XCTAssertFalse(fired(events(pressing: [0, 6], in: tree)), "reset keeps the time to cancel")
        XCTAssertFalse(fired(events(pressing: [0, 7], in: tree)), "instant: false keeps it too")
        XCTAssertTrue(fired(events(pressing: [1], in: tree)), "instant: true works for any action")
        XCTAssertFalse(fired(events(pressing: [2], in: tree)), "everything else waits as before")
    }

    func testAPendingLeafWaitsItsOwnDelay() throws {
        _ = registered()
        let tree = try config("1. Stopwatch [Stopwatch]\n   1. Reset")
        var navigator = Navigator(config: tree, now: Date(timeIntervalSinceReferenceDate: 0))
        _ = navigator.keyDown(0, at: Date(timeIntervalSinceReferenceDate: 0))
        _ = navigator.keyDown(4, at: Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(navigator.pendingWindow, Date(timeIntervalSinceReferenceDate: 0)...Date(timeIntervalSinceReferenceDate: tree.commitDelay))
        XCTAssertTrue(fired(navigator.tick(at: Date(timeIntervalSinceReferenceDate: tree.commitDelay))))
    }

    func testTheKeyLeadingToItIsFound() throws {
        _ = registered()
        let tree = try config("""
        1. Notes
        # row 3
        1. Other
        2. Timing
           1. Stopwatch [Stopwatch]
        """)
        XCTAssertEqual(tree.entryKeys(toActionTypes: ["stopwatch"]), [KeybowProtocol.key(row: 2, column: 1)])
    }

    func testTheEditorWritesItsKeyword() throws {
        _ = registered()
        var document = OutlineDocument()
        document.trees[.main] = [OutlineNode(label: "Timing"), nil, nil, nil]
        let id = try XCTUnwrap(document.roots(.main)[0]?.id)
        try document.setType(id, "stopwatch")
        XCTAssertEqual(document.node(id)?.annotations, [.word("Stopwatch")])
    }

    func testPulsingKeysBreatheWhileIdle() throws {
        let tree = try config("1. Stopwatch [colour: ff8000]")
        var lighting = Lighting()
        lighting.pulsing = [0]
        let navigator = Navigator(config: tree)
        // Half a breath in: at full strength.
        let peak = Date(timeIntervalSinceReferenceDate: 1)
        XCTAssertEqual(lighting.colours(for: navigator, config: tree, now: peak)[0], KeyColour(hex: "ff8000"))
        let trough = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(lighting.colours(for: navigator, config: tree, now: trough)[0],
                       Lighting().colours(for: navigator, config: tree, now: trough)[0], "at rest, as dim as idle")
    }
}
