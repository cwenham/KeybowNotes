@testable import KeybowData
import XCTest

final class ExtractionTests: XCTestCase {
    private let weather = Data("""
        {"location": {"name": "London", "tz": "Europe/London"},
         "current": {"temp_c": 14.2, "wind": 12, "raining": false, "gusts": null},
         "hours": [{"at": "09:00", "temp_c": 11}, {"at": "12:00", "temp_c": 14.5}, {"at": "15:00", "temp_c": 16}],
         "odd name": {"x y": "spaced"}}
        """.utf8)

    private let trains = Data("""
        {"departures": [
          {"to": "London", "type": "train", "minutes": 4, "platform": "2"},
          {"to": "Leeds", "type": "bus", "minutes": 6},
          {"to": "York", "type": "train", "minutes": 12, "platform": "1", "cancelled": true},
          {"to": "Hull", "type": "train", "minutes": 25}
        ]}
        """.utf8)

    private func json(_ expression: String, _ body: Data? = nil) throws -> String {
        try ExtractionRule(kind: .jsonPath, expression: expression).value(in: body ?? weather)
    }

    func testJSONPathMembersAndElements() throws {
        XCTAssertEqual(try json("$.current.temp_c"), "14.2")
        XCTAssertEqual(try json("$['location']['name']"), "London")
        XCTAssertEqual(try json("$.hours[1].at"), "12:00")
        XCTAssertEqual(try json("$.hours[-1].at"), "15:00")
        XCTAssertEqual(try json("$['odd name']['x y']"), "spaced")
        XCTAssertEqual(try json("$.hours[7].at"), "", "an element past the end finds nothing")
        XCTAssertEqual(try json("$.nowhere.at.all"), "")
    }

    func testJSONPathWildcardsAndDescendantsJoinWithCommas() throws {
        XCTAssertEqual(try json("$.hours[*].at"), "09:00, 12:00, 15:00")
        XCTAssertEqual(try json("$.hours.*.temp_c"), "11, 14.5, 16")
        XCTAssertEqual(try json("$..temp_c"), "14.2, 11, 14.5, 16")
    }

    func testJSONPathFilters() throws {
        XCTAssertEqual(try json("$.departures[?(@.type == 'train')].to", trains), "London, York, Hull")
        XCTAssertEqual(try json("$.departures[?(@.type == 'train' && @.minutes < 10)].to", trains), "London")
        XCTAssertEqual(try json("$.departures[?(@.minutes >= 12 || @.type == 'bus')].to", trains), "Leeds, York, Hull")
        XCTAssertEqual(try json("$.departures[?(@.platform)].to", trains), "London, York")
        XCTAssertEqual(try json("$.departures[?(!@.platform)].to", trains), "Leeds, Hull")
        XCTAssertEqual(try json("$.departures[?(@.cancelled == true)].to", trains), "York")
        XCTAssertEqual(try json("$.departures[?(@.to != \"London\")][0].to", trains), "",
                       "[0] applies to each filtered object, which isn't a list")
    }

    func testJSONPathFormatsWhatItFinds() throws {
        XCTAssertEqual(try json("$.current.wind"), "12", "no needless .0")
        XCTAssertEqual(try json("$.current.raining"), "false")
        XCTAssertEqual(try json("$.current.gusts"), "", "null is nothing")
        XCTAssertEqual(try json("$.location"), #"{"name":"London","tz":"Europe\/London"}"#)
    }

    func testJSONPathMistakesAreExplained() {
        XCTAssertThrowsError(try json("current.temp_c")) { error in
            XCTAssertEqual((error as? ExtractionError)?.message, "A JSONPath starts with $: “current.temp_c”.")
        }
        XCTAssertThrowsError(try json("$.current."))
        XCTAssertThrowsError(try json("$.hours[0"))
        XCTAssertThrowsError(try json("$.current.temp_c", Data("<html>not json</html>".utf8))) { error in
            XCTAssertEqual((error as? ExtractionError)?.message, "The response isn't JSON, so a JSONPath can't read it.")
        }
    }

    func testXPathReadsXMLIncludingDefaultNamespaces() throws {
        let feed = Data("""
            <?xml version="1.0"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry><title>First post</title><link href="https://example.com/1"/></entry>
              <entry><title>Second post</title><link href="https://example.com/2"/></entry>
            </feed>
            """.utf8)
        let rule = ExtractionRule(kind: .xPath, expression: "//*[local-name()='entry'][1]/*[local-name()='title']")
        XCTAssertEqual(try rule.value(in: feed, contentType: "application/atom+xml"), "First post")
        let links = ExtractionRule(kind: .xPath, expression: "//*[local-name()='link']/@href")
        XCTAssertEqual(try links.value(in: feed), "https://example.com/1, https://example.com/2")
    }

    func testXPathReadsUntidyHTML() throws {
        let page = Data("""
            <!DOCTYPE html><html><head><title>Status</title></head>
            <body><div class="status"><span id="state">All systems go<br></span></div><p>unclosed
            </body></html>
            """.utf8)
        let rule = ExtractionRule(kind: .xPath, expression: "//span[@id='state']")
        XCTAssertEqual(try rule.value(in: page, contentType: "text/html; charset=utf-8"), "All systems go")
        XCTAssertEqual(try rule.value(in: page), "All systems go", "known as HTML by its start, without a content type")
        XCTAssertThrowsError(try ExtractionRule(kind: .xPath, expression: "//span[").value(in: page))
    }

    func testRegexTakesTheFirstGroupOrTheWholeMatch() throws {
        let text = Data("Next train: 09:42 to London. Following: 10:15.".utf8)
        XCTAssertEqual(try ExtractionRule(kind: .regex, expression: #"Next train: (\d\d:\d\d)"#).value(in: text), "09:42")
        XCTAssertEqual(try ExtractionRule(kind: .regex, expression: #"\d\d:\d\d"#).value(in: text), "09:42, 10:15")
        XCTAssertEqual(try ExtractionRule(kind: .regex, expression: "Bus: (\\d+)").value(in: text), "")
        XCTAssertThrowsError(try ExtractionRule(kind: .regex, expression: "(unclosed").value(in: text))
    }

    func testRulesSurviveEncoding() throws {
        let rule = ExtractionRule(kind: .jsonPath, expression: "$.current.temp_c")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(rule)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"expression":"$.current.temp_c","kind":"jsonpath"}"#)
        XCTAssertEqual(try JSONDecoder().decode(ExtractionRule.self, from: data), rule)
    }
}
