import XCTest
@testable import KeybowKit

final class OutlineEditingTests: XCTestCase {
    private func document(_ text: String) -> OutlineDocument {
        let (document, diagnostics) = OutlineParser.parse(text)
        XCTAssertEqual(diagnostics, [])
        return document
    }

    private func id(_ document: OutlineDocument, _ path: [Int], in tree: TreeKind = .main) throws -> UUID {
        try XCTUnwrap(document.node(at: OutlineLocation(.tree(tree), path))?.id)
    }

    private func text(_ document: OutlineDocument) -> String {
        OutlineWriter.text(document)
    }

    private func assertRefused(_ expected: OutlineEditError, file: StaticString = #filePath, line: UInt = #line,
                               _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? OutlineEditError, expected, file: file, line: line)
        }
    }

    // MARK: - Inserting

    func testNewNodeGoesOnTheNextFreeKey() throws {
        var doc = document("1. A\n3. C")
        let new = try doc.insertNode(after: try id(doc, [0]), in: .tree(.main), label: "B")
        XCTAssertEqual(doc.location(of: new)?.path, [1])
        XCTAssertEqual(text(doc), "1. A\n2. B\n3. C\n")
    }

    func testNewNodeWrapsToAFreeKeyBefore() throws {
        var doc = document("2. B\n3. C\n4. D")
        let new = try doc.insertNode(after: try id(doc, [3]), in: .tree(.main), label: "A")
        XCTAssertEqual(doc.location(of: new)?.path, [0])
    }

    func testFullRowRefusesANewNode() throws {
        var doc = document("1. A\n2. B\n3. C\n4. D")
        let d = try id(doc, [3])
        assertRefused(.rowFull) { try doc.insertNode(after: d, in: .tree(.main)) }
    }

    func testTypingIntoAPlaceholder() throws {
        var doc = document("1. A\n   1. X\n   3. Z")
        try doc.insertNode(at: OutlineLocation(.tree(.main), [0, 1]), label: "Y")
        XCTAssertEqual(text(doc), "1. A\n   1. X\n   2. Y\n   3. Z\n")
        assertRefused(.notEmpty) { try doc.insertNode(at: OutlineLocation(.tree(.main), [0, 0])) }
    }

    func testPlaceholdersRespectDepth() {
        var doc = document("# row 3\n1. A\n   1. B")
        assertRefused(.tooDeep(levels: 2)) { try doc.insertNode(at: OutlineLocation(.tree(.row3), [0, 0, 0])) }
    }

    // MARK: - Indenting and outdenting

    func testIndentUnderTheNodeAbove() throws {
        var doc = document("1. Work\n   1. Old\n2. New")
        try doc.indent(try id(doc, [1]))
        XCTAssertEqual(text(doc), "1. Work\n   1. Old\n   2. New\n")
    }

    func testIndentNeedsANodeAbove() throws {
        var doc = document("1. First")
        let first = try id(doc, [0])
        assertRefused(.nothingAbove) { try doc.indent(first) }
    }

    func testIndentIntoAFullRowIsRefused() throws {
        var doc = document("1. A\n   1. a\n   2. b\n   3. c\n   4. d\n2. B")
        let b = try id(doc, [1])
        assertRefused(.rowFull) { try doc.indent(b) }
    }

    func testIndentPastTheTreeDepthIsRefused() throws {
        var doc = document("# row 3\n1. A\n   1. a\n2. B\n   1. b")
        let b = try id(doc, [1], in: .row3)
        // B has a child, so indenting it would need three levels.
        assertRefused(.tooDeep(levels: 2)) { try doc.indent(b) }
    }

    func testIndentUnderAListReferenceIsRefused() throws {
        var doc = document("1. A [@when]\n2. B\n\n# list when\n1. Today")
        let b = try id(doc, [1])
        assertRefused(.aboveUsesList) { try doc.indent(b) }
    }

    func testOutdentGoesAfterTheParent() throws {
        var doc = document("1. Work\n   1. Meeting\n   2. Notes\n3. Home")
        try doc.outdent(try id(doc, [0, 1]))
        XCTAssertEqual(text(doc), "1. Work\n   1. Meeting\n2. Notes\n3. Home\n")
    }

    func testOutdentFromTheTopIsRefused() throws {
        var doc = document("1. A")
        let a = try id(doc, [0])
        assertRefused(.alreadyAtTop) { try doc.outdent(a) }
    }

    func testOutdentIntoAFullRowIsRefused() throws {
        var doc = document("1. A\n   1. x\n2. B\n3. C\n4. D")
        let x = try id(doc, [0, 0])
        assertRefused(.rowFull) { try doc.outdent(x) }
    }

    func testIndentThenOutdentReturnsANodeWithItsChildren() throws {
        var doc = document("1. A\n2. B\n   1. b")
        let b = try id(doc, [1])
        try doc.indent(b)
        XCTAssertEqual(doc.location(of: b)?.path, [0, 0])
        try doc.outdent(b)
        XCTAssertEqual(doc.location(of: b)?.path, [1])
        XCTAssertEqual(doc.node(b)?.children[0]?.label, "b", "children travel with it")
    }

    // MARK: - Moving and deleting

    func testMoveSwapsWithTheNeighbour() throws {
        var doc = document("1. A\n2. B")
        try doc.move(try id(doc, [0]), by: 1)
        XCTAssertEqual(text(doc), "1. B\n2. A\n")
    }

    func testMoveIntoAnEmptyKey() throws {
        var doc = document("1. A\n3. C")
        let a = try id(doc, [0])
        try doc.move(a, by: 1)
        XCTAssertEqual(doc.location(of: a)?.path, [1])
    }

    func testMoveStopsAtTheEdges() throws {
        var doc = document("1. A\n4. D")
        let a = try id(doc, [0]), d = try id(doc, [3])
        assertRefused(.atEdge) { try doc.move(a, by: -1) }
        assertRefused(.atEdge) { try doc.move(d, by: 1) }
    }

    func testDeleteTakesTheSubtree() throws {
        var doc = document("1. A\n   1. a\n2. B")
        try doc.delete(try id(doc, [0]))
        XCTAssertEqual(text(doc), "2. B\n")
    }

    // MARK: - Content

    func testSetTextKeepsChildrenAndIdentity() throws {
        var doc = document("1. Meeting\n   1. Today")
        let meeting = try id(doc, [0])
        try doc.setText(meeting, "Meeting [Calendar, 5 min alert]")
        XCTAssertEqual(doc.node(meeting)?.annotations, [.word("Calendar"), .word("5 min alert")])
        XCTAssertEqual(doc.node(meeting)?.children[0]?.label, "Today")
    }

    func testSetPairUpdatesInPlaceAddsAndRemoves() throws {
        var doc = document("1. Meeting [Calendar, duration: 30m, 5 min alert]")
        let meeting = try id(doc, [0])
        try doc.setPair(meeting, key: "duration", value: "1h")
        XCTAssertEqual(doc.node(meeting)?.text, "Meeting [Calendar, duration: 1h, 5 min alert]", "updated where it stands")
        try doc.setPair(meeting, key: "calendar", value: "Home")
        XCTAssertEqual(doc.node(meeting)?.text, "Meeting [Calendar, duration: 1h, 5 min alert, calendar: Home]")
        try doc.setPair(meeting, key: "duration", value: nil)
        XCTAssertEqual(doc.node(meeting)?.text, "Meeting [Calendar, 5 min alert, calendar: Home]")
    }

    func testSetTypeReplacesTheKeyword() throws {
        var doc = document("1. Docs [append, template.md]")
        let docs = try id(doc, [0])
        try doc.setType(docs, "calendar.createEvent")
        XCTAssertEqual(doc.node(docs)?.text, "Docs [Calendar, template.md]")
        try doc.setType(docs, "shortcut")
        XCTAssertEqual(doc.node(docs)?.text, "Docs [type: shortcut, template.md]")
        try doc.setType(docs, nil)
        XCTAssertEqual(doc.node(docs)?.text, "Docs [template.md]")
    }

    func testEntryFields() {
        var doc = document("1. A\n\n# contacts\n- Alex [phone: 1]")
        doc.setEntryField(.contacts, name: "Alex", key: "phone", value: "2")
        doc.setEntryField(.contacts, name: "Sam", key: "email", value: "sam@example.com")
        XCTAssertEqual(doc.contacts.map(\.name), ["Alex", "Sam"])
        XCTAssertEqual(doc.contacts[0].value("phone"), "2")
        XCTAssertEqual(doc.contacts[1].value("email"), "sam@example.com")
    }

    func testRefusedEditsLeaveTheDocumentAlone() throws {
        var doc = document("1. A\n   1. x\n2. B\n3. C\n4. D")
        let before = text(doc)
        let x = try id(doc, [0, 0])
        _ = try? doc.outdent(x)
        XCTAssertEqual(text(doc), before)
    }
}
