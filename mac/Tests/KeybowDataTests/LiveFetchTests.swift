@testable import KeybowData
import KeybowKit
import XCTest

/// Fetches a real, keyless API: only with KEYBOW_LIVE_TESTS=1.
final class LiveFetchTests: XCTestCase {
    func testARealAPIIsFetchedAndRead() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KEYBOW_LIVE_TESTS"] == "1", "set KEYBOW_LIVE_TESTS=1 to run")
        let data = DataModule()
        data.openWindow = nil
        data.start(host: MemoryModuleHost())
        var weather = DataSource(
            name: "weather",
            url: "https://api.open-meteo.com/v1/forecast?latitude={{lat}}&longitude={{lon}}&current=temperature_2m")
        weather.rule = ExtractionRule(kind: .jsonPath, expression: "$.current.temperature_2m")
        data.save(weather)

        let values = try await data.fetch(["api.weather", "api.weather.raw"], params: ["lat": "51.51", "lon": "-0.13"], now: Date())
        let temperature = try XCTUnwrap(values["api.weather"].flatMap(Double.init))
        XCTAssertTrue((-40...50).contains(temperature), "\(temperature)")
        XCTAssertTrue(values["api.weather.raw"]?.contains("\"current\"") ?? false)
    }
}
