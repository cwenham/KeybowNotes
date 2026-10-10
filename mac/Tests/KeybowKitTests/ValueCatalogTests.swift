@testable import KeybowKit
import XCTest

/// The values fields and templates can use, described: every one there is,
/// with samples that are what it gives, found by the name a template uses.
final class ValueCatalogTests: XCTestCase {
    private let catalog = ValueCatalog(modules: [])

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    /// The samples' moment: Saturday 26 September 2026, 14:07.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 14, minute: 7))!
    }

    private let outline = """
        1. Work [Copy, area: work]
           1. Meetings [room: 4]
              1. Standup [area: team]
              2. Alex Example
        # contacts
        - Alex Example [phone: +44 7700 900123, email: alex@example.com, discord: alex_example]
        """

    private func config() throws -> KeybowConfig {
        try XCTUnwrap(OutlineCompiler.compile(OutlineParser.parse(outline).0, locateApp: { _ in nil }).config)
    }

    private func expand(_ text: String, _ params: [String: String] = [:]) -> String {
        Template.expand(text, params: params, now: now, calendar: calendar, locale: Locale(identifier: "en_GB")).text
    }

    // MARK: - Everything described

    func testEveryValueBuiltInIsDescribed() throws {
        let selection = try XCTUnwrap(config().resolve(path: [0, 0, 1]))
        let names = Array(Template.builtInNames) + Array(Template.environmentNames)
            + ["level4"] + selection.params.keys.filter { !["area", "room"].contains($0) }
        XCTAssertEqual(catalog.undescribed(names), [])
        XCTAssertEqual(Set(catalog.entries.map(\.name)).count, catalog.entries.count, "each name once")
    }

    func testSamplesAreWhatTheyGive() throws {
        // Work › Meetings › Standup, without the values the tree sets.
        let config = try XCTUnwrap(OutlineCompiler.compile(OutlineParser.parse("""
            1. Work
               1. Meetings
                  1. Standup
            """).0, locateApp: { _ in nil }).config)
        let params = try XCTUnwrap(config.resolve(path: [0, 0, 0])).params
        for entry in catalog.entries(in: "This key") {
            XCTAssertEqual(entry.sample, params[entry.name] ?? "", entry.name)
        }
        for entry in catalog.entries(in: "Date and time") {
            XCTAssertEqual(entry.sample, expand(entry.insertion), entry.name)
            for format in entry.formats {
                XCTAssertEqual(expand("{{\(entry.name):\(format.pattern)}}"), format.sample, format.pattern)
            }
        }
    }

    func testGroupsInOrder() {
        XCTAssertEqual(catalog.groups, ["This key", "Contact", "Project", "Date and time", "What you were doing"])
    }

    // MARK: - Finding one

    func testFoundByTheNameATemplateUses() {
        let names = Template.names(in: "{{date:EEEE}} {{contact.phone|none}} {{contact.discord}} {{level9}}")
        XCTAssertEqual(catalog.entry(named: "date")?.title, "The date")
        XCTAssertTrue(names.contains("date"), "its format dropped")
        XCTAssertEqual(catalog.entry(named: "contact.phone")?.name, "contact.phone", "the name itself first")
        XCTAssertEqual(catalog.entry(named: "contact.discord")?.name, "contact.<field>")
        XCTAssertNil(catalog.entry(named: "level9"))
        XCTAssertNil(catalog.entry(named: "contact"), "a part to fill in is never empty")
        XCTAssertNil(catalog.entry(named: "contact.discord.handle"), "and stands for one part")
    }

    func testTheEntryThatSaysMostIsFound() {
        let catalog = ValueCatalog(modules: [Describing()])
        XCTAssertEqual(catalog.entry(named: "home.sensor.outdoor")?.title, "State")
        XCTAssertEqual(catalog.entry(named: "home.sensor.outdoor.unit")?.title, "Unit", "over any attribute")
        XCTAssertEqual(catalog.entry(named: "home.sensor.outdoor.battery")?.title, "Attribute")
        XCTAssertEqual(catalog.entry(named: "home.sensor")?.name, nil)
        XCTAssertEqual(catalog.entry(named: "test.weather")?.title, "weather", "a module's own name over its family")
        XCTAssertEqual(catalog.entry(named: "test.rain")?.title, "Any")
        XCTAssertEqual(catalog.entry(named: "lines file='q.md' order=sequential")?.name, "lines", "a call by its first word")
        XCTAssertNil(catalog.entry(named: "lines", block: true))
        XCTAssertEqual(catalog.entry(named: "reply", block: true)?.kind, .block)
        XCTAssertNil(catalog.entry(named: "reply"), "a block isn't a value")
    }

    func testAModulesValuesAreListedUnderItsName() {
        let catalog = ValueCatalog(modules: [Describing()])
        XCTAssertEqual(catalog.groups.last, "Describing")
        XCTAssertEqual(catalog.entries(in: "Describing").map(\.name).last, "test.weather", "the named after the manifest's")
        XCTAssertEqual(catalog.entry(named: "test.weather")?.group, "Describing")
    }

    func testWhatsPutInForEach() {
        let catalog = ValueCatalog(modules: [Describing()])
        XCTAssertEqual(catalog.entry(named: "leaf")?.insertion, "{{leaf}}")
        XCTAssertEqual(catalog.entry(named: "lines")?.insertion, "{{lines file=''}}", "with what it needs")
        XCTAssertEqual(catalog.entry(named: "reply", block: true)?.insertion, "{{#reply}}{{/reply}}")
        XCTAssertEqual(catalog.entry(named: "reply", block: true)?.example, "{{#reply}}…{{/reply}}")
    }

    // MARK: - At a key

    func testTheTreesOwnValuesAtAKey() throws {
        let config = try config()
        let standup = catalog.atKey(try XCTUnwrap(config.resolve(path: [0, 0, 0])), config: config)
        let own = standup.entries(in: "Set in the tree")
        XCTAssertEqual(own.map(\.name), ["area", "room"])
        XCTAssertEqual(own.map(\.sample), ["team", "4"], "the deeper wins")
        XCTAssertEqual(own.first?.help, "Set on Standup, for it and every key under it.")
        XCTAssertEqual(standup.entry(named: "room")?.help, "Set on Meetings, for it and every key under it.")
        XCTAssertEqual(standup.groups.first, "Set in the tree")
    }

    func testAContactsOwnFieldsAtTheirKey() throws {
        let config = try config()
        let alex = catalog.atKey(try XCTUnwrap(config.resolve(path: [0, 0, 1])), config: config)
        let fields = alex.entries(in: "Contact").filter { $0.holes == 0 }
        XCTAssertEqual(fields.map(\.name), ["contact.discord", "contact.name", "contact.phone", "contact.email"],
                       "theirs, then those always described")
        XCTAssertEqual(fields.first?.sample, "alex_example")
        XCTAssertEqual(fields.first?.help, "A field of Alex Example's, in # contacts.")
        XCTAssertEqual(alex.entry(named: "contact.discord")?.name, "contact.discord", "over contact.<field>")
    }

    func testAgentsAreToldWhatsHere() {
        let registry = ModuleRegistry()
        registry.register(Describing(), host: MemoryModuleHost())
        let catalog = AgentGuide.catalog(registry: registry)
        XCTAssertTrue(catalog.contains("""
            - Describing: `{{home.<domain>.<entity>}}`, `{{home.<domain>.<entity>.unit}}`, \
            `{{home.<domain>.<entity>.<attribute>}}`, `{{test.<source>}}`, `{{lines file=''}}`, \
            `{{#reply}}…{{/reply}}`, and here:
              - `{{test.weather}}` — Today's weather. Takes `city=…`.
            """), catalog)
        XCTAssertFalse(AgentGuide.catalog(registry: ModuleRegistry()).contains("## Values"), "none without modules")
    }

    func testPreviewsFetchAndReadNothing() throws {
        let registry = ModuleRegistry()
        registry.register(Describing(), host: MemoryModuleHost())
        let params = try XCTUnwrap(config().resolve(path: [0, 0, 0])).params
        func preview(_ name: String) -> String {
            ValueCatalog.preview(of: "{{\(name)}}", params: params, registry: registry, now: now, calendar: calendar).text
        }
        XCTAssertEqual(preview("leaf"), "Standup")
        XCTAssertEqual(preview("area"), "team")
        XCTAssertEqual(preview("time"), "14:07")
        XCTAssertEqual(preview("selection"), "‹selected text›")
        XCTAssertEqual(preview("test.weather"), "‹test.weather›", "a stand-in: nothing fetched")
        XCTAssertEqual(preview("level4"), "")
    }
}

/// A module describing values of each kind, in families and by name.
private final class Describing: KeybowModule, @unchecked Sendable {
    let manifest = ModuleManifest(
        id: "test", name: "Describing", blocks: [ModuleBlockType(name: "reply", title: "Test")], fetches: ["test"],
        values: [
            ValueEntry("home.<domain>.<entity>", title: "State", help: ""),
            ValueEntry("home.<domain>.<entity>.unit", title: "Unit", help: ""),
            ValueEntry("home.<domain>.<entity>.<attribute>", title: "Attribute", help: ""),
            ValueEntry("test.<source>", title: "Any", help: "", fetched: true),
            ValueEntry("lines", title: "Lines", help: "", kind: .call,
                       attributes: [ValueAttribute("file", help: "", required: true), ValueAttribute("order", help: "")]),
            ValueEntry("reply", title: "Reply", help: "", kind: .block),
        ])

    func start(host: ModuleHost) {}
    func summary(of request: ModuleRequest, now: Date) -> ModuleSummary { ModuleSummary(verb: "", subject: "") }
    func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome { .failure("") }
    func namedValues() -> [ValueEntry] {
        [ValueEntry("test.weather", title: "weather", help: "Today's weather.", fetched: true,
                    attributes: [ValueAttribute("city", help: "")])]
    }
}
