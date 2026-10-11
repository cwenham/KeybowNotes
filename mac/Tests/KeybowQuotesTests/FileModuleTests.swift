import KeybowKit
@testable import KeybowQuotes
import XCTest

final class FileModuleTests: XCTestCase {
    private var folder: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileModuleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Name,Role\nAnn,Lead\nBob,QA\n".write(to: folder.appendingPathComponent("team.csv"), atomically: true, encoding: .utf8)
        // Saved by a spreadsheet on Windows: not UTF-8.
        try Data("Caf\u{e9}\n".data(using: .windowsCP1252)!).write(to: folder.appendingPathComponent("menu.txt"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func registry() -> ModuleRegistry {
        let registry = ModuleRegistry()
        registry.register(FileModule(), host: MemoryModuleHost(templatesFolder: folder))
        return registry
    }

    func testAListGoesThroughAFilesRows() async throws {
        let registry = registry()
        let template = "{{#each file='team.csv' separator=', '}}{{Name}} ({{Role}}){{/each}}"
        let names = registry.fetchedNames(in: Template.names(in: template))
        XCTAssertEqual(names, ["file name='team.csv'"])
        XCTAssertEqual(registry.standIn(forValue: names[0]), "‹team.csv›")
        let values = try await registry.fetch(names, params: [:], now: now, rows: Template.listSources(in: template))
        XCTAssertEqual(Template.expand(template, params: values).text, "Ann (Lead), Bob (QA)")
    }

    func testAFilesTextWithANameFromTheKey() async throws {
        let values = try await registry().fetch(["file name='{{leaf}}.txt'"], params: ["leaf": "menu"], now: now)
        XCTAssertEqual(values["file name='{{leaf}}.txt'"], "Café\n")
        XCTAssertEqual(registry().valuesNeeded(toFetch: ["file name='{{selection}}.txt'"]), ["selection"])
    }

    func testMistakesSayWhat() async {
        do {
            _ = try await registry().fetch(["file name='nowhere.csv'"], params: [:], now: now)
            XCTFail("expected an error")
        } catch let error as ModuleError {
            XCTAssertEqual(error.message, "There's no “nowhere.csv” to read")
        } catch {
            XCTFail("\(error)")
        }
        do {
            _ = try await registry().fetch(["file path='team.csv'"], params: [:], now: now)
            XCTFail("expected an error")
        } catch let error as ModuleError {
            XCTAssertEqual(error.message, "{{file}} doesn't take “path”")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testItsValueIsDescribed() {
        XCTAssertEqual(ValueCatalog(modules: [FileModule()]).undescribed(["file name='x.txt'"]), [])
    }
}
