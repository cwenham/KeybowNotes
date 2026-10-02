import CoreGraphics
import KeybowKit
@testable import KeybowWindows
import XCTest

final class WindowGeometryTests: XCTestCase {
    typealias Place = WindowGeometry.Place

    /// A portrait screen on the left, the main one — menu bar and Dock — and
    /// another on the right, each with its own menu bar.
    private let portrait = WindowGeometry.Screen(name: "Portrait Display", frame: CGRect(x: -1080, y: -200, width: 1080, height: 1920),
                                                 visible: CGRect(x: -1080, y: -200, width: 1080, height: 1895))
    private let main = WindowGeometry.Screen(name: "Studio Display", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                             visible: CGRect(x: 0, y: 80, width: 2560, height: 1335))
    private let side = WindowGeometry.Screen(name: "LG HDR 4K", frame: CGRect(x: 2560, y: 0, width: 2560, height: 1440),
                                             visible: CGRect(x: 2560, y: 0, width: 2560, height: 1415))
    private var screens: [WindowGeometry.Screen] { [main, side, portrait] }

    func testHalvesFillTheOtherWayAndQuartersAreHalfOfEach() {
        let area = main.visible
        XCTAssertEqual(WindowGeometry.rect(for: .full, in: area), area, "the screen less the menu bar and the Dock")
        XCTAssertEqual(WindowGeometry.rect(for: .left, in: area), CGRect(x: 0, y: 80, width: 1280, height: 1335))
        XCTAssertEqual(WindowGeometry.rect(for: .right, in: area), CGRect(x: 1280, y: 80, width: 1280, height: 1335))
        XCTAssertEqual(WindowGeometry.rect(for: .bottom, in: area), CGRect(x: 0, y: 80, width: 2560, height: 667))
        XCTAssertEqual(WindowGeometry.rect(for: .top, in: area), CGRect(x: 0, y: 747, width: 2560, height: 668))
        XCTAssertEqual(WindowGeometry.rect(for: .topLeft, in: area), CGRect(x: 0, y: 747, width: 1280, height: 668))
        XCTAssertEqual(WindowGeometry.rect(for: .topRight, in: area), CGRect(x: 1280, y: 747, width: 1280, height: 668))
        XCTAssertEqual(WindowGeometry.rect(for: .bottomLeft, in: area), CGRect(x: 0, y: 80, width: 1280, height: 667))
        XCTAssertEqual(WindowGeometry.rect(for: .bottomRight, in: area), CGRect(x: 1280, y: 80, width: 1280, height: 667))
    }

    func testOddSizesLeaveNoGap() {
        let area = CGRect(x: 0, y: 0, width: 1001, height: 801)
        let left = WindowGeometry.rect(for: .left, in: area), right = WindowGeometry.rect(for: .right, in: area)
        XCTAssertEqual(left.maxX, right.minX)
        XCTAssertEqual(left.width + right.width, 1001)
        let bottom = WindowGeometry.rect(for: .bottom, in: area), top = WindowGeometry.rect(for: .top, in: area)
        XCTAssertEqual(bottom.maxY, top.minY)
        XCTAssertEqual(bottom.height + top.height, 801)
    }

    func testScreensAreNumberedFromTheLeft() throws {
        XCTAssertEqual(WindowGeometry.ordered(screens).map(\.name), ["Portrait Display", "Studio Display", "LG HDR 4K"])
        XCTAssertEqual(try WindowGeometry.screen("1", from: main, in: screens), portrait)
        XCTAssertEqual(try WindowGeometry.screen("3", from: main, in: screens), side)
        XCTAssertThrowsError(try WindowGeometry.screen("4", from: main, in: screens)) { error in
            XCTAssertEqual(error as? ModuleError, ModuleError("There's no screen 4", "Screens are numbered 1 to 3, from the left."))
        }
    }

    func testNextPreviousAndMain() throws {
        XCTAssertEqual(try WindowGeometry.screen("next", from: main, in: screens), side)
        XCTAssertEqual(try WindowGeometry.screen("Next screen", from: side, in: screens), portrait, "round the end")
        XCTAssertEqual(try WindowGeometry.screen("previous", from: portrait, in: screens), side)
        XCTAssertEqual(try WindowGeometry.screen("main", from: side, in: screens), main, "the one with the menu bar")
        XCTAssertEqual(try WindowGeometry.screen(nil, from: side, in: screens), side, "its own, when none is named")
        XCTAssertEqual(try WindowGeometry.screen("", from: portrait, in: screens), portrait)
    }

    func testScreensByName() throws {
        XCTAssertEqual(try WindowGeometry.screen("lg", from: main, in: screens), side)
        XCTAssertEqual(try WindowGeometry.screen("Studio Display", from: side, in: screens), main)
        XCTAssertThrowsError(try WindowGeometry.screen("Dell", from: main, in: screens)) { error in
            XCTAssertEqual((error as? ModuleError)?.message, "No screen is called “Dell”")
            XCTAssertEqual((error as? ModuleError)?.detail, "Connected: “Portrait Display”, “Studio Display”, “LG HDR 4K”.")
        }
    }

    func testTheScreenAWindowIsOn() {
        XCTAssertEqual(WindowGeometry.screen(holding: CGRect(x: 2400, y: 300, width: 800, height: 600), in: screens), side,
                       "the one with most of it")
        XCTAssertEqual(WindowGeometry.screen(holding: CGRect(x: -900, y: 100, width: 400, height: 400), in: screens), portrait)
        XCTAssertEqual(WindowGeometry.screen(holding: CGRect(x: 6000, y: 300, width: 100, height: 100), in: screens), side,
                       "off every screen: the nearest")
    }

    func testAWindowKeepsItsShareOnAnotherScreen() {
        let window = CGRect(x: 640, y: 80 + 1335 / 4, width: 1280, height: 1335 / 2)
        let moved = WindowGeometry.carried(window, from: main.visible, to: portrait.visible)
        XCTAssertEqual(moved.minX - portrait.visible.minX, 270, accuracy: 1, "a quarter across")
        XCTAssertEqual(moved.width, 540, accuracy: 1, "half the width")
        XCTAssertEqual(moved.height, 947, accuracy: 1, "half the height")
        XCTAssertTrue(portrait.visible.contains(moved))
    }

    func testAccessibilityCountsFromTheTop() {
        let left = WindowGeometry.rect(for: .left, in: main.visible)
        let flipped = WindowGeometry.flipped(left, mainHeight: 1440)
        XCTAssertEqual(flipped, CGRect(x: 0, y: 25, width: 1280, height: 1335), "just under the menu bar")
        XCTAssertEqual(WindowGeometry.flipped(flipped, mainHeight: 1440), left)
    }

    func testPlacesByName() {
        XCTAssertEqual(Place(words: "Top left"), .topLeft)
        XCTAssertEqual(Place(words: "top-left quarter"), .topLeft)
        XCTAssertEqual(Place(words: "TOPLEFT"), .topLeft)
        XCTAssertEqual(Place(words: "Upper right"), .topRight)
        XCTAssertEqual(Place(words: "Lower left corner"), .bottomLeft)
        XCTAssertEqual(Place(words: "bottomRight"), .bottomRight)
        XCTAssertEqual(Place(words: "Left half"), .left)
        XCTAssertEqual(Place(words: "Bottom"), .bottom)
        XCTAssertEqual(Place(words: "Full screen"), .full)
        XCTAssertEqual(Place(words: "Maximise"), .full)
        XCTAssertNil(Place(words: "Notes"))
        XCTAssertNil(Place(words: "Middle"))
        XCTAssertNil(Place(words: "Half"))
    }
}

final class WindowModuleTests: XCTestCase {
    private func request(_ fields: [String: String], leaf: String) -> ModuleRequest {
        ModuleRequest(type: WindowModule.type, fields: fields, labels: ["Windows", leaf])
    }

    func testThePlaceComesFromTheFieldOrTheLabel() {
        XCTAssertEqual(WindowModule.request(request(["place": "topLeft"], leaf: "Notes")).place, .topLeft)
        XCTAssertEqual(WindowModule.request(request([:], leaf: "Right half")).place, .right)
        let next = WindowModule.request(request([:], leaf: "Next screen"))
        XCTAssertNil(next.place)
        XCTAssertEqual(next.screen, "next", "a label can name the screen")
        XCTAssertEqual(WindowModule.request(request(["screen": "2"], leaf: "Docs")).screen, "2")
    }

    func testMistakesAreCaughtBeforeItRuns() {
        let module = WindowModule()
        XCTAssertEqual(module.problem(with: request(["place": "middle"], leaf: "Left")),
                       "“middle” isn't a place: full, left, right, top, bottom, topLeft, topRight, bottomLeft or bottomRight.")
        XCTAssertEqual(module.problem(with: request([:], leaf: "Docs")),
                       "Say where: a place like left or topRight — or a label that says it — or a screen.")
        XCTAssertNil(module.problem(with: request([:], leaf: "Bottom right")))
    }

    func testWhatThePreviewSays() {
        let module = WindowModule()
        let left = module.summary(of: request([:], leaf: "Left"), now: Date())
        XCTAssertEqual(left.verb, "Move window")
        XCTAssertEqual(left.subject, "Left half")
        XCTAssertEqual(module.summary(of: request(["screen": "next"], leaf: "Elsewhere"), now: Date()).subject, "to another screen")
        XCTAssertEqual(module.summary(of: request(["place": "full", "screen": "2"], leaf: "x"), now: Date()).details, ["on screen 2"])
    }
}

final class ExposeModuleTests: XCTestCase {
    private func request(_ fields: [String: String], leaf: String) -> ModuleRequest {
        ModuleRequest(type: ExposeModule.type, fields: fields, labels: ["Windows", leaf])
    }

    func testWhatToShowComesFromTheFieldOrTheLabel() {
        XCTAssertEqual(ExposeModule.show(request(["show": "app"], leaf: "Anything")).show, .app)
        XCTAssertEqual(ExposeModule.show(request([:], leaf: "App windows")).show, .app)
        XCTAssertEqual(ExposeModule.show(request([:], leaf: "Show desktop")).show, .desktop)
        XCTAssertEqual(ExposeModule.show(request([:], leaf: "All windows")).show, .all)
        XCTAssertEqual(ExposeModule.show(request([:], leaf: "Spaces")).show, .all, "else everything")
        XCTAssertEqual(ExposeModule.Show.app.argument, "2")
        XCTAssertNil(ExposeModule.Show.all.argument)
    }

    /// An event's `show` is yes or no; Exposé's is what to show — whichever
    /// the key inherits, and wherever the type is written in its brackets.
    func testShowIsWhatToShowNotAFlag() throws {
        ModuleRegistry.shared.register(ExposeModule(), host: MemoryModuleHost())
        ModuleRegistry.shared.register(WindowModule(), host: MemoryModuleHost())
        let (document, _) = OutlineParser.parse("""
            # row 2 [pages]
            1. Screens [Window, screen: main, instant: true]
               4. Expose [Exposé, show: all]
               8. App [show: app, Expose]
            # row 3
            1. Meeting [Calendar, show: no]
            """)
        let compiled = OutlineCompiler.compile(document, locateApp: { _ in nil })
        XCTAssertTrue(compiled.json.contains(#""action": { "type": "expose", "show": "all" }"#), compiled.json)
        XCTAssertTrue(compiled.json.contains(#""show": "app""#), "the type after the field")
        XCTAssertTrue(compiled.json.contains(#""show": false"#), "an event's is still a flag")
        XCTAssertTrue(compiled.json.contains(#""instant": true"#), "every action's flag")
    }

    func testMistakesAndThePreview() {
        let module = ExposeModule()
        XCTAssertEqual(module.problem(with: request(["show": "everything twice"], leaf: "x")),
                       "“everything twice” isn't something to show: all, app or desktop.")
        XCTAssertNil(module.problem(with: request([:], leaf: "Desktop")))
        XCTAssertTrue(module.firesAtOnce(request([:], leaf: "Desktop")))
        let summary = module.summary(of: request([:], leaf: "App windows"), now: Date())
        XCTAssertEqual(summary.verb, "Show")
        XCTAssertEqual(summary.subject, "the app's windows")
    }
}
