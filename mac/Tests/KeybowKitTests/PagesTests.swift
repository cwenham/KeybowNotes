@testable import KeybowKit
import XCTest

/// Trees set as pages: a row of page keys, each turning the rows below into
/// keys that run their actions at once, until another page — or a row above.
final class PagesTests: XCTestCase {
    private let outline = """
        1. Work [colour: 0000ff]
           1. Standup [Copy]

        # row 2 [pages]
        1. Editing [colour: 00ff00, Copy]
           1. Cut
           2. Paste
           6. Undo [colour: ff0000]
        2. Music [colour: ff8000, Copy]
           8. Next

        # row 3
        1. Timers [Copy]
        """

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func config(_ text: String? = nil) throws -> KeybowConfig {
        let (document, problems) = OutlineParser.parse(text ?? outline)
        XCTAssertEqual(problems, [])
        return try XCTUnwrap(OutlineCompiler.compile(document, locateApp: { _ in nil }).config)
    }

    // MARK: The outline

    func testAPageHoldsEveryKeyOnTheRowsBelow() throws {
        let (document, problems) = OutlineParser.parse(outline)
        XCTAssertEqual(problems, [])
        XCTAssertEqual(document.pages, [.row2])
        XCTAssertTrue(document.isPaged(.row2))
        XCTAssertFalse(document.isPaged(.main))
        let editing = try XCTUnwrap(document.roots(.row2)[0])
        XCTAssertEqual(editing.children.count, 8, "rows 3 and 4")
        XCTAssertEqual(editing.children[5]?.label, "Undo", "6: row 4, key 2")
        XCTAssertEqual(TreeKind.row2.key(onPage: 5), 13)
        XCTAssertEqual(TreeKind.main.pageKeys, 12)
        XCTAssertEqual(TreeKind.row3.pageKeys, 4)
        XCTAssertEqual(TreeKind.bottom.pageKeys, 0)
    }

    func testItWritesBackAsItReads() {
        let (document, _) = OutlineParser.parse(outline)
        let written = OutlineWriter.text(document)
        XCTAssertTrue(written.contains("# row 2 [pages]\n1. Editing [colour: 00ff00, Copy]\n   1. Cut\n   2. Paste\n   6. Undo"),
                      written)
        XCTAssertEqual(OutlineWriter.text(OutlineParser.parse(written).0), written)

        let main = OutlineParser.parse("# main [pages]\n1. Keys\n   12. Last\n").0
        XCTAssertEqual(OutlineWriter.text(main), "# main [pages]\n1. Keys\n   12. Last\n", "the main tree needs its heading")
        let empty = OutlineParser.parse("# row 3 [pages]\n").0
        XCTAssertEqual(OutlineWriter.text(empty), "# row 3 [pages]\n", "kept, empty")
    }

    func testMistakesInPagesAreCaught() {
        let (_, problems) = OutlineParser.parse("""
            # row 2 [pages]
            1. Editing
               9. Too far
               1. Cut
                  1. Under a key
            # bottom [pages]
            1. Up
            """)
        XCTAssertEqual(problems.map(\.message), [
            "Item 9: this page's keys are numbered 1 to 8.",
            "Too deep: a page's keys run actions, and can't have keys under them.",
            "The bottom tree can't be pages: there are no rows below it.",
        ])
    }

    func testTheCompiledFormNamesThePages() throws {
        let (document, _) = OutlineParser.parse(outline)
        let compiled = OutlineCompiler.compile(document, locateApp: { _ in nil })
        XCTAssertTrue(compiled.json.contains("\"pages\": [\n    \"row2\"\n  ]"), compiled.json)
        let config = try XCTUnwrap(compiled.config)
        XCTAssertEqual(config.pages, [.row2])
        XCTAssertEqual(config.node(in: .row2, at: [0, 5])?.label, "Undo")
        XCTAssertEqual(config.node(in: .row2, at: [1, 7])?.label, "Next")
        let undo = try XCTUnwrap(config.resolve(tree: .row2, path: [0, 5]))
        XCTAssertEqual(config.commitDelay(for: undo), 0, "a page's keys run at once")
        XCTAssertEqual(undo.action?.type, "clipboard.copy", "inherited from the page")
    }

    func testAnEmptyPageIsNoted() {
        let (document, _) = OutlineParser.parse("# row 3 [pages]\n1. Nothing yet\n")
        let compiled = OutlineCompiler.compile(document, locateApp: { _ in nil })
        let problems = compiled.diagnostics.map(\.message)
        XCTAssertEqual(problems, ["An empty page: its keys are the items under it."])
    }

    func testAKeypadsOwnTreesCanBePages() throws {
        let (document, _) = OutlineParser.parse("""
            1. Work [Copy]

            # keypad Desk [RGB Keypad]
            # main [pages]
            1. Macros [Copy]
               12. Last
            """)
        XCTAssertTrue(document.isPaged(.main, keypad: 1))
        XCTAssertFalse(document.isPaged(.main))
        let config = try XCTUnwrap(OutlineCompiler.compile(document, locateApp: { _ in nil }).config)
        XCTAssertEqual(config.forKeypad(1).pages, [.main])
        XCTAssertEqual(config.forKeypad(1).node(in: .main, at: [0, 11])?.label, "Last")
        XCTAssertEqual(config.pages, [])
    }

    // MARK: Pressing keys

    func testAPageStaysAndItsKeysRunAtOnce() throws {
        var navigator = Navigator(config: try config(), now: start)
        guard case .page(let page?)? = navigator.keyDown(4, at: start).first else { return XCTFail("no page") }
        XCTAssertEqual(page.node.label, "Editing")
        XCTAssertEqual(navigator.page, KeypadPage(tree: .row2, column: 0))
        XCTAssertNil(navigator.tree, "nothing being chosen")

        let cut = navigator.keyDown(8, at: start)
        guard case .fire(let selection, _)? = cut.first, cut.count == 1 else { return XCTFail("\(cut)") }
        XCTAssertEqual(selection.labels, ["Editing", "Cut"])
        XCTAssertEqual(navigator.page, KeypadPage(tree: .row2, column: 0), "still on the page")

        guard case .fire(let undo, _)? = navigator.keyDown(13, at: start).first else { return XCTFail() }
        XCTAssertEqual(undo.labels, ["Editing", "Undo"])
        XCTAssertEqual(navigator.keyDown(15, at: start), [.invalidPress(key: 15)], "nothing on that key")

        // Neither waiting nor holding a key lets go of it.
        _ = navigator.keyDown(9, at: start)
        XCTAssertTrue(navigator.tick(at: start.addingTimeInterval(60)).isEmpty)
        XCTAssertEqual(navigator.page, KeypadPage(tree: .row2, column: 0))
    }

    func testAnotherPageOrTheSameKeyAgain() throws {
        var navigator = Navigator(config: try config(), now: start)
        _ = navigator.keyDown(4, at: start)
        guard case .page(let music?)? = navigator.keyDown(5, at: start).first else { return XCTFail() }
        XCTAssertEqual(music.node.label, "Music")
        guard case .fire(let next, _)? = navigator.keyDown(15, at: start).first else { return XCTFail() }
        XCTAssertEqual(next.labels, ["Music", "Next"])
        XCTAssertEqual(navigator.keyDown(8, at: start), [.invalidPress(key: 8)], "Cut was Editing's")

        XCTAssertEqual(navigator.keyDown(5, at: start), [.page(nil)], "its own key again: back to the trees")
        XCTAssertNil(navigator.page)
        guard case .selectionChanged(let timers?)? = navigator.keyDown(8, at: start).first else { return XCTFail() }
        XCTAssertEqual(timers.labels, ["Timers"], "row 3 is its own tree again")
    }

    func testARowAboveGoesBackToTheTreesAndCounts() throws {
        var navigator = Navigator(config: try config(), now: start)
        _ = navigator.keyDown(4, at: start)
        let events = navigator.keyDown(0, at: start)
        XCTAssertEqual(events.first, .page(nil))
        guard case .selectionChanged(let work?)? = events.dropFirst().first else { return XCTFail("\(events)") }
        XCTAssertEqual(work.labels, ["Work"], "the press starts the main tree")
        XCTAssertNil(navigator.page)
        XCTAssertEqual(navigator.tree, .main)
    }

    func testTheMainTreeChoosesBeforeItsRowsPages() throws {
        var navigator = Navigator(config: try config(), now: start)
        _ = navigator.keyDown(0, at: start)                  // Work
        guard case .selectionChanged(let standup?)? = navigator.keyDown(4, at: start).first else { return XCTFail() }
        XCTAssertEqual(standup.labels, ["Work", "Standup"], "row 2 is the main tree's next row while it's in play")
        XCTAssertNil(navigator.page)
    }

    func testPagesOnTheTopRowLeaveOnlyByTheirOwnKey() throws {
        var navigator = Navigator(config: try config("# main [pages]\n1. Keys [Copy]\n   12. Last\n# bottom\n1. Up [Copy]\n"),
                                  now: start)
        _ = navigator.keyDown(0, at: start)
        guard case .fire(let last, _)? = navigator.keyDown(15, at: start).first else { return XCTFail() }
        XCTAssertEqual(last.labels, ["Keys", "Last"])
        XCTAssertEqual(navigator.keyDown(12, at: start), [.invalidPress(key: 12)], "the bottom row is the page's")
        XCTAssertEqual(navigator.keyDown(0, at: start), [.page(nil)])
        guard case .selectionChanged(let up?)? = navigator.keyDown(12, at: start).first else { return XCTFail() }
        XCTAssertEqual(up.labels, ["Up"])
    }

    func testAPageSurvivesAReloadIfItsStillThere() throws {
        var navigator = Navigator(config: try config(), now: start)
        _ = navigator.keyDown(5, at: start)
        var reloaded = Navigator(config: try config(), now: start)
        reloaded.restore(page: navigator.page)
        XCTAssertEqual(reloaded.page, KeypadPage(tree: .row2, column: 1))
        var gone = Navigator(config: try config("# row 2\n1. Editing [Copy]\n2. Music [Copy]\n"), now: start)
        gone.restore(page: navigator.page)
        XCTAssertNil(gone.page, "no longer pages")
    }

    // MARK: Lights

    func testAPageLightsInItsColour() throws {
        let config = try config()
        var navigator = Navigator(config: config, now: start)
        _ = navigator.keyDown(4, at: start)
        let lighting = Lighting()
        let colours = lighting.colours(for: navigator, config: config, firing: 9, now: start)
        let green = KeyColour(red: 0, green: 255, blue: 0)
        func dim(_ colour: KeyColour, _ level: Double) -> KeyColour {
            KeyColour(red: UInt8((Double(colour.red) * level).rounded()), green: UInt8((Double(colour.green) * level).rounded()),
                      blue: UInt8((Double(colour.blue) * level).rounded()))
        }
        XCTAssertEqual(colours[4], green, "the page's key, lit")
        XCTAssertEqual(colours[5], dim(KeyColour(red: 255, green: 128, blue: 0), 0.35), "another page, on offer")
        XCTAssertEqual(colours[8], dim(green, 0.35), "its keys in its colour")
        XCTAssertEqual(colours[9], green, "pressed: bright as it runs")
        XCTAssertEqual(colours[13], dim(KeyColour(red: 255, green: 0, blue: 0), 0.35), "unless they have their own")
        XCTAssertEqual(colours[12], .off, "an empty key")
        XCTAssertEqual(colours[0], dim(KeyColour(red: 0, green: 0, blue: 255), 0.1), "the row above, faintly")
    }

    // MARK: Editing

    func testATreeBecomesPagesOnlyWhereItFits() throws {
        var (document, _) = OutlineParser.parse("# row 2\n1. Deep\n   1. Deeper\n      1. Deepest\n")
        XCTAssertThrowsError(try document.setPages(true, for: .row2)) { error in
            XCTAssertEqual(error as? OutlineEditError, .tooDeepForPages)
        }
        XCTAssertThrowsError(try document.setPages(true, for: .bottom)) { error in
            XCTAssertEqual(error as? OutlineEditError, .noRoomForPages)
        }

        (document, _) = OutlineParser.parse("# row 2\n1. Editing\n   1. Cut\n")
        try document.setPages(true, for: .row2)
        XCTAssertTrue(document.isPaged(.row2))
        let page = OutlineLocation(.tree(.row2), [0, 7])
        XCTAssertEqual(document.levels(.tree(.row2)), 2)
        let id = try document.insertNode(at: page, label: "Eighth")
        XCTAssertEqual(document.node(id)?.label, "Eighth")
        XCTAssertThrowsError(try document.insertNode(at: OutlineLocation(.tree(.row2), [0, 0, 0]))) { error in
            XCTAssertEqual(error as? OutlineEditError, .tooDeep(levels: 2))
        }

        XCTAssertThrowsError(try document.setPages(false, for: .row2)) { error in
            XCTAssertEqual(error as? OutlineEditError, .pagesTooBig, "the eighth key has nowhere to go")
        }
        try document.delete(id)
        try document.setPages(false, for: .row2)
        XCTAssertEqual(document.roots(.row2)[0]?.children.count, 4)
        XCTAssertEqual(OutlineWriter.text(document), "# row 2\n1. Editing\n   1. Cut\n")
    }

    func testKeysGoOnAPagesNextFreeKey() throws {
        var (document, _) = OutlineParser.parse("# row 3 [pages]\n1. One\n   1. a\n   2. b\n   3. c\n   4. d\n2. Two\n")
        let two = try XCTUnwrap(document.roots(.row3)[1]?.id)
        XCTAssertThrowsError(try document.indent(two)) { error in
            XCTAssertEqual(error as? OutlineEditError, .rowFull, "a row 3 page holds four")
        }
        (document, _) = OutlineParser.parse("# row 2 [pages]\n1. One\n   1. a\n   2. b\n   3. c\n   4. d\n2. Two\n")
        try document.indent(XCTUnwrap(document.roots(.row2)[1]?.id))
        XCTAssertEqual(document.roots(.row2)[0]?.children[4]?.label, "Two", "on to row 4")
    }
}
