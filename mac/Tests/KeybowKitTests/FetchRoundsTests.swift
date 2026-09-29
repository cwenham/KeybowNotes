@testable import KeybowKit
import XCTest

/// Fetches its names, noting what it was given each time.
private final class Fetcher: KeybowModule, @unchecked Sendable {
    let manifest: ModuleManifest
    let needs: [String: Set<String>]
    let subject: String
    private let lock = NSLock()
    private var calls: [(names: [String], params: [String: String])] = []

    init(_ prefix: String, needs: [String: Set<String>] = [:], subject: String? = nil) {
        manifest = ModuleManifest(id: prefix, name: prefix.capitalized, fetches: [prefix])
        self.needs = needs
        self.subject = subject ?? prefix
    }

    var received: [(names: [String], params: [String: String])] { lock.withLock { calls } }

    func start(host: ModuleHost) {}
    func summary(of request: ModuleRequest, now: Date) -> ModuleSummary { ModuleSummary(verb: "", subject: "") }
    func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome { .failure("") }

    func fetch(_ names: [String], params: [String: String], now: Date) async throws -> [String: String] {
        lock.withLock { calls.append((names.sorted(), params)) }
        var values: [String: String] = [:]
        for name in names {
            let used = (needs[name] ?? []).sorted().map { "\($0)=\(params[$0] ?? "?")" }
            values[name] = ([name] + used).joined(separator: " ")
        }
        return values
    }

    func valuesNeeded(toFetch names: [String]) -> Set<String> {
        names.reduce(into: Set<String>()) { $0.formUnion(needs[$1] ?? []) }
    }

    func fetchSubject(for names: [String]) -> String { subject }
}

final class FetchRoundsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func registry() -> (ModuleRegistry, place: Fetcher, api: Fetcher) {
        let registry = ModuleRegistry()
        let place = Fetcher("location", subject: "your location")
        let api = Fetcher("api", needs: [
            "api.sunset": ["location.latitude", "location.longitude"],
            "api.news": ["topic"],
            "api.chain": ["api.sunset"],
        ])
        registry.register(place, host: MemoryModuleHost())
        registry.register(api, host: MemoryModuleHost())
        return (registry, place, api)
    }

    func testWhatAFetchNeedsIsFetchedFirst() async throws {
        let (registry, place, api) = registry()
        XCTAssertEqual(try registry.fetchRounds(["api.sunset"]),
                       [["location.latitude", "location.longitude"], ["api.sunset"]])

        let values = try await registry.fetch(["api.sunset"], params: ["leaf": "Sunset"], now: now)
        XCTAssertEqual(values["api.sunset"], "api.sunset location.latitude=location.latitude location.longitude=location.longitude")
        XCTAssertEqual(values["location.latitude"], "location.latitude", "everything fetched comes back")
        XCTAssertEqual(place.received.count, 1)
        XCTAssertEqual(place.received.first?.names, ["location.latitude", "location.longitude"])
        XCTAssertEqual(api.received.first?.params["location.latitude"], "location.latitude")
        XCTAssertEqual(api.received.first?.params["leaf"], "Sunset")
    }

    func testChainsGoAsDeepAsTheyNeed() throws {
        let (registry, _, _) = registry()
        XCTAssertEqual(try registry.fetchRounds(["api.chain", "api.news"]),
                       [["api.news", "location.latitude", "location.longitude"], ["api.sunset"], ["api.chain"]])
        XCTAssertEqual(registry.valuesNeeded(toFetch: ["api.chain"]),
                       ["api.sunset", "location.latitude", "location.longitude"])
    }

    func testTheTreesOwnValuesWin() async throws {
        let (registry, place, api) = registry()
        let given = ["location.latitude": "40.7", "location.longitude": "-74.0"]
        XCTAssertEqual(try registry.fetchRounds(["api.sunset"], given: given), [["api.sunset"]])
        let values = try await registry.fetch(["api.sunset"], params: given, now: now)
        XCTAssertEqual(values, ["api.sunset": "api.sunset location.latitude=40.7 location.longitude=-74.0"])
        XCTAssertTrue(place.received.isEmpty, "a node that sets its own place isn't located")
        XCTAssertEqual(api.received.count, 1)
    }

    func testValuesThatNeedEachOtherAreRefused() {
        let registry = ModuleRegistry()
        registry.register(Fetcher("api", needs: ["api.a": ["api.b"], "api.b": ["api.a"], "api.c": []]), host: MemoryModuleHost())
        XCTAssertThrowsError(try registry.fetchRounds(["api.a", "api.c"])) { error in
            XCTAssertEqual((error as? ModuleError)?.message, "These values each need another to be fetched first")
            XCTAssertEqual((error as? ModuleError)?.detail, "{{api.a}}, {{api.b}}")
        }
    }

    func testTheOverlaySaysWhatsBeingFetchedInOrder() {
        let (registry, _, _) = registry()
        XCTAssertEqual(registry.fetchSubject(for: ["api.sunset"]), "your location and api")
        XCTAssertEqual(registry.fetchSubject(for: ["location"]), "your location")
        XCTAssertEqual(registry.fetchSubject(for: ["api.sunset"], given: ["location.latitude": "1", "location.longitude": "2"]),
                       "api")
    }
}
