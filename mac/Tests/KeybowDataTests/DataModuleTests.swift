@testable import KeybowData
import KeybowKit
import XCTest

final class DataModuleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func module(_ sources: [DataSource] = [], transport: StubDataTransport = StubDataTransport(),
                        host: MemoryModuleHost = MemoryModuleHost()) -> DataModule {
        let module = DataModule(fetcher: DataFetcher(transport: transport))
        module.openWindow = nil
        module.start(host: host)
        for source in sources { module.save(source) }
        return module
    }

    private func weather(rule: String? = "$.current.temp_c") -> DataSource {
        var source = DataSource(name: "weather", url: "https://api.example.com/current?city={{city}}")
        source.rule = rule.map { ExtractionRule(kind: .jsonPath, expression: $0) }
        source.wanted = "The temperature"
        source.sampleValues = ["city": "London"]
        return source
    }

    func testAValueIsFetchedAndFound() async throws {
        let transport = StubDataTransport()
        let data = module([weather()], transport: transport)
        let values = try await data.fetch(["api.weather"], params: ["city": "York"], now: now)
        XCTAssertEqual(values, ["api.weather": "14.2"])
        XCTAssertEqual(transport.requests.first?.url?.query, "city=York")
        let saved = try XCTUnwrap(data.source(named: "Weather"), "names match whatever their case")
        XCTAssertEqual(saved.lastValue, "14.2")
        XCTAssertEqual(saved.lastChecked, now)
        XCTAssertNil(saved.broken)
    }

    func testTheRawResponseComesWithoutARule() async throws {
        let transport = StubDataTransport()
        let data = module([weather(rule: nil)], transport: transport)
        let values = try await data.fetch(["api.weather.raw"], params: ["city": "York"], now: now)
        XCTAssertEqual(values, ["api.weather.raw": #"{"current": {"temp_c": 14.2}}"#])
        await assertModuleError({ try await data.fetch(["api.weather"], params: ["city": "York"], now: self.now) },
                                "“weather” has no rule yet")
    }

    func testASourceIsFetchedOnceForAllItsValues() async throws {
        let transport = StubDataTransport()
        let data = module([weather()], transport: transport)
        let values = try await data.fetch(["api.weather", "api.weather.raw"], params: ["city": "York"], now: now)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testUnknownSourcesAndMissingValuesAreExplained() async {
        let data = module([weather()])
        await assertModuleError({ try await data.fetch(["api.traffic"], params: [:], now: self.now) },
                                "There's no data source called “traffic”", detail: "Add it in Data Sources, in the menu bar.")
        await assertModuleError({ try await data.fetch(["api.weather"], params: [:], now: self.now) },
                                "“weather” needs a value for {{city}}")
    }

    func testARuleThatStopsWorkingIsMarkedUntilItWorksAgain() async throws {
        let transport = StubDataTransport()
        var fixed = weather()
        fixed.url = "https://api.example.com/current/london"
        fixed.sampleValues = [:]
        let data = module([fixed], transport: transport)
        transport.body = Data(#"{"now": {"temperature": 15}}"#.utf8)
        await assertModuleError({ try await data.fetch(["api.weather"], params: [:], now: self.now) },
                                "“weather” didn't find its value",
                                detail: "The API may have changed. Open Data Sources in the menu bar and use Find It Again.")
        XCTAssertEqual(data.source(named: "weather")?.broken, "Its rule found nothing in the latest response.")
        XCTAssertEqual(data.menuItems(now: now).map(\.title), ["Edit Data Sources…", "⚠︎ weather needs fixing"])

        transport.body = Data("<html>Service unavailable</html>".utf8)
        await assertModuleError({ try await data.fetch(["api.weather"], params: [:], now: self.now) },
                                "“weather” didn't find its value")
        XCTAssertEqual(data.source(named: "weather")?.broken, "The response isn't JSON, so a JSONPath can't read it.")

        transport.body = Data(#"{"current": {"temp_c": 16}}"#.utf8)
        let value = try await data.test(try XCTUnwrap(data.source(named: "weather")))
        XCTAssertEqual(value, "16")
        XCTAssertNil(data.source(named: "weather")?.broken)
        XCTAssertEqual(data.source(named: "weather")?.lastValue, "16")
        XCTAssertEqual(data.menuItems(now: now).map(\.title), ["Edit Data Sources…"])
    }

    func testASearchThatFindsNothingIsntABrokenRule() async throws {
        let transport = StubDataTransport()
        let data = module([weather()], transport: transport)       // its URL takes {{city}}
        transport.body = Data(#"{"current": {}}"#.utf8)
        await assertModuleError({ try await data.fetch(["api.weather city={{selection}}"], params: ["selection": "Atlantis"],
                                                       now: self.now) },
                                "“weather” found nothing",
                                detail: "Nothing for city “Atlantis”. If there should be, the API may have changed: "
                                    + "try Test Now in Data Sources.")
        XCTAssertNil(data.source(named: "weather")?.broken, "a place with no weather isn't a broken rule")

        // A response it can't read at all still is.
        transport.body = Data("<html>Service unavailable</html>".utf8)
        await assertModuleError({ try await data.fetch(["api.weather"], params: ["city": "York"], now: self.now) },
                                "“weather” didn't find its value")
        XCTAssertNotNil(data.source(named: "weather")?.broken)

        // And so is nothing for the sample's values, which should find something.
        transport.body = Data(#"{"current": {"temp_c": 9}}"#.utf8)
        _ = try await data.test(try XCTUnwrap(data.source(named: "weather")))
        transport.body = Data(#"{"current": {}}"#.utf8)
        await assertModuleError({ try await data.test(try XCTUnwrap(data.source(named: "weather"))) },
                                "“weather” didn't find its value")
        XCTAssertEqual(data.source(named: "weather")?.broken, "Its rule found nothing in the latest response.")
        XCTAssertEqual(transport.requests.last?.url?.query, "city=London", "a test uses the sample values")
    }

    // MARK: - Values given where it's used

    func testAnAttributeGivesTheURLItsValue() async throws {
        let transport = StubDataTransport()
        let data = module([weather()], transport: transport)
        let name = "api.weather city={{selection}}"
        let values = try await data.fetch([name], params: ["city": "York", "selection": "Leeds"], now: now)
        XCTAssertEqual(values, [name: "14.2"])
        XCTAssertEqual(transport.requests.last?.url?.query, "city=Leeds", "over the tree's own city")
        XCTAssertEqual(data.valuesNeeded(toFetch: [name]), ["selection"], "not {{city}}: the attribute gives it")
        XCTAssertEqual(data.valuesNeeded(toFetch: ["api.weather"]), ["city"])
        XCTAssertEqual(data.standIn(forValue: name), "‹weather›")
        XCTAssertEqual(data.standIn(forValue: "api.weather.raw city='{{clipboard}}'"), "‹weather response›")
    }

    func testEachDistinctURLIsFetchedOnce() async throws {
        let transport = StubDataTransport()
        let data = module([weather()], transport: transport)
        let names = ["api.weather city={{selection}}", "api.weather city={{clipboard}}",
                     "api.weather.raw city='{{selection}}'", "api.weather"]
        let values = try await data.fetch(names, params: ["city": "York", "selection": "Leeds", "clipboard": "Hull"], now: now)
        XCTAssertEqual(values.count, 4)
        XCTAssertEqual(Set(transport.requests.compactMap { $0.url?.query }), ["city=Leeds", "city=Hull", "city=York"])
        XCTAssertEqual(transport.requests.count, 3, "the value and the response for Leeds are one fetch")
    }

    func testAttributesThatCantBeUsedSayWhy() async {
        let data = module([weather()])
        await assertModuleError({ try await data.fetch(["api.weather town=Leeds"], params: [:], now: self.now) },
                                "“weather”'s URL has no {{town}}", detail: "It uses {{city}}.")
        await assertModuleError({ try await data.fetch(["api.weather city={{selection}}"], params: [:], now: self.now) },
                                "“weather” needs a value for {{city}}",
                                detail: "It's given {{selection}}, and nothing is selected.")
        await assertModuleError({ try await data.fetch(["api.weather city={{topic}}"], params: [:], now: self.now) },
                                "“weather” needs a value for {{city}}", detail: "It's given {{topic}}, which has no value.")
    }

    func testFromTheTreeThroughToTheAction() async throws {
        let registry = ModuleRegistry()
        let transport = StubDataTransport()
        let data = DataModule(fetcher: DataFetcher(transport: transport))
        data.openWindow = nil
        registry.register(data, host: MemoryModuleHost())
        var wiki = DataSource(name: "wikipedia", url: "https://en.wikipedia.org/w/api.php?list=search&srsearch={{term}}")
        wiki.rule = ExtractionRule(kind: .jsonPath, expression: "$.current.temp_c")
        data.save(wiki)

        let (document, _) = OutlineParser.parse("""
            1. Literal [Copy, text: "{{api.wikipedia}}", term: Ada Lovelace]
            2. Selected [Copy, text: "{{api.wikipedia term={{selection}}}}"]
            3. Quoted [Copy, text: "{{api.wikipedia term='{{clipboard}}'}}"]
            """)
        let config = try XCTUnwrap(OutlineCompiler.compile(document, locateApp: { _ in nil }).config)
        for (path, query) in [(0, "Ada%20Lovelace"), (1, "Grace%20Hopper"), (2, "Alan%20Turing")] {
            let selection = try XCTUnwrap(config.resolve(path: [path]))
            var context = ActionContext(templatesDirectory: nil)
            context.environment = ["selection": "Grace Hopper", "clipboard": "Alan Turing"]
            let fetched = registry.fetchedNames(in: ActionPlanner.placeholders(for: selection, context: context))
            let values = try await registry.fetch(fetched, params: ActionPlanner.values(for: selection, context: context), now: now)
            context.environment.merge(values) { _, new in new }
            XCTAssertEqual(try ActionPlanner.plan(selection, config: config, context: context).plan, .copyToClipboard("14.2"))
            XCTAssertEqual(transport.requests.last?.url?.query, "list=search&srsearch=" + query)
        }
    }

    func testSourcesAndKeysAreKept() async throws {
        let host = MemoryModuleHost()
        let transport = StubDataTransport()
        var keyed = weather()
        keyed.keyUse = .bearer
        let first = module([keyed], transport: transport, host: host)
        XCTAssertNil(first.setKey("k-123", for: keyed.id))
        XCTAssertEqual(host.secret("key.\(keyed.id.uuidString)", for: DataModule.id), "k-123")

        let again = module(transport: transport, host: host)
        XCTAssertEqual(again.sources, [keyed])
        _ = try await again.fetch(["api.weather"], params: ["city": "York"], now: now)
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer k-123")

        again.remove(keyed.id)
        XCTAssertTrue(again.sources.isEmpty)
        XCTAssertNil(host.secret("key.\(keyed.id.uuidString)", for: DataModule.id), "its key goes with it")
        XCTAssertTrue(module(host: host).sources.isEmpty)
    }

    func testSourcesSurviveTheStateFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DataState-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("state.json")

        var full = weather()
        full.keyUse = .query
        full.keyName = "appid"
        full.ruleNote = "The current block's temperature — in °C."
        full.cacheSeconds = 900
        full.lastValue = "14.2"
        full.lastChecked = Date(timeIntervalSinceReferenceDate: 780_000_000.123456)
        full.broken = "Its rule found nothing in the latest response."
        var bare = DataSource(name: "news", url: "https://api.example.com/news")
        bare.rule = ExtractionRule(kind: .xPath, expression: "//item[1]/title")

        let first = DataModule(fetcher: DataFetcher(transport: StubDataTransport()))
        first.openWindow = nil
        first.start(host: StateFileHost(StateFile(url: url)))
        first.save(full)
        first.save(bare)

        // As the app does at its next launch: a fresh module from the file.
        let again = DataModule(fetcher: DataFetcher(transport: StubDataTransport()))
        again.openWindow = nil
        again.start(host: StateFileHost(StateFile(url: url)))
        XCTAssertEqual(again.sources, [full, bare])
    }

    func testChangingAKeyForgetsKeptResponses() async throws {
        let transport = StubDataTransport()
        var kept = weather()
        kept.cacheSeconds = 600
        let data = module([kept], transport: transport)
        _ = try await data.fetch(["api.weather"], params: ["city": "York"], now: now)
        _ = try await data.fetch(["api.weather"], params: ["city": "York"], now: now)
        XCTAssertEqual(transport.requests.count, 1)
        _ = data.setKey("new", for: kept.id)
        _ = try await data.fetch(["api.weather"], params: ["city": "York"], now: now)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testSavingPostsAChange() {
        let data = module()
        let posted = expectation(forNotification: DataModule.changed, object: data)
        data.save(weather())
        wait(for: [posted], timeout: 1)
    }

    func testWhatPreviewsShowAndWhatAFetchNeeds() {
        let data = module([weather()])
        XCTAssertEqual(data.standIn(forValue: "api.weather"), "‹weather›")
        XCTAssertEqual(data.standIn(forValue: "api.weather.raw"), "‹weather response›")
        XCTAssertEqual(data.valuesNeeded(toFetch: ["api.weather", "api.traffic"]), ["city"])
        XCTAssertEqual(DataModule.parse("api.next-train.raw").source, "next-train")
    }

    func testAKeyPressLocatesTheMacBeforeFetchingASourceThatNeedsIt() async throws {
        let registry = ModuleRegistry()
        let transport = StubDataTransport()
        let data = DataModule(fetcher: DataFetcher(transport: transport))
        data.openWindow = nil
        registry.register(data, host: MemoryModuleHost())
        registry.register(FixedPlace(), host: MemoryModuleHost())
        var sunset = weather()
        sunset.name = "sunset"
        sunset.url = "https://api.example.com/sun?lat={{location.latitude}}&lon={{location.longitude}}"
        data.save(sunset)

        XCTAssertEqual(registry.fetchSubject(for: ["api.sunset"]), "your location and sunset")
        let values = try await registry.fetch(["api.sunset"], params: [:], now: now)
        XCTAssertEqual(values["api.sunset"], "14.2")
        XCTAssertEqual(transport.requests.first?.url?.query, "lat=48.8566&lon=2.3522")
    }

    func testASampleFindsValuesOtherModulesFetch() async throws {
        ModuleRegistry.shared.register(FixedPlace(), host: MemoryModuleHost())
        let transport = StubDataTransport()
        var sunset = DataSource(name: "sunset", url: "https://api.example.com/sun?lat={{location.latitude}}&lon={{location.longitude}}&tz={{tz}}")
        sunset.sampleValues = ["tz": "auto", "location.longitude": "-0.13"]
        let data = module([sunset], transport: transport)
        _ = try await data.sample(sunset)
        XCTAssertEqual(transport.requests.first?.url?.query, "lat=48.8566&lon=-0.13&tz=auto",
                       "the Mac's place where there's no sample value, the sample value where there is")
    }

    func testTheRegistryRoutesApiNamesHere() async throws {
        let registry = ModuleRegistry()
        let transport = StubDataTransport()
        let data = DataModule(fetcher: DataFetcher(transport: transport))
        data.openWindow = nil
        registry.register(data, host: MemoryModuleHost())
        data.save(weather())

        let names = Template.names(in: "It's {{api.weather}}°C in {{city}} — {{date:HH:mm}}")
        XCTAssertEqual(registry.fetchedNames(in: names), ["api.weather"])
        XCTAssertEqual(registry.valuesNeeded(toFetch: ["api.weather"]), ["city"])
        XCTAssertEqual(registry.standIn(forValue: "api.weather"), "‹weather›")
        let values = try await registry.fetch(["api.weather"], params: ["city": "York"], now: now)
        XCTAssertEqual(values, ["api.weather": "14.2"])
    }

    func testAFetchedValueCanSteerALinkButAnAIBlockCant() throws {
        let (document, _) = OutlineParser.parse("""
            1. Look up [Link, url: "https://example.com/search?q={{api.weather}}"]
            2. Ring [Call, to: "{{api.phone}}"]
            3. Guess [Link, url: "https://example.com/?q={{#ai}}Tidy {{api.weather.raw}}{{/ai}}"]
            """)
        let config = try XCTUnwrap(OutlineCompiler.compile(document, locateApp: { _ in nil }).config)
        var context = ActionContext(templatesDirectory: nil)
        context.environment["api.weather"] = "14.2 °C"
        context.environment["api.phone"] = "+44 1632 960000"

        let lookUp = try XCTUnwrap(config.resolve(path: [0]))
        XCTAssertEqual(ActionPlanner.placeholders(for: lookUp, context: context).contains("api.weather"), true)
        XCTAssertEqual(try ActionPlanner.plan(lookUp, config: config, context: context).plan,
                       .openLink(URL(string: "https://example.com/search?q=14.2%20%C2%B0C")!))
        let ring = try XCTUnwrap(config.resolve(path: [1]))
        XCTAssertNoThrow(try ActionPlanner.plan(ring, config: config, context: context))

        let guess = try XCTUnwrap(config.resolve(path: [2]))
        XCTAssertThrowsError(try ActionPlanner.blockTexts(for: guess, context: context)) {
            XCTAssertEqual($0 as? ActionPlanError, .blockNotAllowed(field: "url", block: "ai"))
        }
    }
}

/// Always in Paris.
private final class FixedPlace: KeybowModule, @unchecked Sendable {
    let manifest = ModuleManifest(id: "location", name: "Location", fetches: ["location"])
    func start(host: ModuleHost) {}
    func summary(of request: ModuleRequest, now: Date) -> ModuleSummary { ModuleSummary(verb: "", subject: "") }
    func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome { .failure("") }
    func fetchSubject(for names: [String]) -> String { "your location" }
    func fetch(_ names: [String], params: [String: String], now: Date) async throws -> [String: String] {
        let place = ["location.latitude": "48.8566", "location.longitude": "2.3522"]
        return place.filter { names.contains($0.key) }
    }
}

/// Keeps a module's state in a real state.json, as the app does.
private final class StateFileHost: ModuleHost, @unchecked Sendable {
    let state: StateFile
    init(_ state: StateFile) { self.state = state }
    func load(_ key: String, for module: String) -> Data? { state.load(key, for: module) }
    func save(_ data: Data?, as key: String, for module: String) { state.save(data, as: key, for: module) }
    func statusChanged() {}
    func copy(_ text: String) {}
}
