@testable import KeybowKit
import XCTest

/// Completion in the outline's brackets: where the caret is, and what's
/// offered there.
final class OutlineCompletionTests: XCTestCase {
    private let sources = OutlineCompletionSources(
        vocabulary: ActionVocabulary(), lists: ["when", "rating"], templates: ["standup.md", "work/review.md", "notes.txt"],
        apps: ["Safari", "Sublime Text", "Calculator"], valueKeys: ["when", "area"])

    /// The completion at the caret, marked `|` in the line.
    private func at(_ marked: String) -> OutlineCompletion? {
        let caret = (marked as NSString).range(of: "|").location
        return OutlineCompletion.at(caret, in: marked.replacingOccurrences(of: "|", with: ""))
    }

    private func offered(_ marked: String, inheriting type: String? = nil) -> [String] {
        var sources = sources
        sources.inheritedType = type
        return at(marked)?.candidates(sources) ?? []
    }

    // MARK: - Where

    func testOnlyInBrackets() {
        XCTAssertNil(at("Meet|ing"))
        XCTAssertNil(at("Meeting [Calendar]|"), "after the closing bracket")
        XCTAssertNil(at("Meeting |[Calendar]"), "before the opening one")
        XCTAssertEqual(at("Meeting [|")?.slot, .item, "half typed, no ] yet")
    }

    func testAnItem() {
        let completion = at("Meeting [Calendar, ti|")
        XCTAssertEqual(completion?.slot, .item)
        XCTAssertEqual(completion?.partial, "ti")
        XCTAssertEqual(completion?.range, NSRange(location: 19, length: 2))
        XCTAssertEqual(completion?.others, [.word("Calendar")])
        XCTAssertEqual(at("Meeting [Calendar, |, title: x]")?.others, [.word("Calendar"), .pair(key: "title", value: "x")],
                       "those after it too")
    }

    func testAPairsValue() {
        XCTAssertEqual(at("Timer [type: shor|")?.slot, .value(key: "type"))
        XCTAssertEqual(at("Timer [type: shor|")?.partial, "shor")
        XCTAssertEqual(at("Copy [Copy, format: \"pl|")?.partial, "pl", "inside its quotes")
        XCTAssertEqual(at("Copy [Copy, text: \"a, b\", format: |]")?.slot, .value(key: "format"), "a comma in quotes isn't one")
        XCTAssertNil(at("Copy [Copy, text: \"{{leaf}} and |"), "free text after a value")
    }

    func testAValueInsideAPair() {
        let completion = at("Note [Notes, title: \"{{leaf}} at {{ti|")
        XCTAssertEqual(completion?.slot, .placeholder(block: false))
        XCTAssertEqual(completion?.partial, "ti")
        XCTAssertEqual(at("Ask [Copy, text: {{#|")?.slot, .placeholder(block: true))
    }

    // MARK: - What

    func testAnItemOffersKeywordsKeysListsTemplatesAndApps() {
        XCTAssertEqual(offered("Meeting [Cal|"), ["Calendar", "Call", "Calculator"], "keywords, then an app")
        XCTAssertEqual(offered("X [@|"), ["@when", "@rating"])
        XCTAssertEqual(offered("X [Notes, st|"), ["standup.md"], "a template the bare word can name")
        XCTAssertTrue(offered("X [|").contains("Notes"))
        XCTAssertFalse(offered("X [|").contains("Safari"), "no apps until something's typed")
        XCTAssertEqual(offered("X [Sa|"), ["Safari"])
    }

    func testAnItemOffersTheTypesKeysNotYetSet() {
        let keys = offered("Meeting [Calendar, title: x, |")
        XCTAssertTrue(keys.contains("start: "))
        XCTAssertTrue(keys.contains("alertMinutes: "))
        XCTAssertFalse(keys.contains("title: "), "already set")
        XCTAssertFalse(keys.contains("type: "), "a type's been given")
        XCTAssertFalse(keys.contains("Notes"), "nor another keyword")
        XCTAssertTrue(keys.contains("when: "), "a name other nodes give a value")
        XCTAssertEqual(offered("Today [du|", inheriting: "reminders.create"), ["due: "], "the type from above")
        XCTAssertEqual(offered("Today [inst|"), ["instant: "])
    }

    func testAValueOffersWhatTheKeyTakes() {
        XCTAssertEqual(offered("X [Copy, format: |"), ["auto", "rich", "plain"])
        XCTAssertEqual(offered("X [type: clipboard|"), ["clipboard.copy"])
        XCTAssertEqual(offered("X [append, createIfMissing: |"), ["true", "false"])
        XCTAssertEqual(offered("X [Notes, template: work|"), ["work/review.md"])
        XCTAssertEqual(offered("X [app: Sub|"), ["Sublime Text"])
        XCTAssertEqual(offered("X [Notes, title: Mee|"), [], "free text")
        XCTAssertEqual(offered("X [Copy, format: plain|"), [], "what's typed already")
    }

    func testAValueInsideOffersTheValues() {
        XCTAssertEqual(offered("X [Notes, title: \"{{pa|"), ["parent", "path", "parentPath"])
    }

    func testTheNamesNodesGiveValues() {
        let outline = """
            1. Meeting [Calendar, start: "{{when}}"]
               1. Today [when: today, colour: ff0000]
               2. Later [@later]
            # row 2
            1. Work [area: work, Copy, text: hi]
            # list later
            1. Friday [when: friday, mood: calm]
            """
        let document = OutlineParser.parse(outline).0
        XCTAssertEqual(document.valueKeys(vocabulary: ActionVocabulary()), ["when", "area", "mood"])
    }
}
