@testable import KeybowKit
import XCTest

final class ConfigFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func write(_ text: String, as name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testATreeIsCompiledAsItsRead() throws {
        let url = try write("""
            1. Work [colour: 0060ff]
               1. Standup [Copy, text: "Standup notes"]

            # row 3
            1. Timer [Timer]
               1. 5 min
            """, as: "tree.md")
        let loaded = try ConfigFile.load(url, locateApp: { _ in nil })
        XCTAssertEqual(loaded.errors, [])
        XCTAssertEqual(loaded.config.roots(.main).first??.label, "Work")
        XCTAssertEqual(loaded.config.roots(.row3).first??.children.first??.label, "5 min")
        XCTAssertTrue(ConfigFile.isOutline(url))
    }

    func testMistakesLeaveTheRestWorking() throws {
        let url = try write("""
            1. Work [colour: blue]
               1. Standup [Copy, text: "Standup notes"]
               7. Nowhere
            2. Home [Notes]
               1. Groceries [@shopping]
            3. Play [Notes]
               5. Chess
            4. Ideas
               1. Big [@when]
               2. Small

            # row 3
            1. Timer [Reminders]
               1. Soon [@when]
               2. Later

            # list when
            1. Today
               1. Morning
            """, as: "tree.md")
        let loaded = try ConfigFile.load(url, locateApp: { _ in nil })
        XCTAssertEqual(loaded.errors.map(\.line), [1, 3, 5, 7])
        // Home and Play lost everything under them: left out, not made leaves that make notes.
        XCTAssertEqual(loaded.config.roots(.main).compactMap { $0?.label }, ["Work", "Ideas"])
        XCTAssertNotNil(loaded.config.roots(.main)[0]?.colour, "the bad colour is dropped, not the key")
        XCTAssertEqual(loaded.config.roots(.main)[0]?.children.compactMap { $0?.label }, ["Standup"])
        XCTAssertEqual(loaded.config.roots(.main)[3]?.children.compactMap { $0?.label }, ["Big", "Small"],
                       "the list fits the main tree")
        // In row 3's two levels, @when's Morning is too deep: Today goes, then the whole of Soon.
        XCTAssertEqual(loaded.config.roots(.row3)[0]?.children.compactMap { $0?.label }, ["Later"])
        XCTAssertEqual(loaded.leftOut.count, 2)
        XCTAssertTrue(loaded.leftOut[0].contains("too deep"), loaded.leftOut[0])
        XCTAssertTrue(loaded.leftOut[1].contains("everything under it was left out"), loaded.leftOut[1])

        XCTAssertEqual(loaded.mistakeCount, 6)
        XCTAssertEqual(loaded.describe(in: url), "6 mistakes in tree.md — the first, line 1: “blue” isn't a colour; use rrggbb.")
        let one = ConfigFile.Loaded(config: loaded.config, errors: Array(loaded.errors.prefix(1)))
        XCTAssertEqual(one.describe(in: url), "tree.md, line 1: “blue” isn't a colour; use rrggbb.")
        XCTAssertNil(ConfigFile.Loaded(config: loaded.config, errors: []).describe(in: url))
    }

    func testTheStrictCheckStillRefusesForJSON() {
        let json = Data(#"{ "trees": { "main": [ { "label": "Home", "children": "@nope" } ] } }"#.utf8)
        XCTAssertThrowsError(try KeybowConfig.parse(json))
        var skipped: [String] = []
        XCTAssertNoThrow(try KeybowConfig.parse(json) { skipped.append($0) })
        XCTAssertEqual(skipped.count, 1)
    }

    func testCompiledJSONIsTakenAsItIs() throws {
        let url = try write(#"{ "version": 2, "trees": { "main": [ { "label": "Work" } ] } }"#, as: "config.json")
        XCTAssertFalse(ConfigFile.isOutline(url))
        let loaded = try ConfigFile.load(url)
        XCTAssertEqual(loaded.config.roots(.main).first??.label, "Work")
        XCTAssertEqual(loaded.errors, [])
    }

    func testAMissingFileSaysSo() {
        XCTAssertThrowsError(try ConfigFile.load(folder.appendingPathComponent("tree.md"))) { error in
            guard case .unreadable? = error as? ConfigError else { return XCTFail("\(error)") }
        }
    }

    func testAnAppNamedOnItsOwnLeafJustOpens() throws {
        let url = try write("""
            1. Open [type: app.open]
               1. Notes [app: Notes]
               2. Website [app: Visual Studio Code]
            """, as: "tree.md")
        let (document, _) = OutlineParser.parse(try String(contentsOf: url, encoding: .utf8))
        let compiled = OutlineCompiler.compile(document) { .init(name: $0, installed: true, isService: false) }
        XCTAssertEqual(compiled.todo, ["projects: “Website” needs path — add it under # projects"],
                       "Notes opens Notes; Website is a project to open in VS Code")
    }
}
