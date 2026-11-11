@testable import KeybowKit
import XCTest

/// Keypads with a screen under each key: icons and captions in the outline,
/// the folders layout, and Back and Cancel.
final class KeyFacesTests: XCTestCase {
    private let outline = """
        1. Work [colour: 0000ff, icon: sf:briefcase.fill]
           1. Standup [Copy, icon: 🗣, caption: Stand-up]
           2. Notes [Copy]
              1. Today [caption: none, icon: Icons/today.png]
        2. Home [icon: "🏠"]

        # row 2
        1. Timers [Copy]

        # bottom
        1. Lights [Copy]
        """

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func config(_ text: String? = nil) throws -> KeybowConfig {
        let (document, problems) = OutlineParser.parse(text ?? outline)
        XCTAssertEqual(problems, [])
        let compiled = OutlineCompiler.compile(document, locateApp: { _ in nil })
        XCTAssertEqual(compiled.diagnostics.filter { $0.severity == .error }, [])
        return try XCTUnwrap(compiled.config)
    }

    // MARK: Icons

    func testReadsEachKindOfIcon() {
        XCTAssertEqual(KeyIcon("sf:envelope.fill"), .symbol("envelope.fill"))
        XCTAssertEqual(KeyIcon("SF: star"), .symbol("star"))
        XCTAssertEqual(KeyIcon("Icons/mum.png"), .file("Icons/mum.png"))
        XCTAssertEqual(KeyIcon("~/Pictures/My Cat.JPG"), .file("~/Pictures/My Cat.JPG"))
        XCTAssertEqual(KeyIcon("logo.svg"), .file("logo.svg"))
        XCTAssertEqual(KeyIcon("📞"), .text("📞"))
        XCTAssertEqual(KeyIcon("Hi"), .text("Hi"))
        XCTAssertEqual(KeyIcon("v1.2"), .text("v1.2"), "not an image's extension")
        XCTAssertNil(KeyIcon("  "))
        XCTAssertNil(KeyIcon("sf:"))
        for written in ["sf:star", "Icons/a.png", "🙂"] { XCTAssertEqual(KeyIcon(written)?.written, written) }
    }

    func testFilesAreFoundBesideTheTree() {
        let folder = URL(fileURLWithPath: "/tmp/tree")
        XCTAssertEqual(KeyIcon("Icons/a.png")?.fileURL(relativeTo: folder)?.path, "/tmp/tree/Icons/a.png")
        XCTAssertEqual(KeyIcon("/x/a.png")?.fileURL(relativeTo: folder)?.path, "/x/a.png")
        XCTAssertNil(KeyIcon("🙂")?.fileURL(relativeTo: folder))
    }

    func testTheOutlineGivesKeysIconsAndCaptions() throws {
        let config = try config()
        let work = try XCTUnwrap(config.node(at: [0]))
        XCTAssertEqual(work.icon, .symbol("briefcase.fill"))
        XCTAssertEqual(work.keyCaption, "Work", "the label, without a caption")
        let standup = try XCTUnwrap(config.node(at: [0, 0]))
        XCTAssertEqual(standup.icon, .text("🗣"))
        XCTAssertEqual(standup.keyCaption, "Stand-up")
        let today = try XCTUnwrap(config.node(at: [0, 1, 0]))
        XCTAssertNil(today.keyCaption, "caption: none")
        XCTAssertNil(config.node(at: [0, 1])?.icon, "icons aren't inherited")
        XCTAssertEqual(config.node(at: [1])?.icon, .text("🏠"))
    }

    func testIconsAreNotValuesForTemplates() throws {
        let config = try config()
        let standup = try XCTUnwrap(config.resolve(tree: .main, path: [0, 0]))
        XCTAssertNil(standup.params["icon"])
        XCTAssertNil(standup.params["caption"])
    }

    func testAStepCantHaveAnIcon() {
        let (document, _) = OutlineParser.parse("1. Go\n   - Copy [Copy, icon: sf:star]\n")
        let compiled = OutlineCompiler.compile(document, locateApp: { _ in nil })
        XCTAssertTrue(compiled.diagnostics.contains { $0.message.contains("no icon") }, "\(compiled.diagnostics)")
    }

    // MARK: Back and Cancel

    func testBackGoesUpALevelThenToRest() throws {
        var navigator = Navigator(config: try config(), now: start)
        _ = navigator.keyDown(0, at: start)
        _ = navigator.keyDown(KeybowProtocol.key(row: 1, column: 1), at: start)
        XCTAssertEqual(navigator.path, [0, 1])
        XCTAssertEqual(navigator.navigate(.back, at: start).count, 1)
        XCTAssertEqual(navigator.path, [0])
        XCTAssertEqual(navigator.navigate(.back, at: start), [.selectionChanged(nil)])
        XCTAssertNil(navigator.tree)
        XCTAssertEqual(navigator.navigate(.back, at: start), [], "nothing to go back from")
    }

    func testCancelClearsEverythingAndStopsAPendingAction() throws {
        var navigator = Navigator(config: try config(), now: start)
        _ = navigator.keyDown(0, at: start)
        _ = navigator.keyDown(KeybowProtocol.key(row: 1, column: 0), at: start)
        XCTAssertNotNil(navigator.pendingWindow, "Standup waits to run")
        XCTAssertEqual(navigator.navigate(.back, at: start), [.cleared(reason: .cancelled), .selectionChanged(nil)],
                       "while waiting, Back calls it off as any press does")
        _ = navigator.keyDown(0, at: start)
        XCTAssertEqual(navigator.navigate(.cancel, at: start), [.cleared(reason: .cancelled), .selectionChanged(nil)])
        XCTAssertTrue(navigator.tick(at: start.addingTimeInterval(5)).isEmpty, "nothing left to fire")
    }

    // MARK: The folders layout

    private func view(_ navigator: Navigator, _ config: KeybowConfig) -> KeypadView {
        KeypadView(config: config, tree: navigator.tree, path: navigator.path, page: navigator.page,
                   currentRow: navigator.currentRow, pending: navigator.pendingWindow != nil,
                   colours: Lighting().colours(for: navigator, config: config))
    }

    private let layout = FolderLayout(columns: 5, rows: 3)

    func testAtRestEachTreeHasItsRow() throws {
        let config = try config()
        let slots = layout.slots(for: view(Navigator(config: config, now: start), config))
        XCTAssertEqual(slots.count, 15)
        XCTAssertEqual(slots[0].face?.caption, "Work")
        XCTAssertEqual(slots[0].face?.icon, .symbol("briefcase.fill"))
        XCTAssertEqual(slots[0].press, .key(0))
        XCTAssertEqual(slots[5].face?.caption, "Timers", "row 2's tree")
        XCTAssertEqual(slots[5].press, .key(4))
        XCTAssertNil(slots[10].face, "no row 3 tree")
        XCTAssertEqual(slots[14].press, .showBottomTree(true), "the bottom tree is a key away")

        let bottom = layout.slots(for: view(Navigator(config: config, now: start), config), showingBottomTree: true)
        XCTAssertEqual(bottom[10].face?.caption, "Lights")
        XCTAssertEqual(bottom[10].press, .key(12), "row 4 of the keypad")
        XCTAssertEqual(bottom[4].press, .showBottomTree(false))
    }

    func testChoosingShowsThePathTheOptionsAndControls() throws {
        let config = try config()
        var navigator = Navigator(config: config, now: start)
        _ = navigator.keyDown(0, at: start)
        var slots = layout.slots(for: view(navigator, config))
        XCTAssertEqual(slots[0].face?.caption, "Work")
        XCTAssertEqual(slots[0].face?.emphasis, .chosen)
        XCTAssertEqual(slots[5].face?.caption, "Stand-up")
        XCTAssertEqual(slots[5].press, .key(4), "row 2 of the keypad")
        XCTAssertEqual(slots[6].face?.caption, "Notes")
        XCTAssertEqual(slots[4].press, .navigate(.cancel))
        XCTAssertEqual(slots[9].press, .navigate(.back))
        XCTAssertNil(slots[10].face, "the main tree: no escape row")

        _ = navigator.keyDown(5, at: start)
        slots = layout.slots(for: view(navigator, config))
        XCTAssertEqual(slots[1].face?.caption, "Notes")
        XCTAssertEqual(slots[1].press, .key(5))
        XCTAssertNil(slots[5].face?.caption, "Today has no caption")
        XCTAssertEqual(slots[5].face?.icon, .file("Icons/today.png"))
        XCTAssertEqual(slots[5].press, .key(8), "row 3")
    }

    func testASideTreeOffersTheWayBackToTheMainTree() throws {
        let config = try config()
        var navigator = Navigator(config: config, now: start)
        _ = navigator.keyDown(4, at: start)
        XCTAssertEqual(navigator.tree, .row2)
        let slots = layout.slots(for: view(navigator, config))
        XCTAssertEqual(slots[0].face?.caption, "Timers")
        XCTAssertEqual(slots[10].face?.caption, "Work")
        XCTAssertEqual(slots[10].press, .key(0))
    }

    func testAPageFillsTheGrid() throws {
        let text = """
            # main [pages]
            1. Snippets [Copy]
               1. One
               5. Five
               12. Twelve
            """
        let config = try config(text)
        var navigator = Navigator(config: config, now: start)
        _ = navigator.keyDown(0, at: start)
        XCTAssertNotNil(navigator.page)
        let slots = layout.slots(for: view(navigator, config))
        XCTAssertEqual(slots[0].face?.caption, "One")
        XCTAssertEqual(slots[0].press, .key(4))
        XCTAssertEqual(slots[5].face?.caption, "Five", "second row")
        XCTAssertEqual(slots[13].face?.caption, "Twelve")
        XCTAssertEqual(slots[13].press, .key(15))
        XCTAssertEqual(slots[4].face?.caption, "Snippets")
        XCTAssertEqual(slots[4].press, .key(0), "its own key leaves it")
    }

    func testTooSmallAKeypadShowsNothing() throws {
        let config = try config()
        let slots = FolderLayout(columns: 3, rows: 2).slots(for: view(Navigator(config: config, now: start), config))
        XCTAssertTrue(slots.allSatisfy { $0.face == nil })
    }
}
