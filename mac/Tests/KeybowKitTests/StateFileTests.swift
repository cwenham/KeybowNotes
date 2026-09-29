@testable import KeybowKit
import XCTest

final class StateFileTests: XCTestCase {
    private var folder: URL!
    private var url: URL { folder.appendingPathComponent("state.json") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("StateFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func json(_ text: String) -> Data { Data(text.utf8) }

    private func fileObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testEachModuleKeepsItsOwnPartAsReadableJSON() throws {
        let state = StateFile(url: url)
        XCTAssertNil(state.save(json(#"{"running":true,"laps":[65.5,60]}"#), as: "state", for: "stopwatch"))
        XCTAssertNil(state.save(json(#"{"next":{"/q.md#":3}}"#), as: "positions", for: "quote"))

        let root = try fileObject()
        XCTAssertEqual(root["version"] as? Int, 1)
        let modules = try XCTUnwrap(root["modules"] as? [String: Any])
        let stopwatch = try XCTUnwrap((modules["stopwatch"] as? [String: Any])?["state"] as? [String: Any])
        XCTAssertEqual(stopwatch["running"] as? Bool, true, "stored as JSON, not an opaque blob")
        XCTAssertEqual(state.keys(for: "quote"), ["positions"])

        let again = StateFile(url: url)
        let reloaded = try XCTUnwrap(again.load("state", for: "stopwatch"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reloaded) as? [String: Any])
        XCTAssertEqual(object["laps"] as? [Double], [65.5, 60])
        XCTAssertNil(again.load("state", for: "quote"), "one module can't see another's key")
        XCTAssertNil(again.problem)
    }

    func testDataThatIsntJSONIsKeptAsIs() throws {
        let state = StateFile(url: url)
        let bytes = Data([0x00, 0xFF, 0x10, 0x80])
        state.save(bytes, as: "blob", for: "odd")
        XCTAssertEqual(StateFile(url: url).load("blob", for: "odd"), bytes)
    }

    func testForgettingAKeyAndAnEmptyModule() throws {
        let state = StateFile(url: url)
        state.save(json(#"{"a":1}"#), as: "one", for: "m")
        state.save(json(#"{"b":2}"#), as: "two", for: "m")
        state.save(nil, as: "one", for: "m")
        XCTAssertEqual(StateFile(url: url).keys(for: "m"), ["two"])
        state.save(nil, as: "two", for: "m")
        XCTAssertNil(try fileObject()["modules"].flatMap { ($0 as? [String: Any])?["m"] })
    }

    func testAnUnreadableFileIsSetAsideNotOverwritten() throws {
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)
        let state = StateFile(url: url)
        let problem = try XCTUnwrap(state.problem)
        XCTAssertTrue(problem.hasPrefix("state.json couldn't be read"), problem)
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("state-unreadable-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(aside[0]), encoding: .utf8), "{ not json")
        XCTAssertNil(state.load("state", for: "stopwatch"))
        XCTAssertNil(state.save(json("{}"), as: "state", for: "stopwatch"), "a fresh file starts")
    }

    func testAFileFromANewerAppIsSetAside() throws {
        try #"{"version": 9, "modules": {}}"#.write(to: url, atomically: true, encoding: .utf8)
        let state = StateFile(url: url)
        XCTAssertTrue(state.problem?.contains("version 9") ?? false)
    }

    func testOnlyThisUserCanReadIt() throws {
        StateFile(url: url).save(json("{}"), as: "x", for: "m")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
}
