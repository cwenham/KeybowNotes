import KeybowKit
@testable import KeybowQuotes
import XCTest

/// Hands out the numbers given, in turn, noting each range asked for.
private final class Dice: @unchecked Sendable {
    private let lock = NSLock()
    private var rolls: [Int]
    private(set) var ranges: [Range<Int>] = []

    init(_ rolls: [Int]) { self.rolls = rolls }

    var roll: @Sendable (Range<Int>) -> Int {
        { [self] range in lock.withLock { ranges.append(range); return rolls.isEmpty ? range.lowerBound : rolls.removeFirst() } }
    }
}

final class QuoteModuleTests: XCTestCase {
    private var folder: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("QuoteModuleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Carpe diem\nMemento mori\nAmor fati\n".write(to: folder.appendingPathComponent("latin.txt"),
                                                          atomically: true, encoding: .utf8)
        try """
            ## Stoics
            - The obstacle is the way.
            - Amor fati.
            ## Poets
            - Hope is the thing with feathers.
            """.write(to: folder.appendingPathComponent("quotes.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func module(_ host: MemoryModuleHost? = nil, dice: Dice = Dice([])) -> (QuoteModule, MemoryModuleHost) {
        let host = host ?? MemoryModuleHost(templatesFolder: folder)
        let module = QuoteModule(random: dice.roll)
        module.start(host: host)
        return (module, host)
    }

    private func quote(_ module: QuoteModule, _ name: String, params: [String: String] = [:]) async throws -> String {
        let values = try await module.fetch([name], params: params, now: now)
        return try XCTUnwrap(values[name])
    }

    func testInSequenceItGoesRoundAndStartsAgain() async throws {
        let (quotes, host) = module()
        let name = #"quote file="latin.txt" order=sequential"#
        var said: [String] = []
        for _ in 0..<4 { said.append(try await quote(quotes, name)) }
        XCTAssertEqual(said, ["Carpe diem", "Memento mori", "Amor fati", "Carpe diem"])

        // The place is kept: a new run of the app carries on.
        let (later, _) = module(host)
        let next = try await quote(later, name)
        XCTAssertEqual(next, "Memento mori")
        let saved = try XCTUnwrap(host.load("positions", for: QuoteModule.id))
        XCTAssertTrue(String(decoding: saved, as: UTF8.self).contains("latin.txt#"))
    }

    func testAListThatShrankStartsAgainFromTheTop() async throws {
        let (quotes, _) = module()
        let name = #"quote file="latin.txt" order="sequential""#
        for _ in 0..<2 { _ = try await quote(quotes, name) }
        try "Only one now\n".write(to: folder.appendingPathComponent("latin.txt"), atomically: true, encoding: .utf8)
        let first = try await quote(quotes, name)
        XCTAssertEqual(first, "Only one now")
    }

    func testAtRandomNeverTheSameTwiceRunning() async throws {
        let dice = Dice([1, 1, 0, 0])
        let (quotes, _) = module(dice: dice)
        let name = #"quote file="latin.txt""#
        var said: [String] = []
        for _ in 0..<4 { said.append(try await quote(quotes, name)) }
        // 1 → Memento; 1 again, not the last (1), so 2 → Amor; 0 → Carpe; 0 again, so 1 → Memento.
        XCTAssertEqual(said, ["Memento mori", "Amor fati", "Carpe diem", "Memento mori"])
        XCTAssertEqual(dice.ranges, [0..<2, 0..<2, 0..<2, 0..<2], "one fewer than there are: the last is left out")
    }

    func testAHeadingNamedByTheKeyChosen() async throws {
        let (quotes, _) = module()
        let name = #"quote file="quotes.md" heading="{{leaf}}" order=sequential"#
        let poet = try await quote(quotes, name, params: ["leaf": "Poets"])
        XCTAssertEqual(poet, "Hope is the thing with feathers.")
        let stoic = try await quote(quotes, name, params: ["leaf": "Stoics"])
        XCTAssertEqual(stoic, "The obstacle is the way.")
        XCTAssertEqual(quotes.valuesNeeded(toFetch: [name]), ["leaf"])
    }

    func testTheSameQuoteTwiceInOnePressIsOnePick() async throws {
        let (quotes, _) = module()
        let a = #"quote file="latin.txt" order=sequential"#
        let b = #"quote  file='latin.txt'   order="sequential""#
        let values = try await quotes.fetch([a, b], params: [:], now: now)
        XCTAssertEqual(values[a], "Carpe diem")
        XCTAssertEqual(values[b], "Carpe diem", "written differently, but the same list")
        let next = try await quote(quotes, a)
        XCTAssertEqual(next, "Memento mori", "and it moved on once")
    }

    func testAFullPathOrHomePath() async throws {
        let (quotes, _) = module(MemoryModuleHost())
        let full = folder.appendingPathComponent("latin.txt").path
        let first = try await quote(quotes, "quote file=\"\(full)\" order=sequential")
        XCTAssertEqual(first, "Carpe diem")
        XCTAssertEqual(try QuoteModule.resolve("~/q.txt", in: nil).path,
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("q.txt").path)
    }

    func testMistakesSayWhatToDo() async {
        let (quotes, _) = module()
        let cases: [(String, String)] = [
            ("quote", "{{quote}} needs a file to quote from"),
            (#"quote heading="Stoics""#, "{{quote}} needs a file"),
            (#"quote file="latin.txt" shuffle=yes"#, "{{quote}} doesn't take “shuffle”"),
            (#"quote file="latin.txt" order=backwards"#, "{{quote}}'s order is random or sequential, not “backwards”"),
            (#"quote file="missing.txt""#, "There's no “missing.txt” to quote from"),
            (#"quote file="latin.txt" heading="Stoics""#, "“latin.txt” is plain text, with no headings to pick by"),
            (#"quote file="quotes.md" heading="Cynics""#, "“quotes.md” has no heading “Cynics” with a list under it"),
            (#"quote file="quotes.md" heading="{{topic}}""#, "{{quote}}'s heading needs a value for {{topic}}"),
        ]
        for (name, message) in cases {
            do {
                _ = try await quotes.fetch([name], params: [:], now: now)
                XCTFail("expected “\(message)” for \(name)")
            } catch let error as ModuleError {
                XCTAssertEqual(error.message, message, name)
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    func testAHeadingThatIsntThereListsTheOnesThatAre() async {
        let (quotes, _) = module()
        do {
            _ = try await quotes.fetch([#"quote file="quotes.md" heading="Cynics""#], params: [:], now: now)
        } catch let error as ModuleError {
            XCTAssertEqual(error.detail, "It has “Stoics”, “Poets”.")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testPreviewsAndTheOverlay() {
        let (quotes, _) = module()
        XCTAssertEqual(quotes.standIn(forValue: #"quote file="~/Notes/quotes.md" heading="Stoics""#),
                       "‹a quote from quotes.md, Stoics›")
        XCTAssertEqual(quotes.standIn(forValue: #"quote file="quotes.md" heading="{{leaf}}""#), "‹a quote from quotes.md›")
        XCTAssertEqual(quotes.standIn(forValue: "quote"), "‹a quote›")
        XCTAssertEqual(quotes.fetchSubject(for: []), "a quote")
    }

    func testThroughTheRegistryIntoAnAction() async throws {
        let registry = ModuleRegistry()
        let (quotes, host) = module()
        registry.register(quotes, host: host)

        let (document, _) = OutlineParser.parse("""
            1. Quote [Copy, text: "Today: {{quote file='quotes.md' heading='{{leaf}}' order=sequential}}"]
               1. Stoics
            2. Read [Link, url: "https://example.com/?q={{quote file=latin.txt order=sequential}}"]
            """)
        let config = try XCTUnwrap(OutlineCompiler.compile(document, locateApp: { _ in nil }).config)
        for (path, expected) in [([0, 0], ActionPlan.copyToClipboard("Today: The obstacle is the way.")),
                                 ([1], ActionPlan.openLink(URL(string: "https://example.com/?q=Carpe%20diem")!))] {
            let selection = try XCTUnwrap(config.resolve(path: path))
            var context = ActionContext(templatesDirectory: nil)
            let used = ActionPlanner.placeholders(for: selection, context: context)
            let fetched = registry.fetchedNames(in: used)
            XCTAssertEqual(fetched.count, 1)
            let values = try await registry.fetch(fetched, params: ActionPlanner.values(for: selection, context: context),
                                                  now: now)
            context.environment.merge(values) { _, new in new }
            XCTAssertEqual(try ActionPlanner.plan(selection, config: config, context: context).plan, expected,
                           "a quote may go in a link, like any fetched value")
        }
    }
}
