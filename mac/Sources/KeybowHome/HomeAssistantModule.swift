import Foundation
import KeybowKit

/// Home Assistant: lamps, thermostats, scenes and anything else it controls,
/// from a key — and any entity's state as a value.
///
///   Desk lamp [Home, entity: light.desk_lamp]                        toggles it
///   Reading [Home, entity: light.desk_lamp, brightness: 40]          on, at 40%
///   Warmer [Home, entity: climate.hallway, temperature: 21]
///   Evening [Home, entity: scene.evening]
///
///   {{home.sensor.outdoor_temperature}}         14.2
///   {{home.sensor.outdoor_temperature.text}}    14.2 °C
///   {{home.climate.hallway.current_temperature}}  any attribute, by its name
///
/// Its address and a long-lived access token go in Settings; the token is
/// kept in the Keychain.
public final class HomeAssistantModule: KeybowModule, @unchecked Sendable {
    public static let id = "home"
    public static let type = "home"
    static let defaultAddress = "http://homeassistant.local:8123"

    /// Where the service is given by the domain alone.
    static let services: [String: String] = [
        "scene": "turn_on", "script": "turn_on", "button": "press", "input_button": "press",
        "automation": "trigger", "media_player": "media_play_pause",
    ]
    /// What's too much to leave to a toggle: say which.
    static let mustSay: Set<String> = ["lock", "alarm_control_panel"]

    public let manifest = ModuleManifest(
        id: id, name: "Home Assistant",
        actionTypes: [
            ModuleActionType(
                type: type, title: "Home Assistant", keywords: ["Home", "Home Assistant"], symbol: "house",
                fields: [
                    ModuleField(key: "entity", title: "Entity", hint: "light.desk_lamp", help: """
                        What to control, by its entity ID — or several, separated by commas. The list is what \
                        Home Assistant has.
                        Example: light.desk_lamp
                        """, offersChoices: true),
                    ModuleField(key: "service", title: "Service", hint: "toggle — or turn_on, climate.set_temperature…",
                                help: """
                        What to do, as Home Assistant names it: turn_on, turn_off, toggle, or a whole name like \
                        climate.set_hvac_mode. Left out: a toggle; on, for a light given a brightness or colour; \
                        the temperature, for a thermostat given one; on, for a scene or script.
                        Example: turn_off
                        """, offersChoices: true),
                    ModuleField(key: "brightness", title: "Brightness", kind: .number, hint: "percent", help: """
                        A light's brightness, 0 to 100.
                        Example: 40
                        """),
                    ModuleField(key: "color", title: "Colour", kind: .colour, hint: "#ff8800, or a name: orange", help: """
                        A light's colour: #rrggbb, or a name Home Assistant knows.
                        Example: orange
                        """),
                    ModuleField(key: "kelvin", title: "Colour temperature", kind: .number, hint: "2700", help: """
                        A white light's warmth, in kelvin: 2700 is warm, 6500 daylight.
                        Example: 2700
                        """, offersChoices: true),
                    ModuleField(key: "temperature", title: "Temperature", kind: .number, help: """
                        What a thermostat is set to, in Home Assistant's units.
                        Example: 21
                        """),
                    ModuleField(key: "mode", title: "Mode", hint: "heat, cool, auto, off", help: """
                        A thermostat's mode, as Home Assistant names it.
                        Example: heat
                        """, offersChoices: true),
                    ModuleField(key: "value", title: "Value", help: """
                        For a number, a select or a text entity: the value to set — or the option to choose.
                        Example: 3
                        """, offersChoices: true),
                    ModuleField(key: "data", title: "More", hint: "transition: 2, effect: colorloop", help: """
                        Anything else the service takes, as name: value pairs separated by commas — or as JSON.
                        Example: transition: 2
                        """),
                ]),
        ],
        settings: [
            ModuleSetting(key: "address", title: "Address", kind: .text, defaultValue: defaultAddress, help: """
                Where Home Assistant is: http on your local network, https anywhere else.
                Example: http://homeassistant.local:8123
                """),
            ModuleSetting(key: "token", title: "Access token", kind: .secret, help: """
                A long-lived access token: in Home Assistant, open your profile, then Security, and create one \
                at the bottom of the page. Kept in the Keychain.
                """),
        ],
        fetches: [id])

    private let transport: HomeTransport
    private var host: ModuleHost?
    /// What Home Assistant has, kept a little while for the editor: it asks
    /// each time a field is drawn.
    private let lock = NSLock()
    private var listed: (at: Date, states: [EntityState])?
    private var listedServices: (at: Date, services: [String: [(service: String, title: String)]])?
    static let listKept: TimeInterval = 30

    public init(transport: HomeTransport = HomeSessionTransport()) {
        self.transport = transport
    }

    public func start(host: ModuleHost) {
        self.host = host
    }

    /// The API, as set up in Settings.
    func client() throws -> HomeAssistant {
        let address = host?.setting("address", for: Self.id).flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultAddress
        guard let token = host?.secret("token", for: Self.id), !token.isEmpty else {
            throw ModuleError("Home Assistant needs an access token",
                              "Make a long-lived one in Home Assistant — your profile, then Security — and paste it "
                              + "in Settings → Home Assistant.")
        }
        return HomeAssistant(base: try HomeAssistant.address(address), token: token, transport: transport)
    }

    // MARK: - Values

    /// `home.sensor.outdoor_temperature.unit` → (sensor.outdoor_temperature, unit).
    static func parse(_ name: String) -> (entity: String, part: String?)? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == id, isEntityPart(parts[1]), isEntityPart(parts[2]) else { return nil }
        return ("\(parts[1]).\(parts[2])", parts.count > 3 ? parts[3...].joined(separator: ".") : nil)
    }

    private static func isEntityPart(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    public func fetch(_ names: [String], params: [String: String], now: Date) async throws -> [String: String] {
        var wanted: [String: (entity: String, part: String?)] = [:]
        for name in names {
            guard let parsed = Self.parse(name) else {
                throw ModuleError("{{\(name)}} doesn't name an entity",
                                  "Write it as {{home.sensor.outdoor_temperature}}, with a part after if you like: .unit, .name, .text.")
            }
            wanted[name] = parsed
        }
        let client = try client()
        let entities = Set(wanted.values.map(\.entity))
        var states: [String: EntityState] = [:]
        if entities.count > 4 {
            for state in try await client.states() where entities.contains(state.entityID) { states[state.entityID] = state }
            if let absent = entities.sorted().first(where: { states[$0] == nil }) {
                throw ModuleError("Home Assistant has no \(absent)",
                                  "Copy Home Assistant Entities, in the menu bar's menu, lists the ones it has.")
            }
        } else {
            try await withThrowingTaskGroup(of: EntityState.self) { group in
                for entity in entities { group.addTask { try await client.state(of: entity) } }
                for try await state in group { states[state.entityID] = state }
            }
        }
        return wanted.reduce(into: [:]) { values, item in
            if let state = states[item.value.entity] { values[item.key] = Self.value(of: state, part: item.value.part, now: now) }
        }
    }

    /// The state, or one part of it: `name`, `unit`, `text` (the state with
    /// its unit), `changed`, or any attribute.
    static func value(of state: EntityState, part: String?, now: Date, locale: Locale = .current) -> String {
        switch part {
        case nil, "state"?: return state.state
        case "name"?: return state.name
        case "unit"?: return state.unit ?? ""
        case "text"?: return state.unit.map { "\(state.state) \($0)" } ?? state.state
        case "changed"?:
            guard let date = state.lastChanged else { return "" }
            let format = DateFormatter()
            format.locale = locale
            format.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "d MMM, HH:mm"
            return format.string(from: date)
        case let attribute?:
            return state.attributes[attribute].map(HomeAssistant.text) ?? ""
        }
    }

    public func fetchSubject(for names: [String]) -> String { "Home Assistant" }

    public func standIn(forValue name: String) -> String {
        guard let (entity, part) = Self.parse(name) else { return "‹\(name)›" }
        return "‹\(entity)\(part.map { " \($0)" } ?? "")›"
    }

    // MARK: - The action

    /// The service to call, and what to send it.
    struct Call: Equatable {
        var domain: String
        var service: String
        var data: [String: JSONValue]
        /// Called first: turning a thermostat on before setting it, when the
        /// mode to turn it on in isn't given.
        var before: [Call] = []
    }

    static func entities(_ request: ModuleRequest) -> [String] {
        (request.field("entity") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// What pressing the key sends: the service worked out from the fields
    /// when it isn't named.
    static func call(for request: ModuleRequest) throws -> Call {
        let entities = entities(request)
        guard let first = entities.first else { throw ModuleError("Which entity? Name one: entity: light.desk_lamp") }
        for entity in entities where entity.split(separator: ".").count != 2 || !entity.split(separator: ".").allSatisfy({
            isEntityPart(String($0))
        }) {
            throw ModuleError("“\(entity)” isn't an entity ID", "Like light.desk_lamp: its domain, a dot, and its name.")
        }
        let domain = String(first.split(separator: ".")[0])

        var data: [String: JSONValue] = try extra(request.field("data"))
        data["entity_id"] = entities.count == 1 ? .string(first) : .array(entities.map { .string($0) })
        func number(_ key: String) throws -> Double? {
            guard let text = request.field(key) else { return nil }
            guard let value = Double(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) else {
                throw ModuleError("\(key) is a number", "“\(text)” isn't one.")
            }
            return value
        }
        let brightness = try number("brightness")
        let kelvin = try number("kelvin")
        let temperature = try number("temperature")
        let color = request.field("color")
        let mode = request.field("mode")
        let value = request.field("value")
        if let brightness { data["brightness_pct"] = .number(min(max(brightness, 0), 100)) }
        if let kelvin { data["color_temp_kelvin"] = .number(kelvin) }
        if let color {
            if let rgb = Self.rgb(color) {
                data["rgb_color"] = .array(rgb.map { .number(Double($0)) })
            } else {
                data["color_name"] = .string(color.lowercased().replacingOccurrences(of: " ", with: ""))
            }
        }
        if let temperature { data["temperature"] = .number(temperature) }
        if let mode { data["hvac_mode"] = .string(mode.lowercased()) }

        if let named = request.field("service") {
            let parts = named.split(separator: ".", maxSplits: 1).map(String.init)
            if let value { data[["select", "input_select"].contains(domain) ? "option" : "value"] = .string(value) }
            let call = parts.count == 2 ? Call(domain: parts[0], service: parts[1], data: data)
                : Call(domain: domain, service: named, data: data)
            return meant(call, temperature: temperature != nil, mode: mode != nil)
        }
        if mustSay.contains(domain) {
            throw ModuleError("Say what to do with \(first)", "service: lock or service: unlock — or arm, or disarm.")
        }
        switch domain {
        case "climate":
            if temperature != nil { return Call(domain: domain, service: "set_temperature", data: data) }
            if mode != nil { return Call(domain: domain, service: "set_hvac_mode", data: data) }
        case "light":
            if brightness != nil || kelvin != nil || color != nil { return Call(domain: domain, service: "turn_on", data: data) }
        case "number", "input_number", "input_text", "text":
            guard let value else { throw ModuleError("What should \(first) be set to?", "value: 3") }
            data["value"] = Double(value).map { .number($0) } ?? .string(value)
            return Call(domain: domain, service: "set_value", data: data)
        case "select", "input_select":
            guard let value else { throw ModuleError("Which option for \(first)?", "value: Movie night") }
            data["option"] = .string(value)
            return Call(domain: domain, service: "select_option", data: data)
        default:
            break
        }
        return Call(domain: domain, service: services[domain] ?? "toggle", data: data)
    }

    /// What a named service takes, given what else is set. A thermostat's
    /// turn_on takes no temperature, so turning one on to 21° is setting it
    /// — in the mode given, or after turning it on — and turning one off, or
    /// a light, sends nothing about how it would be.
    static func meant(_ call: Call, temperature: Bool, mode: Bool) -> Call {
        var call = call
        let settings = ["temperature", "hvac_mode", "brightness_pct", "rgb_color", "color_name", "color_temp_kelvin"]
        switch (call.domain, call.service) {
        case ("climate", "turn_on") where temperature:
            if !mode {
                let entity = call.data["entity_id"].map { ["entity_id": $0] } ?? [:]
                call.before = [Call(domain: "climate", service: "turn_on", data: entity)]
            }
            call.service = "set_temperature"
        case ("climate", "turn_on") where mode:
            call.service = "set_hvac_mode"
        case (_, "turn_off"):
            for key in settings { call.data.removeValue(forKey: key) }
        default:
            break
        }
        return call
    }

    /// `#ff8800` → [255, 136, 0].
    static func rgb(_ text: String) -> [Int]? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]
    }

    /// `data`: JSON, or `name: value` pairs separated by commas.
    static func extra(_ text: String?) throws -> [String: JSONValue] {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [:] }
        if text.hasPrefix("{") {
            guard let data = text.data(using: .utf8), case .object(let fields)? = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { throw ModuleError("“data” isn't JSON that can be read", text) }
            return fields
        }
        var fields: [String: JSONValue] = [:]
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else {
                throw ModuleError("“data” is name: value pairs, separated by commas", "“\(pair)” isn't one.")
            }
            let value = parts[1]
            if let number = Double(value) {
                fields[parts[0]] = .number(number)
            } else if value == "true" || value == "false" {
                fields[parts[0]] = .bool(value == "true")
            } else {
                fields[parts[0]] = .string(value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
            }
        }
        return fields
    }

    public func problem(with request: ModuleRequest) -> String? {
        do {
            _ = try Self.call(for: request)
            return nil
        } catch let error as ModuleError {
            return error.detail.map { "\(error.message): \($0)" } ?? error.message
        } catch {
            return "\(error)"
        }
    }

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        let entities = Self.entities(request)
        let subject = entities.map { String($0.split(separator: ".").last ?? "").replacingOccurrences(of: "_", with: " ") }
            .joined(separator: ", ")
        guard let call = try? Self.call(for: request) else { return ModuleSummary(verb: "Home Assistant", subject: subject) }
        let verbs = ["toggle": "Toggle", "turn_on": "Turn on", "turn_off": "Turn off", "press": "Press",
                     "trigger": "Run", "set_temperature": "Set", "set_hvac_mode": "Set", "set_value": "Set",
                     "select_option": "Set", "media_play_pause": "Play or pause"]
        var details: [String] = []
        if case .number(let level)? = call.data["brightness_pct"] { details.append("\(Int(level))%") }
        if case .number(let degrees)? = call.data["temperature"] { details.append(JSONValue.number(degrees).stringValue! + "°") }
        if case .string(let mode)? = call.data["hvac_mode"] { details.append(mode) }
        if case .string(let colour)? = call.data["color_name"] { details.append(colour) }
        if let value = request.field("value") { details.append(value) }
        let verb = call.domain == "scene" || call.domain == "script" ? "Run" : verbs[call.service] ?? "\(call.domain).\(call.service)"
        return ModuleSummary(verb: verb, subject: subject, details: details)
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        do {
            let call = try Self.call(for: request)
            let api = try client()
            for first in call.before { _ = try await api.call(first.domain, first.service, data: first.data) }
            let changed = try await api.call(call.domain, call.service, data: call.data)
            return Self.outcome(of: call, entities: Self.entities(request), changed: changed)
        } catch let error as ModuleError {
            return .failure(error.message, error.detail)
        } catch is CancellationError {
            return .failure("Stopped")
        } catch {
            return .failure("Home Assistant couldn't be reached", error.localizedDescription)
        }
    }

    /// "Desk lamp: on", "Hallway: heat, 21 °C", "Ran Evening".
    static func outcome(of call: Call, entities: [String], changed: [EntityState]) -> ActionOutcome {
        let mine = changed.filter { entities.contains($0.entityID) }
        guard let first = mine.first else {
            let names = entities.map { String($0.split(separator: ".").last ?? "").replacingOccurrences(of: "_", with: " ") }
            return .success("Sent \(call.domain).\(call.service)", names.joined(separator: ", "))
        }
        switch first.domain {
        case "scene", "script", "automation", "button", "input_button":
            return .success("Ran \(first.name)")
        default:
            let lines = mine.map { state -> String in
                var words = [state.state.replacingOccurrences(of: "_", with: " ")]
                if state.domain == "climate", let target = state.attributes["temperature"]?.stringValue {
                    words.append("\(target)°")
                }
                if state.domain == "light", state.state == "on", case .number(let level)? = state.attributes["brightness"] {
                    words.append("\(Int((level / 255 * 100).rounded()))%")
                }
                return "\(state.name): \(words.joined(separator: ", "))"
            }
            return .success(lines[0], lines.count > 1 ? lines.dropFirst().joined(separator: " · ") : nil)
        }
    }

    // MARK: - Choices, for the editor

    /// What a lamp, a thermostat or a number takes: the rest is left out.
    public func shownFields(type: String, fields: [String: String]) -> Set<String>? {
        var shown: Set<String> = ["entity", "service", "data"]
        let first = Self.entities(ModuleRequest(type: type, fields: fields, labels: [])).first
        switch first.map({ String($0.split(separator: ".").first ?? "") }) {
        case "light": shown.formUnion(["brightness", "color", "kelvin"])
        case "climate": shown.formUnion(["temperature", "mode"])
        case "number", "input_number", "select", "input_select", "text", "input_text": shown.insert("value")
        default: break
        }
        return shown
    }

    /// Domains with nothing to control: sensors and the like.
    static let readOnly: Set<String> = [
        "sensor", "binary_sensor", "weather", "sun", "zone", "person", "device_tracker", "update", "event", "image",
        "calendar", "conversation", "tts", "stt", "persistent_notification", "geo_location", "air_quality", "wake_word",
    ]

    /// Every entity's state — kept for half a minute.
    func listedStates(now: Date = Date()) async throws -> [EntityState] {
        if let kept = lock.withLock({ listed }), now.timeIntervalSince(kept.at) < Self.listKept { return kept.states }
        let states = try await client().states()
        lock.withLock { listed = (now, states) }
        return states
    }

    func listedServices(now: Date = Date()) async throws -> [String: [(service: String, title: String)]] {
        if let kept = lock.withLock({ listedServices }), now.timeIntervalSince(kept.at) < Self.listKept { return kept.services }
        let services = try await client().services()
        lock.withLock { listedServices = (now, services) }
        return services
    }

    public func choices(for field: String, type: String, fields: [String: String]) async throws -> [FieldChoice] {
        let first = Self.entities(ModuleRequest(type: type, fields: fields, labels: [])).first
        let domain = first.map { String($0.split(separator: ".").first ?? "") }
        switch field {
        case "entity":
            return try await listedStates()
                .filter { !Self.readOnly.contains($0.domain) }
                .sorted { ($0.domain, $0.name.lowercased()) < ($1.domain, $1.name.lowercased()) }
                .map { FieldChoice($0.entityID, title: "\($0.name) — \($0.state.replacingOccurrences(of: "_", with: " "))") }
        case "service":
            guard let domain else { return [] }
            let services = try await listedServices()
            let own = (services[domain] ?? []).map { FieldChoice($0.service, title: $0.title) }
            let general = (services["homeassistant"] ?? []).filter { ["turn_on", "turn_off", "toggle"].contains($0.service) }
                .filter { general in !own.contains { $0.value == general.service } }
                .map { FieldChoice("homeassistant.\($0.service)", title: $0.title) }
            return own + general
        case "mode", "value", "kelvin":
            guard let first, let state = try await listedStates().first(where: { $0.entityID == first }) else { return [] }
            return Self.choices(for: field, of: state)
        default:
            return []
        }
    }

    /// What one entity's attributes say its mode, value or warmth can be.
    static func choices(for field: String, of state: EntityState) -> [FieldChoice] {
        func words(_ key: String) -> [String] {
            guard case .array(let items)? = state.attributes[key] else { return [] }
            return items.compactMap(\.stringValue)
        }
        switch field {
        case "mode":
            return words("hvac_modes").map { FieldChoice($0, title: $0.replacingOccurrences(of: "_", with: " ").capitalized) }
        case "value":
            if !words("options").isEmpty { return words("options").map { FieldChoice($0) } }
            guard let low = state.attributes["min"]?.stringValue.flatMap(Double.init),
                  let high = state.attributes["max"]?.stringValue.flatMap(Double.init), high > low else { return [] }
            let step = state.attributes["step"]?.stringValue.flatMap(Double.init) ?? 1
            // A few along the way, when there are many.
            let count = Int(((high - low) / step).rounded()) + 1
            let stride = count <= 11 ? step : (high - low) / 10
            return (0...min(count - 1, 10)).map { index in
                let value = min(low + Double(index) * stride, high)
                return FieldChoice(JSONValue.number((value * 100).rounded() / 100).stringValue!)
            }
        case "kelvin":
            let warmest = state.attributes["min_color_temp_kelvin"]?.stringValue.flatMap(Double.init) ?? 2000
            let coolest = state.attributes["max_color_temp_kelvin"]?.stringValue.flatMap(Double.init) ?? 6500
            let named: [(Double, String)] = [(2200, "Candlelight"), (2700, "Warm white"), (3000, "Soft white"),
                                             (4000, "Neutral"), (5000, "Cool white"), (6500, "Daylight")]
            return named.filter { $0.0 >= warmest && $0.0 <= coolest }.map { FieldChoice(String(Int($0.0)), title: $0.1) }
        default:
            return []
        }
    }

    // MARK: - The menu

    public func menuItems(now: Date) -> [ModuleMenuItem] {
        [ModuleMenuItem(id: "", title: "Home Assistant", isEnabled: true, submenu: [
            ModuleMenuItem(id: "check", title: "Check the Connection", isEnabled: true),
            ModuleMenuItem(id: "entities", title: "Copy the Entity List", isEnabled: true),
        ])]
    }

    public func performMenuItem(_ id: String, now: Date) -> ActionOutcome? {
        guard let host, ["check", "entities"].contains(id) else { return nil }
        Task { [self] in
            let shown: String
            do {
                let api = try self.client()
                switch id {
                case "check":
                    shown = "**Connected** to \(try await api.describe()), at \(api.base.absoluteString)."
                case "entities":
                    let states = try await api.states().sorted { $0.entityID < $1.entityID }
                    host.copy(states.map { "\($0.entityID)\t\($0.name)\t\($0.state)\($0.unit.map { " \($0)" } ?? "")" }
                        .joined(separator: "\n"))
                    shown = "**Copied \(states.count) entities** to the clipboard: each one's ID, name and state."
                default:
                    return
                }
            } catch let error as ModuleError {
                shown = "**\(error.message)**" + (error.detail.map { "\n\n\($0)" } ?? "")
            } catch {
                shown = "**Home Assistant couldn't be reached**\n\n\(error.localizedDescription)"
            }
            _ = await host.display(ModuleDisplay(content: .markdown(shown), fadeAfter: 8))
        }
        return nil
    }
}
