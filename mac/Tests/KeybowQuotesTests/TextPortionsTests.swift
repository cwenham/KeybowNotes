@testable import KeybowQuotes
import XCTest

final class TextPortionsTests: XCTestCase {
    private func plain(_ text: String) throws -> [String] { try TextPortions.portions(of: text, format: .plain) }
    private func markdown(_ text: String, heading: String? = nil) throws -> [String] {
        try TextPortions.portions(of: text, format: .markdown, heading: heading)
    }
    private func html(_ text: String, heading: String? = nil) throws -> [String] {
        try TextPortions.portions(of: text, format: .html, heading: heading)
    }

    // MARK: Plain text

    func testParagraphsBetweenBlankLines() throws {
        XCTAssertEqual(try plain("""

            The impediment to action
            advances action.

               \t
            What stands in the way
            becomes the way.


            """), ["The impediment to action\nadvances action.", "What stands in the way\nbecomes the way."])
    }

    func testOneALineWhenThereAreNoBlankLines() throws {
        XCTAssertEqual(try plain("Carpe diem\nMemento mori\r\nAmor fati\n"), ["Carpe diem", "Memento mori", "Amor fati"])
    }

    func testFortuneFiles() throws {
        XCTAssertEqual(try plain("""
            A day without sunshine
            is like night.
            %
            Never trust a computer
            you can't throw out a window.

            %
            %
            """), ["A day without sunshine\nis like night.", "Never trust a computer\nyou can't throw out a window."])
    }

    func testNothingIsNothing() throws {
        XCTAssertEqual(try plain(" \n\n "), [])
    }

    func testPlainTextHasNoHeadings() {
        XCTAssertThrowsError(try TextPortions.portions(of: "a", format: .plain, heading: "X")) {
            XCTAssertEqual($0 as? TextPortions.Problem, .headingsNeedStructure)
        }
    }

    // MARK: Markdown

    private let quotes = """
        # Quotes

        Some favourites, gathered over the years.

        ## Stoics
        - The impediment to action advances action.
          - Marcus Aurelius
        - We suffer more in imagination
          than in reality.
        * Luck is what happens when preparation meets opportunity.

        ### Seneca
        1. Begin at once to live.
        2) Difficulties strengthen the mind,
        as labour does the body.

        ## Poets
        + Hope is the thing with feathers.

        ```
        - not a quote, just code
        ```

        Poets, continued
        ----------------
        - Do not go gentle into that good night.
        """

    func testEveryItemWithWhatsIndentedUnderIt() throws {
        XCTAssertEqual(try markdown(quotes), [
            "The impediment to action advances action.\n- Marcus Aurelius",
            "We suffer more in imagination\nthan in reality.",
            "Luck is what happens when preparation meets opportunity.",
            "Begin at once to live.",
            "Difficulties strengthen the mind,\nas labour does the body.",
            "Hope is the thing with feathers.",
            "Do not go gentle into that good night.",
        ])
    }

    func testAHeadingTakesInItsSubheadings() throws {
        XCTAssertEqual(try markdown(quotes, heading: "stoics").count, 5)
        XCTAssertEqual(try markdown(quotes, heading: "Seneca"),
                       ["Begin at once to live.", "Difficulties strengthen the mind,\nas labour does the body."])
        XCTAssertEqual(try markdown(quotes, heading: "Poets, continued"), ["Do not go gentle into that good night."],
                       "an underlined heading")
        XCTAssertEqual(try markdown(quotes, heading: "Quotes").count, 7)
    }

    func testHeadingsMatchLoosely() throws {
        XCTAssertEqual(try markdown("## **Stoics:** ##\n- Amor fati", heading: "  STOICS "), ["Amor fati"])
    }

    func testAHeadingThatIsntThereSaysWhatIs() {
        XCTAssertThrowsError(try markdown(quotes, heading: "Cynics")) { error in
            XCTAssertEqual(error as? TextPortions.Problem,
                           .noHeading("Cynics", available: ["Stoics", "Seneca", "Poets", "Poets, continued"]))
        }
    }

    func testListsNeedTheirSpaceAndBreaksAreNotItems() throws {
        XCTAssertEqual(try markdown("-not an item\n**bold** text\n---\n* * *\n1.5 is a number\n- real"), ["real"])
    }

    func testAParagraphAfterABlankLineEndsTheItem() throws {
        XCTAssertEqual(try markdown("- one\n\nText after.\n\n- two\n\n  more of two"), ["one", "two\n\nmore of two"])
    }

    // MARK: HTML

    private let page = """
        <!DOCTYPE html>
        <html><head><title>Reading</title></head><body>
        <h1>Reading list</h1>
        <h2>Articles</h2>
        <ul>
          <li><a href="https://example.com/a">Why &amp; how</a> — a long read</li>
          <li>Second<br>line two
            <ol><li>nested one</li><li>nested two</li></ol>
          </li>
        </ul>
        <h2>Books</h2>
        <ol><li><p>Walden</p><p>Thoreau</p></li></ol>
        <p>Not a list item</p>
        </body></html>
        """

    func testEveryTopLevelItem() throws {
        XCTAssertEqual(try html(page), [
            "Why & how — a long read",
            "Second\nline two\n- nested one\n- nested two",
            "Walden\nThoreau",
        ])
    }

    func testHeadingsNarrowItToo() throws {
        XCTAssertEqual(try html(page, heading: "Books"), ["Walden\nThoreau"])
        XCTAssertEqual(try html(page, heading: "Reading list").count, 3)
        XCTAssertThrowsError(try html(page, heading: "Films")) { error in
            XCTAssertEqual(error as? TextPortions.Problem, .noHeading("Films", available: ["Articles", "Books"]))
        }
    }

    func testFormatsByExtension() {
        XCTAssertEqual(TextPortions.Format(fileExtension: "MD"), .markdown)
        XCTAssertEqual(TextPortions.Format(fileExtension: "htm"), .html)
        XCTAssertEqual(TextPortions.Format(fileExtension: "txt"), .plain)
        XCTAssertEqual(TextPortions.Format(fileExtension: ""), .plain, "fortune files have none")
    }
}
