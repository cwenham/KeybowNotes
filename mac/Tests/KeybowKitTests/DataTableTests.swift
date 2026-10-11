@testable import KeybowKit
import XCTest

final class DataTableTests: XCTestCase {
    private func cells(_ table: DataTable) -> [[String]] { table.rows.map(\.cells) }

    func testCSVWithQuotesCommasAndNewLines() throws {
        let table = try DataTable.read("Name,Note\r\n\"Doe, Ann\",\"said \"\"hi\"\"\nthen left\"\r\nBob,\r\n")
        XCTAssertEqual(table.columns, ["Name", "Note"])
        XCTAssertEqual(cells(table), [["Doe, Ann", "said \"hi\"\nthen left"], ["Bob", ""]])
    }

    func testCellsCopiedFromASpreadsheetAreTabSeparated() throws {
        let table = try DataTable.read("Item\tQty\tPrice\nPens\t3\t£1.20\nInk\t1\t£4.00")
        XCTAssertEqual(DataTable.guess("Item\tQty\nPens\t3"), .tsv)
        XCTAssertEqual(table.columns, ["Item", "Qty", "Price"])
        XCTAssertEqual(table.cell(1, "price"), "£4.00", "names match ignoring case")
        XCTAssertEqual(table.cell(0, "2"), "3", "and by number")
    }

    func testSemicolonsForCSVWrittenWithDecimalCommas() throws {
        let table = try DataTable.read("Name;Amount\nAnn;1,50\nBob;2,25")
        XCTAssertEqual(cells(table), [["Ann", "1,50"], ["Bob", "2,25"]])
    }

    func testProseWithCommasIsLinesNotCSV() {
        XCTAssertEqual(DataTable.guess("Hello, world.\nHow are you, Bob? Fine, thanks."), .lines)
        XCTAssertEqual(DataTable.guess("one, two"), .lines, "a single line isn't a table")
    }

    func testLinesLoseTheirBullets() throws {
        let table = try DataTable.read("- Milk\n- Eggs\n\n- Bread")
        XCTAssertEqual(table.columns, ["1"])
        XCTAssertEqual(cells(table), [["Milk"], ["Eggs"], ["Bread"]])
        XCTAssertEqual(cells(try DataTable.read("1. One\n2) Two")), [["One"], ["Two"]])
        XCTAssertEqual(cells(try DataTable.read("- Milk\nEggs")), [["- Milk"], ["Eggs"]], "only when every line has one")
    }

    func testMarkdownTable() throws {
        let table = try DataTable.read("| Name | Role |\n|---|:--:|\n| Ann | Lead \\| Dev |\n| Bob | QA |")
        XCTAssertEqual(table.columns, ["Name", "Role"])
        XCTAssertEqual(cells(table), [["Ann", "Lead | Dev"], ["Bob", "QA"]])
    }

    func testJSONObjectsFlattenedWithListsInside() throws {
        let json = #"[{"title": "Fix", "number": 7, "user": {"login": "ann"}, "labels": ["bug", "ui"], "done": false},"#
            + #" {"title": "Ship", "number": 8.5, "user": {"login": "bob"}, "labels": [], "extra": null}]"#
        let table = try DataTable.read(json)
        XCTAssertEqual(table.columns, ["done", "labels", "number", "title", "user.login", "extra"])
        XCTAssertEqual(cells(table)[0], ["false", "bug, ui", "7", "Fix", "ann", ""])
        XCTAssertEqual(cells(table)[1], ["", "", "8.5", "Ship", "bob", ""])
        XCTAssertEqual(table.list(0, "labels").map(cells), [["bug"], ["ui"]])
    }

    func testJSONArraysOfArraysHaveAHeaderRowLikeCSV() throws {
        let table = try DataTable.read(#"[["Name", "Age"], ["Ann", 31]]"#)
        XCTAssertEqual(table.columns, ["Name", "Age"])
        XCTAssertEqual(cells(table), [["Ann", "31"]])
        let numbered = try DataTable.read(#"[["Ann", 31]]"#, columns: .numbered)
        XCTAssertEqual(numbered.columns, ["1", "2"])
    }

    func testAnObjectIsOneRowAndPlainValuesOneColumn() throws {
        XCTAssertEqual(cells(try DataTable.read(#"{"a": 1, "b": "x"}"#)), [["1", "x"]])
        XCTAssertEqual(cells(try DataTable.read(#"["x", 2, true]"#)), [["x"], ["2"], ["true"]])
    }

    func testColumnsNamedWhenTheDataHasNoHeader() throws {
        let table = try DataTable.read("Ann,31\nBob,40", columns: .named(["Name", "Age"]))
        XCTAssertEqual(table.columns, ["Name", "Age"])
        XCTAssertEqual(cells(table), [["Ann", "31"], ["Bob", "40"]])
    }

    func testForcedFormatThatDoesntFit() {
        XCTAssertThrowsError(try DataTable.read("not json", format: .json))
    }

    func testNumbers() {
        XCTAssertEqual(DataTable.number("1,200.50")?.value, 1200.5)
        XCTAssertEqual(DataTable.number("1,200.50")?.decimals, 2)
        XCTAssertEqual(DataTable.number("£12")?.value, 12)
        XCTAssertEqual(DataTable.number("(3.00)")?.value, -3)
        XCTAssertEqual(DataTable.number("1.200,5")?.value, 1200.5)
        XCTAssertEqual(DataTable.number("1,5")?.value, 1.5)
        XCTAssertEqual(DataTable.number("-7")?.value, -7)
        XCTAssertNil(DataTable.number("2026-10-11"))
        XCTAssertNil(DataTable.number("ten"))
        XCTAssertNil(DataTable.number(""))
    }

    func testComparingCells() {
        XCTAssertEqual(DataTable.compare("9", "10"), .orderedAscending)
        XCTAssertEqual(DataTable.compare("item 2", "item 10"), .orderedAscending)
        XCTAssertEqual(DataTable.compare("2026-01-31", "2026-02-01"), .orderedAscending)
    }
}
