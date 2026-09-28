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
        let data = module([weather()], transport: transport)
        transport.body = Data(#"{"now": {"temperature": 15}}"#.utf8)
        await assertModuleError({ try await data.fetch(["api.weather"], params: ["city": "York"], now: self.now) },
                                "“weather” didn't find its value",
                                detail: "The API may have changed. Open Data Sources in the menu bar and use Find It Again.")
        XCTAssertEqual(data.source(named: "weather")?.broken, "Its rule found nothing in the latest response.")
        XCTAssertEqual(data.menuItems(now: now).map(\.title), ["Edit Data Sources…", "⚠︎ weather needs fixing"])

        transport.body = Data("<html>Service unavailable</html>".utf8)
        await assertModuleError({ try await data.fetch(["api.weather"], params: ["city": "York"], now: self.now) },
                                "“weather” didn't find its value")
        XCTAssertEqual(data.source(named: "weather")?.broken, "The response isn't JSON, so a JSONPath can't read it.")

        transport.body = Data(#"{"current": {"temp_c": 16}}"#.utf8)
        let value = try await data.test(try XCTUnwrap(data.source(named: "weather")))
        XCTAssertEqual(value, "16")
        XCTAssertEqual(transport.requests.last?.url?.query, "city=London", "a test uses the sample values")
        XCTAssertNil(data.source(named: "weather")?.broken)
        XCTAssertEqual(data.source(named: "weather")?.lastValue, "16")
        XCTAssertEqual(data.menuItems(now: now).map(\.title), ["Edit Data Sources…"])
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
