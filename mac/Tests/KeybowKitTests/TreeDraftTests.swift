@testable import KeybowKit
import XCTest

/// Trees drafted by Claude: what it's asked, and how the draft goes in.
final class TreeDraftTests: XCTestCase {
    private let mine = """
        1. Work [Copy]
           1. Standup

        # keypad Desk [Keybow 2040]
        1. Desk [Copy]

        # list moods
        1. Calm

        # contacts
        - Alex Example [phone: +15550100]
        """

    private let reply = """
        Here's a draft.

        ```outline
        1. Writing [colour: 8040ff]
           1. Idea [append, find.byName: Ideas]

        # row 2 [pages]
        1. Lights
           1. Lamp [Home, entity: light.desk_lamp]

        # list moods
        1. Anxious

        # list durations
        1. 5 min

        # contacts
        - Alex Example [phone: +15550199]
        - Sam Sample [email: sam@example.com]
        ```

        The main tree is for writing; row 2 is a page of lights.
        """

    func testTheOutlineAndTheNoteAreFoundInTheReply() {
        let outline = TreeDraft.outline(in: reply)
        XCTAssertTrue(outline?.hasPrefix("1. Writing [colour: 8040ff]") == true)
        XCTAssertTrue(outline?.hasSuffix("- Sam Sample [email: sam@example.com]") == true)
        XCTAssertEqual(TreeDraft.note(in: reply), "Here's a draft.\n\nThe main tree is for writing; row 2 is a page of lights.")
        XCTAssertEqual(TreeDraft.outline(in: "```\n1. A\n```"), "1. A", "any block, if none says outline")
        XCTAssertNil(TreeDraft.outline(in: "No block here."))
    }

    func testMistakesAreWhatMustBeFixed() {
        XCTAssertNil(TreeDraft.mistakes(TreeDraft.outline(in: reply)!))
        XCTAssertEqual(TreeDraft.mistakes("5. Five [Copy]"), "line 1: couldn't be read — Item 5: keys are numbered 1 to 4.\nthere are no trees in it")
        XCTAssertNil(TreeDraft.mistakes("1. Call [Call]"), "what's to fill in isn't a mistake")
    }

    func testANewKeypadGetsItsTrees() throws {
        var document = OutlineParser.parse(mine).0
        let said = try TreeDraft.apply(TreeDraft.outline(in: reply)!, scope: .newKeypad(name: "Desk", model: .rgbKeypad),
                                       to: &document)
        XCTAssertEqual(said, "Put the draft in “Desk 2”, with 1 list and 1 contact.")
        XCTAssertEqual(TreeControl.keypadNames(document), ["Default", "Desk", "Desk 2"])
        XCTAssertEqual(document.keypads[1].model, .rgbKeypad)
        XCTAssertEqual(TreeControl.outline(document, keypad: 2, tree: .main), "1. Writing [colour: 8040ff]\n   1. Idea [append, find.byName: Ideas]")
        XCTAssertTrue(document.isPaged(.row2, keypad: 2))
        XCTAssertEqual(document.lists.map(\.name), ["moods", "durations"], "a list there already is kept as it is")
        XCTAssertEqual(document.contacts.map(\.name), ["Alex Example", "Sam Sample"], "and so is a contact")
        XCTAssertEqual(TreeControl.outline(document, keypad: 0, tree: .main), "1. Work [Copy]\n   1. Standup", "Default untouched")
    }

    func testAKeypadsTreesAreReplaced() throws {
        var document = OutlineParser.parse(mine).0
        try TreeDraft.apply(TreeDraft.outline(in: reply)!, scope: .keypad(1), to: &document)
        XCTAssertEqual(TreeControl.outline(document, keypad: 1, tree: .main), "1. Writing [colour: 8040ff]\n   1. Idea [append, find.byName: Ideas]")
        XCTAssertEqual(document.keypads.count, 1)
    }

    func testOneTreeWhateverItsHeading() throws {
        var document = OutlineParser.parse(mine).0
        let said = try TreeDraft.apply("# row 2\n1. Timers [Timer]\n   1. Tea [duration: 4 min]", scope: .tree(.row3, keypad: 0),
                                       to: &document)
        XCTAssertEqual(said, "Put the draft in the row 3 tree of “Default”.")
        XCTAssertEqual(TreeControl.outline(document, keypad: 0, tree: .row3), "1. Timers [Timer]\n   1. Tea [duration: 4 min]")
        XCTAssertEqual(TreeControl.outline(document, keypad: 0, tree: .main), "1. Work [Copy]\n   1. Standup", "the rest untouched")
    }

    // MARK: In conversation

    func testAFollowUpCarriesTheDraftAsItStands() {
        let said = TreeDraft.followUp("  Put the lamp on its own page.  ", current: "1. Writing\n   1. Idea")
        XCTAssertTrue(said.contains("```outline\n1. Writing\n   1. Idea\n```"))
        XCTAssertTrue(said.contains("# What I'd like\n\nPut the lamp on its own page."))
        XCTAssertTrue(said.contains("If I'm only asking something, just answer"))
    }

    func testTheDraftedPartAsOutline() throws {
        var document = OutlineParser.parse(mine).0
        try TreeDraft.apply(TreeDraft.outline(in: reply)!, scope: .newKeypad(name: "Pad", model: nil), to: &document)
        let part = TreeDraft.outline(of: document, scope: .keypad(2))
        XCTAssertTrue(part.hasPrefix("1. Writing [colour: 8040ff]"))
        XCTAssertTrue(part.contains("# row 2 [pages]\n1. Lights"))
        XCTAssertTrue(part.contains("# list moods"), "the lists, for what uses them")
        XCTAssertFalse(part.contains("Work"), "not the other keypads' trees")
        XCTAssertEqual(TreeDraft.outline(of: document, scope: .tree(.main, keypad: 0)).components(separatedBy: "\n").prefix(2),
                       ["1. Work [Copy]", "   1. Standup"])
    }

    func testEarlierDraftsAreLeftOutOfTheConversation() {
        XCTAssertEqual(TreeDraft.withoutOutline("Here.\n```outline\n1. A\n```\nDone."),
                       "Here.\n(an earlier draft, since changed)\nDone.")
    }

    func testADraftIsCarriedIntoTheTree() throws {
        let original = OutlineParser.parse(mine).0
        var draft = original
        try TreeDraft.apply(TreeDraft.outline(in: reply)!, scope: .newKeypad(name: "Pad", model: .rgbKeypad), to: &draft)
        var mineNow = original
        var said = try TreeDraft.carry(from: draft, original: original, scope: .keypad(2), asNewSection: true, into: &mineNow)
        XCTAssertEqual(said, "Added “Pad” to your tree, with 1 list and 1 contact.")
        XCTAssertEqual(TreeControl.keypadNames(mineNow), ["Default", "Desk", "Pad"])
        XCTAssertEqual(mineNow.keypads[1].model, .rgbKeypad)
        XCTAssertTrue(mineNow.isPaged(.row2, keypad: 2))

        // Changed again in the draft, and added again: the same section, updated.
        try draft.setText(draft.roots(.main, keypad: 2)[0]!.id, "Prose [colour: 8040ff]")
        said = try TreeDraft.carry(from: draft, original: original, scope: .keypad(2), asNewSection: false, into: &mineNow)
        XCTAssertEqual(said, "Replaced the trees of “Pad”.")
        XCTAssertEqual(TreeControl.keypadNames(mineNow), ["Default", "Desk", "Pad"])
        XCTAssertEqual(mineNow.roots(.main, keypad: 2)[0]?.label, "Prose")
        XCTAssertEqual(mineNow.lists.count, 2, "nothing added twice")

        // One tree, of a keypad that's there.
        var tree = original
        try TreeDraft.apply("1. Tea [Timer]", scope: .tree(.row3, keypad: 1), to: &tree)
        var mineAgain = original
        said = try TreeDraft.carry(from: tree, original: original, scope: .tree(.row3, keypad: 1), asNewSection: false,
                                   into: &mineAgain)
        XCTAssertEqual(said, "Replaced the row 3 tree of “Desk”.")
        XCTAssertEqual(TreeControl.outline(mineAgain, keypad: 1, tree: .row3), "1. Tea [Timer]")
    }

    func testTheRequestSaysWhatAndWithWhat() {
        let document = OutlineParser.parse(mine).0
        let request = TreeDraft.request(
            "Writing, and the lights in my study.", scope: .tree(.row2, keypad: 1), document: document,
            context: TreeDraft.Context(outline: mine, keypads: ["Keybow 2040, using “Desk”"], apps: ["Ulysses", "Safari"],
                                       shortcuts: ["Focus"], homeEntities: ["light.desk_lamp — Desk lamp"]))
        XCTAssertTrue(request.contains("Writing, and the lights in my study."))
        XCTAssertTrue(request.contains("Draft the row 2 tree of the keypad “Desk”"))
        XCTAssertTrue(request.contains("Apps installed: Ulysses, Safari."))
        XCTAssertTrue(request.contains("- light.desk_lamp — Desk lamp"))
        XCTAssertTrue(request.contains("- Alex Example [phone: +15550100]"), "the file, when it's sent")
        let bare = TreeDraft.request("x", scope: .newKeypad(name: "Pad", model: nil), document: document, context: TreeDraft.Context())
        XCTAssertTrue(bare.contains("Home Assistant isn't set up"))
        XCTAssertFalse(bare.contains("My tree file"))
    }
}
