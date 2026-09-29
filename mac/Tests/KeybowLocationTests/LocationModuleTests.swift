import KeybowKit
@testable import KeybowLocation
import XCTest

/// Answers with a fixed place, counting the questions.
final class StubLocation: LocationProvider, @unchecked Sendable {
    var reading = LocationReading(latitude: 51.507222, longitude: -0.1275, altitude: nil, accuracy: 35,
                                  at: Date(timeIntervalSince1970: 1_800_000_000))
    var error: Error?
    private(set) var asked: [TimeInterval] = []

    func reading(maxAge: TimeInterval) async throws -> LocationReading {
        asked.append(maxAge)
        if let error { throw error }
        return reading
    }
}

final class LocationModuleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func module(precision: String? = nil) -> (LocationModule, StubLocation) {
        let provider = StubLocation()
        let host = MemoryModuleHost()
        host.set(precision, for: "precision", of: LocationModule.id)
        let module = LocationModule(provider: provider)
        module.start(host: host)
        return (module, provider)
    }

    func testTheValuesAnActionUsesAreFetched() async throws {
        let (location, provider) = module()
        let values = try await location.fetch(["location.latitude", "location.longitude"], params: [:], now: now)
        XCTAssertEqual(values, ["location.latitude": "51.50722", "location.longitude": "-0.1275"])
        XCTAssertEqual(provider.asked, [300], "a place up to five minutes old will do")
    }

    func testEveryValue() {
        let reading = LocationReading(latitude: 27.988056, longitude: 86.925278, altitude: 8848.86, accuracy: 4.2, at: now)
        XCTAssertEqual(LocationModule.values(for: reading, places: 5), [
            "location": "27.98806,86.92528",
            "location.latitude": "27.98806",
            "location.longitude": "86.92528",
            "location.altitude": "8849",
            "location.accuracy": "4",
        ])
    }

    func testAnUnknownAltitudeIsEmpty() async throws {
        let (location, _) = module()
        let values = try await location.fetch(["location.altitude", "location"], params: [:], now: now)
        XCTAssertEqual(values["location.altitude"], "", "so {{location.altitude|unknown}} can say so")
        XCTAssertEqual(values["location"], "51.50722,-0.1275")
    }

    func testPrecisionRoundsThePlaceAndWidensTheAccuracy() async throws {
        let (location, _) = module(precision: "2")
        let values = try await location.fetch(["location", "location.accuracy"], params: [:], now: now)
        XCTAssertEqual(values, ["location": "51.51,-0.13", "location.accuracy": "555"])
        XCTAssertEqual(LocationModule.values(for: StubLocation().reading, places: 1)["location"], "51.5,-0.1")
        XCTAssertEqual(LocationModule.values(for: StubLocation().reading, places: 3)["location.accuracy"], "56")
    }

    func testNumbersAreWrittenPlainly() {
        XCTAssertEqual(LocationModule.decimal(51.50000, places: 5), "51.5")
        XCTAssertEqual(LocationModule.decimal(-0.000001, places: 5), "0")
        XCTAssertEqual(LocationModule.decimal(-0.12, places: 1), "-0.1")
        XCTAssertEqual(LocationModule.decimal(12.0, places: 3), "12")
        XCTAssertEqual(LocationModule.decimal(1234.5, places: 0), "1234", "rounds half to even, as printf does")
        XCTAssertEqual(LocationModule.decimal(-33.8688, places: 4), "-33.8688")
    }

    func testAPlaceTheTreeGivesIsUsedInstead() async throws {
        let (location, provider) = module()
        let office = ["location.latitude": "40.7128", "location.longitude": "-74.006"]
        let values = try await location.fetch(["location", "location.accuracy", "location.altitude"], params: office, now: now)
        XCTAssertEqual(values, ["location": "40.7128,-74.006", "location.accuracy": "1", "location.altitude": ""])
        let pair = try await location.fetch(["location.latitude"], params: ["location": "48.8566, 2.3522"], now: now)
        XCTAssertEqual(pair, ["location.latitude": "48.8566"])
        XCTAssertTrue(provider.asked.isEmpty, "the Mac isn't asked")

        _ = try await location.fetch(["location.latitude"], params: ["location": "Office"], now: now)
        _ = try await location.fetch(["location"], params: ["location.latitude": "91", "location.longitude": "0"], now: now)
        XCTAssertEqual(provider.asked.count, 2, "a word, or a place that can't be, isn't one")
    }

    func testMistakesAndFailuresAreExplained() async {
        let (location, provider) = module()
        do {
            _ = try await location.fetch(["location.city"], params: [:], now: now)
            XCTFail("expected an error")
        } catch let error as ModuleError {
            XCTAssertEqual(error.message, "There's no {{location.city}}")
            XCTAssertTrue(error.detail?.contains("{{location.latitude}}") ?? false)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertTrue(provider.asked.isEmpty, "not located for a name that doesn't exist")

        provider.error = ModuleError("KeybowNotes isn't allowed to use your location")
        do {
            _ = try await location.fetch(["location"], params: [:], now: now)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? ModuleError)?.message, "KeybowNotes isn't allowed to use your location")
        }
    }

    func testPreviewsAndTheOverlay() {
        let (location, _) = module()
        XCTAssertEqual(location.standIn(forValue: "location.latitude"), "‹your latitude›")
        XCTAssertEqual(location.standIn(forValue: "location"), "‹your location›")
        XCTAssertEqual(location.fetchSubject(for: ["location.latitude"]), "your location")
        XCTAssertTrue(location.valuesNeeded(toFetch: ["location"]).isEmpty)
    }

    func testThePrecisionSetting() throws {
        let setting = try XCTUnwrap(LocationModule(provider: StubLocation()).manifest.settings.first)
        XCTAssertEqual(setting.key, "precision")
        XCTAssertEqual(setting.defaultValue, "5")
        guard case .choice(let choices) = setting.kind else { return XCTFail("a choice") }
        XCTAssertEqual(choices.map(\.value), ["5", "3", "2", "1"])
    }

    func testLocationServicesErrorsSayWhatToDo() {
        XCTAssertEqual(CoreLocationProvider.explain(CLErrorStub.denied).detail,
                       "Allow it in System Settings → Privacy & Security → Location Services.")
        XCTAssertEqual(CoreLocationProvider.explain(CLErrorStub.unknown).detail,
                       "Macs find their place from nearby Wi-Fi networks: is Wi-Fi on?")
    }
}

import CoreLocation

private enum CLErrorStub {
    static let denied = CLError(.denied)
    static let unknown = CLError(.locationUnknown)
}
