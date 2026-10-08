@testable import KeybowKit
import XCTest

/// The tree as other apps and agents change it.
final class TreeControlTests: XCTestCase {
    private let outline = """
        1. Work [Copy]
           1. Standup
           2. Notes/Ideas

        # row 2
        1. Window Management
           1. Left Screen [Copy, text: left]
           3. Right Screen [Copy, text: right]
        3. Weather [Display]

        # keypad Desk [Keybow 2040, id: E66000000000AAAA]
        1. Desk [Copy]
           1. Lamp

        # lists
        ## people
        1. Alex
        """

    private var document: OutlineDocument { OutlineParser.parse(outline).0 }

    func testKeypadsAndTreesByName() throws {
        let document = document
        XCTAssertEqual(TreeControl.keypadNames(document), ["Default", "Desk"])
        XCTAssertEqual(try TreeControl.keypad(nil, in: document), 0)
        XCTAssertEqual(try TreeControl.keypad("default", in: document), 0)
        XCTAssertEqual(try TreeControl.keypad("desk", in: document), 1)
        XCTAssertEqual(try TreeControl.keypad("Keybow 2040", in: document), 1, "by model")
        XCTAssertEqual(try TreeControl.keypad("e66000000000aaaa", in: document), 1, "by ID")
        XCTAssertEqual(try TreeControl.keypad(nil, in: document, otherwise: 1), 1)
        XCTAssertThrowsError(try TreeControl.keypad("Lounge", in: document)) { error in
            XCTAssertEqual("\(error)", "There's no keypad “Lounge”. There's “Default” and “Desk”.")
        }
        XCTAssertEqual(try TreeControl.tree(nil), .main)
        XCTAssertEqual(try TreeControl.tree("Row 2"), .row2)
        XCTAssertEqual(try TreeControl.tree("row3"), .row3)
        XCTAssertEqual(try TreeControl.tree("bottom"), .bottom)
        XCTAssertThrowsError(try TreeControl.tree("sideways"))
    }

    func testEntriesAreFoundByTheirLabels() throws {
        let document = document
        let row2 = OutlineContainer.tree(.row2)
        XCTAssertEqual(try TreeControl.locate(TreeControl.path("window management / right screen"), in: document,
                                              container: row2).path, [0, 2])
        XCTAssertEqual(try TreeControl.locate(["Window Management", "3"], in: document, container: row2).path, [0, 2],
                       "or a key's number")
        XCTAssertEqual(try TreeControl.locate(TreeControl.path("Work/Notes/Ideas"), in: document, container: .tree(.main)).path,
                       [0, 1], "a label with a slash in it")
        XCTAssertThrowsError(try TreeControl.locate(["Window Management", "Middle"], in: document, container: row2)) { error in
            XCTAssertEqual("\(error)", "There's no “Middle” under “Window Management”. There's “Left Screen” and “Right Screen”.")
        }
    }

    func testReadingATree() {
        XCTAssertEqual(TreeControl.outline(document, keypad: 0, tree: .row2), """
            1. Window Management
               1. Left Screen [Copy, text: left]
               3. Right Screen [Copy, text: right]
            3. Weather [Display]
            """)
        XCTAssertEqual(TreeControl.leaves(document, keypad: 0, tree: .row2),
                       [["Window Management", "Left Screen"], ["Window Management", "Right Screen"], ["Weather"]])
    }

    func testAddingChangingAndRemoving() throws {
        var document = document
        let added = try TreeControl.add("Middle [Copy, text: middle]", under: ["Window Management"], keypad: 0, tree: .row2,
                                        to: &document)
        XCTAssertEqual(added, ["Middle"])
        XCTAssertEqual(try TreeControl.locate(["Window Management", "Middle"], in: document, container: .tree(.row2)).path,
                       [0, 1], "the first free key")

        try TreeControl.add("""
            1. Lights
               1. Desk lamp [Home, entity: light.desk_lamp]
            """, under: [], keypad: 0, tree: .row2, to: &document)
        XCTAssertEqual(try TreeControl.locate(["Lights", "Desk lamp"], in: document, container: .tree(.row2)).path, [1, 0])

        try TreeControl.change(["Window Management"], to: "Windows [Copy]", keypad: 0, tree: .row2, in: &document)
        XCTAssertEqual(try TreeControl.locate(["Windows", "Left Screen"], in: document, container: .tree(.row2)).path, [0, 0],
                       "what's under it stays")

        XCTAssertEqual(try TreeControl.remove(["Weather"], keypad: 0, tree: .row2, from: &document), "Weather")
        XCTAssertThrowsError(try TreeControl.locate(["Weather"], in: document, container: .tree(.row2)))

        try TreeControl.add("1. A\n2. B", under: [], keypad: 0, tree: .row2, to: &document)
        XCTAssertThrowsError(try TreeControl.add("1. C", under: [], keypad: 0, tree: .row2, to: &document)) { error in
            XCTAssertEqual("\(error)", "No free key here to paste onto.")
        }

        XCTAssertThrowsError(try TreeControl.add("", under: [], keypad: 0, tree: .row2, to: &document))
        try TreeControl.add("Spare", under: ["Desk"], keypad: 1, tree: .main, to: &document)
        XCTAssertTrue(OutlineWriter.text(document).contains("# keypad Desk [Keybow 2040, id: E66000000000AAAA]\n1. Desk [Copy]\n   1. Lamp\n   2. Spare"))
    }

    func testATreeReplacedWhole() throws {
        var document = document
        try TreeControl.replace(.row3, keypad: 0, with: """
            2. Timers [Timer]
               1. Tea [duration: 4 min]
            4. Stopwatch [Stopwatch]
            """, in: &document)
        XCTAssertEqual(TreeControl.outline(document, keypad: 0, tree: .row3), """
            2. Timers [Timer]
               1. Tea [duration: 4 min]
            4. Stopwatch [Stopwatch]
            """, "keys where they're numbered")
        XCTAssertThrowsError(try TreeControl.replace(.row3, keypad: 0, with: "1. a\n2. b\n3. c\n4. d\n5. e", in: &document))
    }

    func testCheckingSaysWhatTheCompilerWould() {
        XCTAssertEqual(TreeControl.check("1. Work [Copy]\n"), "OK: it compiles, with nothing to say.")
        XCTAssertEqual(TreeControl.check("5. Five [Copy]\n"), "line 1: couldn't be read — Item 5: keys are numbered 1 to 4.")
        XCTAssertTrue(TreeControl.check("1. Call [Call]\n").contains("to fill in: contacts: “Call” needs phone"))
    }
}
