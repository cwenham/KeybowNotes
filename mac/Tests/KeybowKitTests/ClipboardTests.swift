@testable import KeybowKit
import XCTest

/// Copying nodes as outline text, and pasting it back — into another tree, a
/// keypad's own, or a page — with the keypad's rules kept.
final class ClipboardTests: XCTestCase {
    private let outline = """
        1. Work [Copy]
           1. Standup
           3. Review
              1. Today
        2. Home [Copy]

        # row 2
        1. Capture [Copy]
           2. Idea

        # row 3 [pages]
        1. Keys [Copy]
           2. Paste

        # keypad Desk [RGB Keypad]
        1. Music [Copy]
        """

    private func parsed() -> OutlineDocument { OutlineParser.parse(outline).0 }

    private func id(_ document: OutlineDocument, _ tree: TreeKind, _ path: [Int], keypad: Int = 0) throws -> UUID {
        try XCTUnwrap(document.node(at: OutlineLocation(.tree(tree, keypad: keypad), path))?.id)
    }

    func testCopiedNodesAreOutlineText() throws {
        let document = parsed()
        let work = try id(document, .main, [0]), review = try id(document, .main, [0, 2])
        let capture = try id(document, .row2, [0])
        XCTAssertEqual(document.clipboardText([review, work, capture]),
                       "1. Work [Copy]\n   1. Standup\n   3. Review\n      1. Today\n2. Capture [Copy]\n   2. Idea\n",
                       "Review goes with Work; each numbered by its order")
    }

    func testOutlineTextBecomesNewNodes() {
        let nodes = OutlineClipboard.nodes(from: """
            Some notes, passed over
            # a heading, too
            7. Work [Copy]
               3. Review
               3. Again
               - Bulleted
            - Home
            """)
        XCTAssertEqual(nodes.map(\.label), ["Work", "Home"])
        XCTAssertEqual(nodes[0].annotations, [.word("Copy")])
        XCTAssertEqual(nodes[0].children.map { $0?.label }, ["Again", "Bulleted", "Review", nil],
                       "3 twice: the second takes the next free key")
        XCTAssertNotEqual(OutlineClipboard.nodes(from: "1. A\n")[0].id, OutlineClipboard.nodes(from: "1. A\n")[0].id)
    }

    func testPastingIntoAnotherTreeAndKeypad() throws {
        var document = parsed()
        let work = try id(document, .main, [0])
        let nodes = OutlineClipboard.nodes(from: document.clipboardText([work]))

        let music = try id(document, .main, [0], keypad: 1)
        let placed = try document.paste(nodes, .after(music))
        XCTAssertEqual(document.node(placed[0])?.label, "Work")
        XCTAssertEqual(document.location(of: placed[0]), OutlineLocation(.tree(.main, keypad: 1), [1]))
        XCTAssertEqual(document.node(placed[0])?.children[2]?.children[0]?.label, "Today", "with everything under it")
        XCTAssertNotEqual(placed[0], work, "a copy, not a move")

        let capture = try id(document, .row2, [0])
        let leaves = OutlineClipboard.nodes(from: "1. One\n2. Two\n")
        let inside = try document.paste(leaves, .inside(capture))
        XCTAssertEqual(inside.map { document.location(of: $0)?.path }, [[0, 0], [0, 2]], "around Idea, on 2")
    }

    func testOnAnEmptyKeyThenTheNextFree() throws {
        var document = parsed()
        let placed = try document.paste(OutlineClipboard.nodes(from: "1. A\n2. B\n3. C\n"),
                                        .at(OutlineLocation(.tree(.row2), [2])))
        XCTAssertEqual(placed.map { document.location(of: $0)?.path }, [[2], [3], [1]] as [[Int]?],
                       "3, 4, then round to the free key before")
    }

    func testWhatDoesntFitIsRefused() throws {
        var document = parsed()
        let home = try id(document, .main, [1])
        XCTAssertThrowsError(try document.paste(OutlineClipboard.nodes(from: "1. A\n2. B\n3. C\n"), .after(home))) { error in
            XCTAssertEqual(error as? OutlineEditError, .notEnoughRoom(free: 2, needed: 3))
        }
        let idea = try id(document, .row2, [0, 1])
        let deep = OutlineClipboard.nodes(from: "1. A\n   1. B\n      1. C\n")
        XCTAssertThrowsError(try document.paste(deep, .after(idea))) { error in
            XCTAssertEqual(error as? OutlineEditError, .tooDeep(levels: 3), "row 2's tree has three levels")
        }
        let page = OutlineClipboard.nodes(from: "1. Page\n   7. Seventh\n")
        XCTAssertThrowsError(try document.paste(page, .after(home))) { error in
            XCTAssertEqual(error as? OutlineEditError, .tooManyKeys("Page", keys: 4))
        }
        XCTAssertEqual(OutlineWriter.text(document), OutlineWriter.text(parsed()), "nothing changed")
    }

    func testPagesTakeAPagesKeys() throws {
        var document = parsed()
        let keys = try id(document, .row3, [0])
        XCTAssertThrowsError(try document.paste(OutlineClipboard.nodes(from: "1. Deep\n   1. Deeper\n"),
                                                .inside(keys))) { error in
            XCTAssertEqual(error as? OutlineEditError, .tooDeep(levels: 2), "a page's keys run actions")
        }
        // Row 3's pages hold four keys: Paste is on 2.
        let placed = try document.paste(OutlineClipboard.nodes(from: "1. A\n2. B\n3. C\n"), .inside(keys))
        XCTAssertEqual(placed.map { document.location(of: $0)?.path }, [[0, 0], [0, 2], [0, 3]] as [[Int]?])
        let newPage = try document.paste(OutlineClipboard.nodes(from: "1. More\n"), .after(keys))
        XCTAssertEqual(document.node(newPage[0])?.children.count, 4, "a page, with room for its keys")
    }

    func testCuttingSeveral() throws {
        var document = parsed()
        let work = try id(document, .main, [0]), today = try id(document, .main, [0, 2, 0])
        let idea = try id(document, .row2, [0, 1])
        XCTAssertEqual(document.topMost([today, work, idea]), [work, idea])
        try document.delete([today, work, idea])
        XCTAssertNil(document.roots(.main)[0])
        XCTAssertNil(document.roots(.row2)[0]?.children[1])
        XCTAssertEqual(document.roots(.main)[1]?.label, "Home")
    }
}
