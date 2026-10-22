@testable import KeybowKit
import XCTest

/// The vocabulary other editors read: what `keybow vocabulary` prints.
final class EditorVocabularyTests: XCTestCase {
    /// Those built in, without any module's.
    private let registry = ModuleRegistry()

    func testActionsWithTheirKeywordsAndFields() throws {
        let actions = try XCTUnwrap(EditorVocabulary.object(registry: registry)["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.count, BuiltInActions.types.count)
        let append = try XCTUnwrap(actions.first { $0["type"] as? String == "notes.append" })
        XCTAssertEqual(append["keywords"] as? [String], ["append"])
        let fields = try XCTUnwrap(append["fields"] as? [[String: Any]])
        let create = try XCTUnwrap(fields.first { $0["key"] as? String == "createIfMissing" })
        XCTAssertEqual(create["kind"] as? String, "flag")
        let copy = try XCTUnwrap(actions.first { $0["type"] as? String == "clipboard.copy" })
        let format = try XCTUnwrap((copy["fields"] as? [[String: Any]])?.first { $0["key"] as? String == "format" })
        XCTAssertEqual(format["kind"] as? String, "choice")
        XCTAssertEqual(format["choices"] as? [String], ["auto", "rich", "plain"])
    }

    func testValuesAndConditions() throws {
        let object = EditorVocabulary.object(registry: registry)
        let values = try XCTUnwrap(object["values"] as? [[String: Any]])
        let date = try XCTUnwrap(values.first { $0["name"] as? String == "date" })
        XCTAssertEqual(date["kind"] as? String, "value")
        XCTAssertFalse((date["formats"] as? [[String: String]] ?? []).isEmpty)
        let each = try XCTUnwrap(values.first { $0["name"] as? String == "each" })
        XCTAssertEqual(each["kind"] as? String, "block")
        XCTAssertTrue((each["attributes"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "where" })
        let operators = try XCTUnwrap(object["conditionOperators"] as? [String])
        XCTAssertLessThan(try XCTUnwrap(operators.firstIndex(of: "is not")), try XCTUnwrap(operators.firstIndex(of: "is")),
                          "longest first, as the steps read them")
    }

    func testJSONIsStable() throws {
        XCTAssertEqual(try EditorVocabulary.json(registry: registry), try EditorVocabulary.json(registry: registry))
    }
}
