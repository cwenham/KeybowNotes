@testable import KeybowKit
import XCTest

/// The tree file, read and written — and where KeybowNotes keeps it.
final class OutlineFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("OutlineFileTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testWritingKeepsTheVersionBefore() throws {
        let file = OutlineFile(folder.appendingPathComponent("tree.md"))
        XCTAssertEqual(file.text(), "", "none yet")
        XCTAssertThrowsError(try file.contents())

        try file.write("1. First")
        XCTAssertEqual(file.text(), "1. First")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.previous.path), "nothing before it")

        try file.write("1. Second")
        XCTAssertEqual(file.text(), "1. Second")
        XCTAssertEqual(try String(contentsOf: file.previous, encoding: .utf8), "1. First")
        XCTAssertEqual(file.previous.lastPathComponent, "tree.md.previous")

        let (document, problems) = file.read()
        XCTAssertEqual(problems, [])
        XCTAssertEqual(document.roots(.main).compactMap { $0?.label }, ["Second"])
        try file.write(document)
        XCTAssertEqual(try String(contentsOf: file.previous, encoding: .utf8), "1. Second")
    }

    func testWhereTheTreeIs() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OutlineFileTests-\(UUID().uuidString)"))
        XCTAssertEqual(AppLocations.tree(chosenIn: defaults), AppLocations.defaultTree)
        XCTAssertEqual(AppLocations.tree(chosenIn: nil), AppLocations.defaultTree)
        defaults.set("/tmp/elsewhere/tree.md", forKey: AppLocations.treePathKey)
        XCTAssertEqual(AppLocations.tree(chosenIn: defaults).path, "/tmp/elsewhere/tree.md", "chosen in Settings")
        defaults.set("", forKey: AppLocations.treePathKey)
        XCTAssertEqual(AppLocations.tree(chosenIn: defaults), AppLocations.defaultTree)

        let json = URL(fileURLWithPath: "/tmp/test/config.json")
        XCTAssertEqual(AppLocations.outline(for: json).path, "/tmp/test/tree.md")
        XCTAssertEqual(AppLocations.outline(for: AppLocations.defaultTree), AppLocations.defaultTree)
        XCTAssertEqual(AppLocations.defaultTree.lastPathComponent, "tree.md")
    }

    func testTreesByName() {
        XCTAssertEqual(TreeKind.allCases.map(\.name), ["main", "row 2", "row 3", "bottom"])
        XCTAssertEqual(TreeKind.allCases.map(\.title), ["Main", "Row 2", "Row 3", "Bottom"])
        for tree in TreeKind.allCases {
            XCTAssertEqual(TreeKind(name: tree.name), tree, "read back as written")
        }
    }
}
