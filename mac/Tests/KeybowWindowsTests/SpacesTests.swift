import CoreGraphics
import KeybowKit
@testable import KeybowWindows
import XCTest

// A made-up window server: three screens — a portrait one on the left, the
// main one with a full-screen app among its desktops, and one on the right —
// listed as the window server lists them, the main one's first. Nothing on
// the Mac running the tests changes.

private let portrait = SpacesLayout.Display(id: 1, identifier: "00000000-0000-0000-0000-00000000000a", name: "Portrait Display",
                                            frame: CGRect(x: -1080, y: -200, width: 1080, height: 1920),
                                            isMain: false)
private let main = SpacesLayout.Display(id: 2, identifier: "00000000-0000-0000-0000-00000000000B", name: "Studio Display",
                                        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), isMain: true)
private let side = SpacesLayout.Display(id: 3, identifier: "00000000-0000-0000-0000-00000000000C", name: "LG HDR 4K",
                                        frame: CGRect(x: 2560, y: 0, width: 2560, height: 1440), isMain: false)

private func desktop(_ id: Int) -> [String: Any] { ["ManagedSpaceID": id, "id64": id, "type": 0] }

private func entry(_ identifier: String, _ spaces: [[String: Any]], showing: Int) -> [String: Any] {
    ["Display Identifier": identifier, "Spaces": spaces, "Current Space": desktop(showing)]
}

private let managed: [[String: Any]] = [
    entry("Main", [desktop(3), desktop(4), ["ManagedSpaceID": 50, "type": 4, "TileLayoutManager": [String: Any](), "pid": 900],
                   desktop(5)], showing: 4),
    entry("00000000-0000-0000-0000-00000000000c", [desktop(20), desktop(21)], showing: 20),
    entry("00000000-0000-0000-0000-00000000000A", [desktop(30), desktop(31)], showing: 31),
    // A screen that's been unplugged.
    ["Display Identifier": "00000000-0000-0000-0000-00000000000D", "Collapsed Space": desktop(60)],
]

private let threeScreens = SpacesLayout(managed: managed, displays: [main, side, portrait], appName: { $0 == 900 ? "Keynote" : nil })

/// A made-up Mission Control: pressing a thumbnail shows its space, unless a
/// test says the press doesn't take.
private final class FakeSpaces: SpacesControl, @unchecked Sendable {
    var screens = threeScreens
    var pointer: Int? = 2
    var current = SpacesLayout.showing(in: managed, mainIdentifier: main.identifier)
    var allowed = true
    var asked = false
    /// Each time Mission Control was opened, the thumbnails pressed: "screen:desktop".
    var pressed: [[String]] = []
    /// As Mission Control does, closing on the first: the rest come to nothing.
    var onlyFirstTakes = false
    /// Screens whose thumbnails never take.
    var stuck: Set<CGDirectDisplayID> = []
    var failure: ModuleError?

    func layout() async -> (layout: SpacesLayout, pointer: Int?) { (screens, pointer) }
    func showing() -> [String: Int] { current }
    var mayPress: Bool { allowed }
    func askToPress() { asked = true }

    func press(_ thumbnails: [SpaceThumbnail]) async throws {
        if let failure { throw failure }
        pressed.append(thumbnails.map { thumbnail in
            let screen = screens.screens.first { $0.displayID == thumbnail.display }!
            return "\(screen.number):\(screen.spaces[thumbnail.index].desktop ?? 0)"
        })
        for (index, thumbnail) in thumbnails.enumerated() where !(onlyFirstTakes && index > 0) {
            guard !stuck.contains(thumbnail.display),
                  let screen = screens.screens.first(where: { $0.displayID == thumbnail.display }) else { continue }
            current[screen.identifier] = screen.spaces[thumbnail.index].id
        }
    }
}

private func request(_ fields: [String: String]) -> ModuleRequest {
    ModuleRequest(type: SpacesModule.type, fields: fields, labels: ["Work", "Coding"])
}

final class SpacesLayoutTests: XCTestCase {
    func testScreensAreCountedFromTheLeftAndDesktopsOnEach() throws {
        XCTAssertEqual(threeScreens.screens.map(\.name), ["Portrait Display", "Studio Display", "LG HDR 4K"])
        XCTAssertEqual(threeScreens.screens.map(\.number), [1, 2, 3])
        let studio = try XCTUnwrap(threeScreens.screen(2))
        XCTAssertEqual(studio.spaces.map(\.id), [3, 4, 50, 5], "in Mission Control's order, full screen and all")
        XCTAssertEqual(studio.spaces.map(\.desktop), [1, 2, nil, 3], "a full-screen app's space isn't a desktop")
        XCTAssertEqual(studio.spaces[2].app, "Keynote")
        XCTAssertEqual(studio.desktop(3)?.id, 5)
        XCTAssertNil(studio.desktop(4))
        XCTAssertEqual(studio.showing, 4, "the main screen, though the window server calls it Main")
        XCTAssertEqual(threeScreens.screen(identifier: side.identifier)?.showing, 20, "identifiers match whatever their case")
        XCTAssertNil(threeScreens.screen(4), "the unplugged one is left out")
    }

    func testThumbnailsCountFullScreenSpacesToo() throws {
        let studio = try XCTUnwrap(threeScreens.screen(2))
        let step = SpacesModule.Step(screen: studio, space: try XCTUnwrap(studio.desktop(3)))
        XCTAssertEqual(step.thumbnail, SpaceThumbnail(display: 2, index: 3, count: 4), "after Keynote's")
    }

    func testScreensSharingTheMainOnesSpacesHaveNoneOfTheirOwn() {
        let shared = SpacesLayout(managed: [entry("Main", [desktop(3), desktop(4)], showing: 3)],
                                  displays: [main, side], separate: false)
        XCTAssertFalse(shared.separate)
        XCTAssertEqual(shared.screens.map { $0.spaces.count }, [2, 0])
    }
}

final class SpacesModuleTests: XCTestCase {
    func testWhatAScreensFieldTakes() {
        typealias Choice = SpacesModule.Choice
        XCTAssertEqual(Choice("2"), .desktop(2))
        XCTAssertEqual(Choice(" Desktop 3 "), .desktop(3))
        for unchanged in ["no change", "No Change", "none", "-", "unchanged", "leave it", ""] {
            XCTAssertEqual(Choice(unchanged), .unchanged, unchanged)
        }
        XCTAssertNil(Choice("0"))
        XCTAssertNil(Choice("Safari"))
        XCTAssertEqual(Choice.desktop(4).written, "4")
        XCTAssertEqual(Choice.unchanged.written, "no change")
        XCTAssertEqual(SpacesModule.screen(ofKey: "screen3"), 3)
        XCTAssertNil(SpacesModule.screen(ofKey: "screen7"))
        XCTAssertNil(SpacesModule.screen(ofKey: "screen"))
    }

    func testProblemsAndSummary() {
        let module = SpacesModule(control: FakeSpaces())
        XCTAssertEqual(module.problem(with: request(["screen2": "Safari"])),
                       "“Safari” isn't a desktop for screen 2: a number, like 2, or no change.")
        XCTAssertNotNil(module.problem(with: request(["screen1": "no change"])), "nothing to switch")
        XCTAssertNil(module.problem(with: request(["screen1": "no change", "screen3": "2"])))
        XCTAssertTrue(module.firesAtOnce(request(["screen1": "1"])))
        let summary = module.summary(of: request(["screen3": "1", "screen1": "2", "screen2": "no change"]), now: Date())
        XCTAssertEqual(summary, ModuleSummary(verb: "Show", subject: "desktop 2 on screen 1", details: ["desktop 1 on screen 3"]))
    }

    func testThePlanLeavesThePointersScreenTillLastAndSkipsWhatsShowing() {
        let plan = SpacesModule.plan([1: 1, 2: 2, 3: 2], layout: threeScreens, pointer: 1)
        XCTAssertEqual(plan.steps.map { "\($0.screen.number):\($0.space.id)" }, ["3:21", "1:30"])
        XCTAssertEqual(plan.already, 1, "screen 2 already shows its desktop 2")
        XCTAssertEqual(plan.failures, [])
    }

    func testThePlanSaysWhatCantBeSwitched() {
        let plan = SpacesModule.plan([2: 5, 4: 1], layout: threeScreens, pointer: nil)
        XCTAssertEqual(plan.steps, [])
        XCTAssertEqual(plan.failures, [
            ModuleError("Studio Display has no desktop 5", "It has 3. Mission Control adds more."),
            ModuleError("There's no screen 4", "Screens are numbered 1 to 3, from the left."),
        ])
        let shared = SpacesLayout(managed: [entry("Main", [desktop(3), desktop(4)], showing: 3)],
                                  displays: [main, side], separate: false)
        XCTAssertEqual(SpacesModule.plan([2: 1], layout: shared, pointer: nil).failures.first?.message,
                       "LG HDR 4K shows the main screen's Spaces")
    }

    func testPressesEveryScreensThumbnailInOneGoWhenTheyTake() async {
        let fake = FakeSpaces()
        let outcome = await SpacesModule(control: fake, patience: 0.2).run(request(["screen1": "1", "screen2": "3", "screen3": "2"]),
                                                                           now: Date())
        XCTAssertEqual(outcome, .quiet)
        XCTAssertEqual(fake.pressed, [["1:1", "3:2", "2:3"]], "the pointer's screen, 2, last")
        XCTAssertEqual(fake.current[portrait.identifier], 30)
        XCTAssertEqual(fake.current[main.identifier], 5)
        XCTAssertEqual(fake.current[side.identifier], 21)
    }

    func testGoesAgainForEachScreenMissionControlClosedOn() async {
        let fake = FakeSpaces()
        fake.onlyFirstTakes = true
        let outcome = await SpacesModule(control: fake, patience: 0.2).run(request(["screen1": "1", "screen2": "3", "screen3": "2"]),
                                                                           now: Date())
        XCTAssertEqual(outcome, .quiet)
        XCTAssertEqual(fake.pressed, [["1:1", "3:2", "2:3"], ["3:2"], ["2:3"]])
    }

    func testSaysWhichScreensDidntSwitch() async {
        let fake = FakeSpaces()
        fake.stuck = [side.id]
        let outcome = await SpacesModule(control: fake, patience: 0.1).run(request(["screen1": "1", "screen3": "2"]), now: Date())
        XCTAssertEqual(outcome, .failure("LG HDR 4K didn't switch to desktop 2",
                                         "Its thumbnail in Mission Control was pressed, and the screen stayed as it was."))
        XCTAssertEqual(fake.current[portrait.identifier], 30, "the other one did")
        XCTAssertEqual(fake.pressed, [["1:1", "3:2"], ["3:2"]])

        let closed = FakeSpaces()
        closed.failure = ModuleError("Mission Control didn't open", "KeybowNotes opens it to switch Spaces.")
        let failed = await SpacesModule(control: closed, patience: 0.1).run(request(["screen3": "2", "screen1": "1"]), now: Date())
        XCTAssertFalse(failed.succeeded)
        XCTAssertEqual(failed.message, "2 screens didn't switch")
        XCTAssertEqual(failed.detail, "Portrait Display didn't switch: Mission Control didn't open — KeybowNotes opens it to "
                       + "switch Spaces. · LG HDR 4K didn't switch: Mission Control didn't open — KeybowNotes opens it to "
                       + "switch Spaces.")
    }

    func testAsksForAccessibilityFirst() async {
        let fake = FakeSpaces()
        fake.allowed = false
        let outcome = await SpacesModule(control: fake).run(request(["screen1": "1"]), now: Date())
        XCTAssertEqual(outcome.message, "KeybowNotes needs Accessibility access to switch Spaces")
        XCTAssertTrue(fake.asked)
        XCTAssertEqual(fake.pressed, [])
    }

    func testEachScreenIsInheritedOnItsOwn() throws {
        let vocabulary = ActionVocabulary(modules: SpacesModule(control: FakeSpaces()).manifest.actionTypes)
        let (document, _) = OutlineParser.parse("""
            1. Coding [Spaces, screen1: 2]
               1. Notes [screen2: 1, screen3: 3]
               2. Site [screen1: no change, screen3: 1]
            """)
        let compiled = OutlineCompiler.compile(document, locateApp: { _ in nil }, vocabulary: vocabulary)
        XCTAssertEqual(compiled.diagnostics.map(\.message), [])
        let config = try XCTUnwrap(compiled.config)
        func wanted(_ path: [Int]) throws -> [Int: Int] {
            let action = try XCTUnwrap(config.resolve(path: path)?.action)
            XCTAssertEqual(action.type, SpacesModule.type)
            return SpacesModule.wanted(request(action.fields.compactMapValues(\.stringValue))).desktops
        }
        XCTAssertEqual(try wanted([0, 0]), [1: 2, 2: 1, 3: 3])
        XCTAssertEqual(try wanted([0, 1]), [3: 1], "no change on screen 1 overrides the branch")
    }
}
