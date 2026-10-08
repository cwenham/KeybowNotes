@testable import KeybowHome
import KeybowKit
import XCTest

/// Home Assistant made up for the tests: answers by path, and remembers what
/// it was sent.
private final class FakeHome: HomeTransport, @unchecked Sendable {
    var answers: [String: (Int, String)] = [:]
    var failure: URLError?
    private let lock = NSLock()
    private var sent: [URLRequest] = []
    /// Several are sent at once: kept behind a lock.
    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { sent.append(request) }
        if let failure { throw failure }
        let path = request.url!.path
        let (status, body) = answers["\(request.httpMethod ?? "GET") \(path)"] ?? (404, #"{"message": "Entity not found."}"#)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func body(_ index: Int) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: requests[index].httpBody ?? Data())) as? [String: Any] ?? [:]
    }
}

final class HomeAssistantTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var home: FakeHome!
    private var module: HomeAssistantModule!
    private var host: MemoryModuleHost!

    override func setUp() {
        home = FakeHome()
        host = MemoryModuleHost()
        host.set("http://homeassistant.local:8123", for: "address", of: "home")
        host.set("made-up-token", for: "token", of: "home", secret: true)
        module = HomeAssistantModule(transport: home)
        module.start(host: host)
    }

    private let outdoor = """
        {"entity_id": "sensor.outdoor_temperature", "state": "14.2",
         "attributes": {"unit_of_measurement": "°C", "friendly_name": "Outdoor temperature", "device_class": "temperature"},
         "last_changed": "2026-10-08T09:15:00.123456+00:00"}
        """
    private let hallway = """
        {"entity_id": "climate.hallway", "state": "heat",
         "attributes": {"current_temperature": 19.5, "temperature": 21, "friendly_name": "Hallway",
                        "hvac_modes": ["off", "heat", "auto"]}}
        """

    private func request(_ fields: [String: String]) -> ModuleRequest {
        ModuleRequest(type: "home", fields: fields, labels: ["Home", "Key"], time: now)
    }

    // MARK: The address

    func testTheTokenStaysOnTheLocalNetworkUnlessEncrypted() throws {
        for local in ["http://homeassistant.local:8123", "homeassistant.local:8123", "http://192.168.1.20:8123",
                      "http://homeassistant:8123", "http://10.0.0.5", "http://100.101.2.3:8123", "http://[fe80::1]:8123"] {
            XCTAssertNoThrow(try HomeAssistant.address(local), local)
        }
        XCTAssertEqual(try HomeAssistant.address("homeassistant.local:8123/").absoluteString, "http://homeassistant.local:8123")
        XCTAssertNoThrow(try HomeAssistant.address("https://example.ui.nabu.casa"))
        XCTAssertThrowsError(try HomeAssistant.address("http://example.ui.nabu.casa")) { error in
            XCTAssertEqual((error as? ModuleError)?.message, "Home Assistant's address must use https")
        }
        XCTAssertThrowsError(try HomeAssistant.address("http://8.8.8.8"))
    }

    // MARK: Values

    func testNamesSayTheEntityAndThePart() {
        XCTAssertEqual(HomeAssistantModule.parse("home.sensor.outdoor_temperature")?.entity, "sensor.outdoor_temperature")
        XCTAssertNil(HomeAssistantModule.parse("home.sensor.outdoor_temperature")?.part)
        XCTAssertEqual(HomeAssistantModule.parse("home.climate.hallway.current_temperature")?.part, "current_temperature")
        XCTAssertNil(HomeAssistantModule.parse("home.sensor"))
        XCTAssertNil(HomeAssistantModule.parse("home"))
    }

    func testAnEntitysStateAndItsParts() async throws {
        home.answers["GET /api/states/sensor.outdoor_temperature"] = (200, outdoor)
        home.answers["GET /api/states/climate.hallway"] = (200, hallway)
        let values = try await module.fetch(
            ["home.sensor.outdoor_temperature", "home.sensor.outdoor_temperature.text",
             "home.sensor.outdoor_temperature.unit", "home.sensor.outdoor_temperature.name",
             "home.climate.hallway.current_temperature", "home.climate.hallway.temperature",
             "home.climate.hallway.hvac_modes", "home.climate.hallway.nothing"], params: [:], now: now)
        XCTAssertEqual(values["home.sensor.outdoor_temperature"], "14.2")
        XCTAssertEqual(values["home.sensor.outdoor_temperature.text"], "14.2 °C")
        XCTAssertEqual(values["home.sensor.outdoor_temperature.unit"], "°C")
        XCTAssertEqual(values["home.sensor.outdoor_temperature.name"], "Outdoor temperature")
        XCTAssertEqual(values["home.climate.hallway.current_temperature"], "19.5")
        XCTAssertEqual(values["home.climate.hallway.temperature"], "21")
        XCTAssertEqual(values["home.climate.hallway.hvac_modes"], "off, heat, auto")
        XCTAssertEqual(values["home.climate.hallway.nothing"], "")
        XCTAssertEqual(home.requests.count, 2, "one request an entity")
        XCTAssertEqual(home.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer made-up-token")
    }

    func testManyEntitiesComeInOneRequest() async throws {
        let all = (1...5).map { #"{"entity_id": "sensor.s\#($0)", "state": "\#($0)", "attributes": {}}"# }
        home.answers["GET /api/states"] = (200, "[" + all.joined(separator: ",") + "]")
        let values = try await module.fetch((1...5).map { "home.sensor.s\($0)" }, params: [:], now: now)
        XCTAssertEqual(values["home.sensor.s3"], "3")
        XCTAssertEqual(home.requests.map { $0.url!.path }, ["/api/states"])
    }

    func testWhatGoesWrongIsSaid() async {
        func message(_ names: [String]) async -> String? {
            do {
                _ = try await module.fetch(names, params: [:], now: now)
                return nil
            } catch {
                return (error as? ModuleError)?.message
            }
        }
        var said = await message(["home.sensor.nowhere"])
        XCTAssertEqual(said, "Home Assistant has no sensor.nowhere")
        home.answers["GET /api/states/sensor.outdoor_temperature"] = (401, "401: Unauthorized")
        said = await message(["home.sensor.outdoor_temperature"])
        XCTAssertEqual(said, "Home Assistant refused the token")
        home.failure = URLError(.cannotFindHost)
        said = await message(["home.sensor.outdoor_temperature"])
        XCTAssertEqual(said, "Home Assistant isn't answering at homeassistant.local")
        home.failure = URLError(.appTransportSecurityRequiresSecureConnection)
        said = await message(["home.sensor.outdoor_temperature"])
        XCTAssertEqual(said, "macOS won't connect to homeassistant.local unencrypted")
        said = await message(["home.weather"])
        XCTAssertEqual(said, "{{home.weather}} doesn't name an entity")
        host.set(nil, for: "token", of: "home", secret: true)
        said = await message(["home.sensor.outdoor_temperature"])
        XCTAssertEqual(said, "Home Assistant needs an access token")
    }

    // MARK: Working out the service

    func testTheServiceComesFromTheFields() throws {
        func call(_ fields: [String: String]) throws -> HomeAssistantModule.Call {
            try HomeAssistantModule.call(for: request(fields))
        }
        XCTAssertEqual(try call(["entity": "light.desk_lamp"]),
                       .init(domain: "light", service: "toggle", data: ["entity_id": .string("light.desk_lamp")]))
        XCTAssertEqual(try call(["entity": "light.desk_lamp", "brightness": "40"]).service, "turn_on")
        XCTAssertEqual(try call(["entity": "light.desk_lamp", "brightness": "40"]).data["brightness_pct"], .number(40))
        XCTAssertEqual(try call(["entity": "light.desk_lamp", "color": "#ff8800"]).data["rgb_color"],
                       .array([.number(255), .number(136), .number(0)]))
        XCTAssertEqual(try call(["entity": "light.desk_lamp", "color": "Warm White"]).data["color_name"], .string("warmwhite"))
        XCTAssertEqual(try call(["entity": "climate.hallway", "temperature": "21"]).service, "set_temperature")
        XCTAssertEqual(try call(["entity": "climate.hallway", "mode": "Heat"]),
                       .init(domain: "climate", service: "set_hvac_mode",
                             data: ["entity_id": .string("climate.hallway"), "hvac_mode": .string("heat")]))
        XCTAssertEqual(try call(["entity": "scene.evening"]).service, "turn_on")
        XCTAssertEqual(try call(["entity": "button.doorbell_snapshot"]).service, "press")
        XCTAssertEqual(try call(["entity": "input_number.volume", "value": "3"]),
                       .init(domain: "input_number", service: "set_value",
                             data: ["entity_id": .string("input_number.volume"), "value": .number(3)]))
        XCTAssertEqual(try call(["entity": "input_select.mood", "value": "Movie night"]).data["option"], .string("Movie night"))
        XCTAssertEqual(try call(["entity": "light.desk_lamp", "service": "light.turn_off"]).service, "turn_off")
        XCTAssertEqual(try call(["entity": "light.a, light.b"]).data["entity_id"], .array([.string("light.a"), .string("light.b")]))
        XCTAssertEqual(try call(["entity": "light.desk_lamp", "service": "turn_on", "data": "transition: 2, effect: colorloop, flash: false"]).data,
                       ["entity_id": .string("light.desk_lamp"), "transition": .number(2), "effect": .string("colorloop"),
                        "flash": .bool(false)])
        XCTAssertEqual(try call(["entity": "light.desk_lamp", "data": #"{"transition": 5}"#]).data["transition"], .number(5))

        // A thermostat's turn_on takes no temperature: setting it is what's meant.
        XCTAssertEqual(try call(["entity": "climate.lounge", "service": "turn_on", "temperature": "26", "mode": "heat"]),
                       .init(domain: "climate", service: "set_temperature",
                             data: ["entity_id": .string("climate.lounge"), "temperature": .number(26), "hvac_mode": .string("heat")]))
        let warm = try call(["entity": "climate.lounge", "service": "turn_on", "temperature": "26"])
        XCTAssertEqual(warm.service, "set_temperature")
        XCTAssertEqual(warm.before, [.init(domain: "climate", service: "turn_on", data: ["entity_id": .string("climate.lounge")])],
                       "turned on first, with no mode to turn it on in")
        XCTAssertEqual(try call(["entity": "climate.lounge", "service": "turn_on", "mode": "heat"]).service, "set_hvac_mode")
        XCTAssertEqual(try call(["entity": "climate.lounge", "service": "turn_off", "temperature": "26"]).data,
                       ["entity_id": .string("climate.lounge")])
        XCTAssertEqual(try call(["entity": "light.desk_lamp", "service": "turn_off", "brightness": "40"]).data,
                       ["entity_id": .string("light.desk_lamp")])

        XCTAssertThrowsError(try call(["entity": "lock.front_door"])) { error in
            XCTAssertEqual((error as? ModuleError)?.message, "Say what to do with lock.front_door")
        }
        XCTAssertEqual(try call(["entity": "lock.front_door", "service": "lock"]).service, "lock")
        XCTAssertThrowsError(try call([:]))
        XCTAssertThrowsError(try call(["entity": "desk lamp"]))
        XCTAssertThrowsError(try call(["entity": "light.desk_lamp", "brightness": "bright"]))
        XCTAssertEqual(module.problem(with: request(["entity": "lock.front_door"])),
                       "Say what to do with lock.front_door: service: lock or service: unlock — or arm, or disarm.")
    }

    // MARK: Pressing the key

    func testAKeyCallsTheServiceAndSaysWhatChanged() async {
        home.answers["POST /api/services/light/turn_on"] = (200, """
            [{"entity_id": "light.desk_lamp", "state": "on", "attributes": {"brightness": 102, "friendly_name": "Desk lamp"}}]
            """)
        let outcome = await module.run(request(["entity": "light.desk_lamp", "brightness": "40"]), now: now)
        XCTAssertEqual(outcome, .success("Desk lamp: on, 40%"))
        XCTAssertEqual(home.requests[0].httpMethod, "POST")
        XCTAssertEqual(home.requests[0].url?.absoluteString, "http://homeassistant.local:8123/api/services/light/turn_on")
        XCTAssertEqual(home.body(0)["entity_id"] as? String, "light.desk_lamp")
        XCTAssertEqual(home.body(0)["brightness_pct"] as? Int, 40)

        home.answers["POST /api/services/climate/set_temperature"] = (200, "[\(hallway)]")
        let warmer = await module.run(request(["entity": "climate.hallway", "temperature": "21"]), now: now)
        XCTAssertEqual(warmer, .success("Hallway: heat, 21°"))

        home.answers["POST /api/services/scene/turn_on"] = (200, """
            [{"entity_id": "scene.evening", "state": "2026-10-08T19:00:00+00:00", "attributes": {"friendly_name": "Evening"}}]
            """)
        let scene = await module.run(request(["entity": "scene.evening"]), now: now)
        XCTAssertEqual(scene, .success("Ran Evening"))

        home.answers["POST /api/services/climate/turn_on"] = (200, "[]")
        home.answers["POST /api/services/climate/set_temperature"] = (200, "[\(hallway)]")
        let before = home.requests.count
        _ = await module.run(request(["entity": "climate.hallway", "service": "turn_on", "temperature": "21"]), now: now)
        XCTAssertEqual(home.requests.dropFirst(before).map { $0.url!.path },
                       ["/api/services/climate/turn_on", "/api/services/climate/set_temperature"])

        home.answers["POST /api/services/light/toggle"] = (200, "[]")
        let unchanged = await module.run(request(["entity": "light.desk_lamp"]), now: now)
        XCTAssertEqual(unchanged, .success("Sent light.toggle", "desk lamp"))

        home.answers["POST /api/services/light/turn_on"] = (400, #"{"message": "extra keys not allowed @ data['sparkle']"}"#)
        let refused = await module.run(request(["entity": "light.desk_lamp", "service": "turn_on", "data": "sparkle: 1"]), now: now)
        XCTAssertEqual(refused, .failure("Home Assistant didn't accept light.turn_on", "extra keys not allowed @ data['sparkle']"))
    }

    // MARK: Choices, for the editor

    private let everything = """
        [{"entity_id": "switch.kettle", "state": "off", "attributes": {"friendly_name": "Kettle"}},
         {"entity_id": "light.floor_lamp", "state": "off", "attributes": {"friendly_name": "Floor lamp"}},
         {"entity_id": "light.desk_lamp", "state": "on", "attributes": {"friendly_name": "Desk lamp",
          "min_color_temp_kelvin": 2500, "max_color_temp_kelvin": 5000}},
         {"entity_id": "climate.hallway", "state": "heat_cool", "attributes": {"friendly_name": "Hallway",
          "hvac_modes": ["off", "heat", "heat_cool"]}},
         {"entity_id": "input_select.mood", "state": "Calm", "attributes": {"options": ["Calm", "Movie night"]}},
         {"entity_id": "input_number.volume", "state": "3", "attributes": {"min": 0, "max": 10, "step": 0.5}},
         {"entity_id": "sensor.outdoor_temperature", "state": "14.2", "attributes": {}}]
        """

    func testTheEditorIsOfferedWhatHomeAssistantHas() async throws {
        home.answers["GET /api/states"] = (200, everything)
        home.answers["GET /api/services"] = (200, """
            [{"domain": "light", "services": {"turn_on": {"name": "Turn on"}, "toggle": {"name": "Toggle"}}},
             {"domain": "homeassistant", "services": {"toggle": {"name": "Generic toggle"},
              "turn_off": {"name": "Generic turn off"}, "restart": {"name": "Restart"}}}]
            """)
        let entities = try await module.choices(for: "entity", type: "home", fields: [:])
        XCTAssertEqual(entities.map(\.value), ["climate.hallway", "input_number.volume", "input_select.mood",
                                               "light.desk_lamp", "light.floor_lamp", "switch.kettle"],
                       "by domain, then name; no sensors")
        XCTAssertEqual(entities.first?.title, "Hallway — heat cool")

        let services = try await module.choices(for: "service", type: "home", fields: ["entity": "light.desk_lamp"])
        XCTAssertEqual(services, [FieldChoice("toggle", title: "Toggle"), FieldChoice("turn_on", title: "Turn on"),
                                  FieldChoice("homeassistant.turn_off", title: "Generic turn off")],
                       "its own, then the general ones it doesn't have")
        let none = try await module.choices(for: "service", type: "home", fields: [:])
        XCTAssertEqual(none, [], "no entity, nothing to follow")

        let modes = try await module.choices(for: "mode", type: "home", fields: ["entity": "climate.hallway"])
        XCTAssertEqual(modes.map(\.value), ["off", "heat", "heat_cool"])
        XCTAssertEqual(modes.last?.title, "Heat Cool")
        let options = try await module.choices(for: "value", type: "home", fields: ["entity": "input_select.mood"])
        XCTAssertEqual(options.map(\.value), ["Calm", "Movie night"])
        let numbers = try await module.choices(for: "value", type: "home", fields: ["entity": "input_number.volume"])
        XCTAssertEqual(numbers.map(\.value), ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10"], "a few along the way")
        let warmth = try await module.choices(for: "kelvin", type: "home", fields: ["entity": "light.desk_lamp"])
        XCTAssertEqual(warmth.map(\.value), ["2700", "3000", "4000", "5000"], "within what the lamp can do")

        let asked = home.requests.filter { $0.url?.path == "/api/states" }.count
        XCTAssertEqual(asked, 1, "kept, not asked again for each field")
    }

    func testWithoutATokenTheListSaysWhy() async {
        host.set(nil, for: "token", of: "home", secret: true)
        do {
            _ = try await module.choices(for: "entity", type: "home", fields: [:])
            XCTFail()
        } catch {
            XCTAssertEqual((error as? ModuleError)?.message, "Home Assistant needs an access token")
        }
    }

    func testOnlyTheFieldsAnEntityTakesAreShown() {
        XCTAssertEqual(module.shownFields(type: "home", fields: ["entity": "light.desk_lamp"]),
                       ["entity", "service", "data", "brightness", "color", "kelvin"])
        XCTAssertEqual(module.shownFields(type: "home", fields: ["entity": "climate.hallway"]),
                       ["entity", "service", "data", "temperature", "mode"])
        XCTAssertEqual(module.shownFields(type: "home", fields: ["entity": "input_select.mood"]),
                       ["entity", "service", "data", "value"])
        XCTAssertEqual(module.shownFields(type: "home", fields: ["entity": "scene.evening"]), ["entity", "service", "data"])
        XCTAssertEqual(module.shownFields(type: "home", fields: [:]), ["entity", "service", "data"])
    }

    func testWhatAKeyWillDoIsSaid() {
        XCTAssertEqual(module.summary(of: request(["entity": "light.desk_lamp", "brightness": "40"]), now: now),
                       ModuleSummary(verb: "Turn on", subject: "desk lamp", details: ["40%"]))
        XCTAssertEqual(module.summary(of: request(["entity": "climate.hallway", "temperature": "21.5", "mode": "heat"]), now: now),
                       ModuleSummary(verb: "Set", subject: "hallway", details: ["21.5°", "heat"]))
        XCTAssertEqual(module.summary(of: request(["entity": "scene.evening"]), now: now),
                       ModuleSummary(verb: "Run", subject: "evening"))
    }
}
