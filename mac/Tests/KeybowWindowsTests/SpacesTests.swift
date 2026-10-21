import CoreGraphics
import KeybowKit
@testable import KeybowWindows
import XCTest

// A made-up window server: three screens — a portrait one on the left, the
// main one with a full-screen app among its desktops, and one on the right —
// listed as the window server lists them, the main one's first. Nothing on
// the Mac running the tests changes.

private let portrait = SpacesLayout.Display(identifier: "00000000-0000-0000-0000-00000000000a", name: "Portrait Display",
                                            frame: CGRect(x: -1080, y: -200, width: 1080, height: 1920), isMain: false)
private let main = SpacesLayout.Display(identifier: "00000000-0000-0000-0000-00000000000B", name: "Studio Display",
                                        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), isMain: true)
private let side = SpacesLayout.Display(identifier: "00000000-0000-0000-0000-00000000000C", name: "LG HDR 4K",
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

/// ⌃1 to ⌃7.
private let controlNumbers = Dictionary(uniqueKeysWithValues: (1...7).map {
    ($0, DesktopShortcut(key: CGKeyCode(17 + $0), modifiers: .maskControl, character: String($0)))
})

private final class FakeSpaces: SpacesControl, @unchecked Sendable {
    var screens = threeScreens
    var pointer: Int? = 2
    var current = SpacesLayout.showing(in: managed, mainIdentifier: main.identifier)
    var keys = controlNumbers
    var allowed = true
    var asked = false
    var pressed: [String] = []
    /// What each desktop number brings up, as this Mac numbers them: from
    /// the left, unless a test says.
    var numbering: [Int: (screen: String, space: Int)] = [:]
    /// Presses that come to nothing, as one might while a screen slides.
    var ignored = 0

    init() {
        for screen in threeScreens.screens {
            for space in screen.desktops { numbering[space.missionControl!] = (screen.identifier, space.id) }
        }
    }

    func layout() async -> (layout: SpacesLayout, pointer: Int?) { (screens, pointer) }
    func showing() -> [String: Int] { current }
    func shortcuts() -> [Int: DesktopShortcut] { keys }
    var mayPress: Bool { allowed }
    func askToPress() { asked = true }

    func press(_ shortcut: DesktopShortcut) {
        pressed.append(shortcut.title)
        if ignored > 0 {
            ignored -= 1
            return
        }
        guard let number = keys.first(where: { $0.value == shortcut })?.key, let shown = numbering[number] else { return }
        current[shown.screen] = shown.space
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

    func testMissionControlCountsDesktopsAcrossScreensFromTheLeft() {
        XCTAssertEqual(threeScreens.screens.map { $0.desktops.map(\.missionControl!) }, [[1, 2], [3, 4, 5], [6, 7]])
        XCTAssertEqual(threeScreens.serverOrder, [main.identifier, side.identifier, portrait.identifier])
        XCTAssertEqual(threeScreens.serverNumber(of: 3), 1, "counting the main screen's first")
        XCTAssertEqual(threeScreens.serverNumber(of: 30), 6)
        XCTAssertNil(threeScreens.serverNumber(of: 50), "a full-screen space has no number")
    }

    func testScreensSharingTheMainOnesSpacesHaveNoneOfTheirOwn() {
        let shared = SpacesLayout(managed: [entry("Main", [desktop(3), desktop(4)], showing: 3)],
                                  displays: [main, side], separate: false)
        XCTAssertFalse(shared.separate)
        XCTAssertEqual(shared.screens.map { $0.spaces.count }, [2, 0])
    }

    func testShortcutsAsSystemSettingsKeepsThem() {
        let hotKeys: [String: Any] = [
            "118": ["enabled": true, "value": ["type": "standard", "parameters": [49, 18, 655_360]]],
            "119": ["enabled": false, "value": ["type": "standard", "parameters": [50, 19, 262_144]]],
            "120": ["enabled": true, "value": ["type": "standard", "parameters": [65_535, 20, 262_144]]],
            // The function key's bit is left out of the press.
            "129": ["enabled": true, "value": ["type": "standard", "parameters": [61, 24, 262_144 | 0x80_0000]]],
            "79": ["enabled": true, "value": ["type": "standard", "parameters": [65_535, 123, 262_144]]],
        ]
        let shortcuts = DesktopShortcut.all(in: hotKeys)
        XCTAssertEqual(shortcuts.keys.sorted(), [1, 3, 12], "only Switch to Desktop, and only those on")
        XCTAssertEqual(shortcuts[1], DesktopShortcut(key: 18, modifiers: [.maskAlternate, .maskShift], character: "1"))
        XCTAssertEqual(shortcuts[1]?.title, "⌥⇧1")
        XCTAssertEqual(shortcuts[3]?.title, "⌃key 20")
        XCTAssertEqual(shortcuts[12]?.modifiers, .maskControl)
        XCTAssertEqual(shortcuts[12]?.title, "⌃=")
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
        let plan = SpacesModule.plan([1: 1, 2: 2, 3: 2], layout: threeScreens, shortcuts: controlNumbers, pointer: 1)
        XCTAssertEqual(plan.steps.map { "\($0.screen.number):\($0.space.id):\($0.shortcut.title)" }, ["3:21:⌃7", "1:30:⌃1"])
        XCTAssertEqual(plan.already, 1, "screen 2 already shows its desktop 2")
        XCTAssertEqual(plan.failures, [])
    }

    func testThePlanSaysWhatCantBeSwitched() {
        var shortcuts = controlNumbers
        shortcuts[7] = nil
        let plan = SpacesModule.plan([2: 5, 3: 2, 4: 1], layout: threeScreens, shortcuts: shortcuts, pointer: nil)
        XCTAssertEqual(plan.steps, [])
        XCTAssertEqual(plan.failures, [
            ModuleError("Studio Display has no desktop 5", "It has 3. Mission Control adds more."),
            ModuleError("Desktop 7 has no shortcut to switch to it", DesktopShortcut.whereToTurnOn(7)),
            ModuleError("There's no screen 4", "Screens are numbered 1 to 3, from the left."),
        ])
        let shared = SpacesLayout(managed: [entry("Main", [desktop(3), desktop(4)], showing: 3)],
                                  displays: [main, side], separate: false)
        XCTAssertEqual(SpacesModule.plan([2: 1], layout: shared, shortcuts: controlNumbers, pointer: nil).failures.first?.message,
                       "LG HDR 4K shows the main screen's Spaces")
    }

    func testPressesEachScreensShortcutAndSaysNothingOnceTheyShow() async {
        let fake = FakeSpaces()
        let module = SpacesModule(control: fake, patience: 0.2)
        let outcome = await module.run(request(["screen1": "1", "screen2": "3", "screen3": "2"]), now: Date())
        XCTAssertEqual(outcome, .quiet)
        XCTAssertEqual(fake.pressed, ["⌃1", "⌃7", "⌃5"], "the pointer's screen, 2, last")
        XCTAssertEqual(fake.current[portrait.identifier], 30)
        XCTAssertEqual(fake.current[main.identifier], 5)
        XCTAssertEqual(fake.current[side.identifier], 21)
    }

    func testPressesAgainWhenNothingChanged() async {
        let fake = FakeSpaces()
        fake.ignored = 1
        let outcome = await SpacesModule(control: fake, patience: 0.2).run(request(["screen3": "2"]), now: Date())
        XCTAssertEqual(outcome, .quiet)
        XCTAssertEqual(fake.pressed, ["⌃7", "⌃7"])

        fake.ignored = 2
        let failed = await SpacesModule(control: fake, patience: 0.1).run(request(["screen1": "1"]), now: Date())
        XCTAssertEqual(failed, .failure("Portrait Display didn't switch to desktop 1",
                                        "Pressing ⌃1, the shortcut for Desktop 1, changed nothing."))
    }

    func testSaysSoWhenMacOSNumbersDesktopsTheOtherWay() async {
        let fake = FakeSpaces()
        // The main screen's first, as the window server lists them.
        fake.numbering = [1: (main.identifier, 3), 2: (main.identifier, 4), 3: (main.identifier, 5),
                          4: (side.identifier, 20), 5: (side.identifier, 21),
                          6: (portrait.identifier, 30), 7: (portrait.identifier, 31)]
        let outcome = await SpacesModule(control: fake, patience: 0.2).run(request(["screen1": "1"]), now: Date())
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.message, "Desktop 1 is on another screen")
        XCTAssertEqual(outcome.detail, "Its shortcut, ⌃1, showed Studio Display's desktop 1 instead of Portrait Display's "
                       + "desktop 1: macOS numbers desktops across screens in another order. "
                       + "It seems to count the main screen's first.")
        XCTAssertEqual(fake.pressed, ["⌃1"], "and it stops there")
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
