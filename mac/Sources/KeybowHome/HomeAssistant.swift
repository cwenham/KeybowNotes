import Foundation
import KeybowKit

/// An entity as Home Assistant has it: `light.desk_lamp`, `on`, and its
/// attributes — brightness, friendly_name, unit_of_measurement…
public struct EntityState: Equatable, Sendable {
    public var entityID: String
    public var state: String
    public var attributes: [String: JSONValue]
    public var lastChanged: Date?

    public init(entityID: String, state: String, attributes: [String: JSONValue] = [:], lastChanged: Date? = nil) {
        self.entityID = entityID
        self.state = state
        self.attributes = attributes
        self.lastChanged = lastChanged
    }

    /// "Desk lamp", else the entity's own name made readable: "desk lamp".
    public var name: String {
        attributes["friendly_name"]?.stringValue
            ?? String(entityID.split(separator: ".").last ?? "").replacingOccurrences(of: "_", with: " ")
    }

    public var unit: String? {
        attributes["unit_of_measurement"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    var domain: String { String(entityID.split(separator: ".").first ?? "") }
}

/// Home Assistant's REST API, with a long-lived access token.
public struct HomeAssistant: Sendable {
    public let base: URL
    let token: String
    let transport: HTTPTransport
    static let timeout: TimeInterval = 10

    public init(base: URL, token: String, transport: HTTPTransport) {
        self.base = base
        self.token = token
        self.transport = transport
    }

    /// The address from Settings, checked: https, unless it's on the local
    /// network — the token mustn't cross the internet unencrypted.
    public static func address(_ text: String) throws -> URL {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw ModuleError("Home Assistant's address can't be read", "“\(text)” — like http://homeassistant.local:8123")
        }
        if url.scheme?.lowercased() == "http", !isLocal(host) {
            throw ModuleError("Home Assistant's address must use https",
                              "\(host) isn't on your local network, and the token shouldn't travel unencrypted.")
        }
        return url
    }

    /// On the local network: a .local name, one without dots, or a private
    /// address — including Tailscale's.
    static func isLocal(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".home.arpa") { return true }
        if host.contains(":") {
            return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, host.split(separator: ".").count == 4 else { return !host.contains(".") }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31), (100, 64...127): return true
        default: return false
        }
    }

    // MARK: Requests

    /// One entity's state.
    public func state(of entity: String) async throws -> EntityState {
        let (data, status) = try await send("GET", "api/states/\(entity)")
        if status == 404 {
            throw ModuleError("Home Assistant has no \(entity)",
                              "Copy Home Assistant Entities, in the menu bar's menu, lists the ones it has.")
        }
        try check(status, data)
        return try Self.decodeState(data)
    }

    /// Every entity's state.
    public func states() async throws -> [EntityState] {
        let (data, status) = try await send("GET", "api/states")
        try check(status, data)
        guard case .array(let items)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ModuleError("Home Assistant's answer couldn't be read")
        }
        return items.compactMap(Self.state)
    }

    /// Calls a service — `light.turn_on` — and says what changed.
    public func call(_ domain: String, _ service: String, data body: [String: JSONValue]) async throws -> [EntityState] {
        let payload = try JSONSerialization.data(withJSONObject: Self.plain(.object(body)))
        let (data, status) = try await send("POST", "api/services/\(domain)/\(service)", body: payload)
        if status == 400 {
            throw ModuleError("Home Assistant didn't accept \(domain).\(service)", Self.message(in: data))
        }
        if status == 404 {
            throw ModuleError("Home Assistant has no service \(domain).\(service)",
                              "Check the name in Home Assistant, under Developer tools → Actions.")
        }
        try check(status, data)
        guard case .array(let items)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        return items.compactMap(Self.state)
    }

    /// Every service, by domain: each one's name, and what it's called —
    /// turn_on, "Turn on".
    public func services() async throws -> [String: [(service: String, title: String)]] {
        let (data, status) = try await send("GET", "api/services")
        try check(status, data)
        guard case .array(let domains)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ModuleError("Home Assistant's answer couldn't be read")
        }
        var found: [String: [(service: String, title: String)]] = [:]
        for case .object(let entry) in domains {
            guard let domain = entry["domain"]?.stringValue, case .object(let services)? = entry["services"] else { continue }
            found[domain] = services.map { name, about in
                var title = name.replacingOccurrences(of: "_", with: " ")
                if case .object(let details) = about, let named = details["name"]?.stringValue, !named.isEmpty { title = named }
                return (name, title)
            }.sorted { $0.service < $1.service }
        }
        return found
    }

    /// Whether it answers, and to the token: its version, and how many
    /// entities it has.
    public func describe() async throws -> String {
        let (data, status) = try await send("GET", "api/config")
        try check(status, data)
        var version = ""
        if case .object(let config)? = try? JSONDecoder().decode(JSONValue.self, from: data) {
            version = config["version"]?.stringValue.map { " \($0)" } ?? ""
        }
        let count = try await states().count
        return "Home Assistant\(version), with \(count) entities"
    }

    private func send(_ method: String, _ path: String, body: Data? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: Self.timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let host = base.host ?? base.absoluteString
        do {
            let (data, response) = try await transport.send(request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError {
            switch error.code {
            case .appTransportSecurityRequiresSecureConnection:
                throw ModuleError("macOS won't connect to \(host) unencrypted",
                                  "Use Home Assistant's .local address — http://homeassistant.local:8123 — or https.")
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .secureConnectionFailed:
                throw ModuleError("Home Assistant's certificate isn't trusted",
                                  "A certificate of its own needs adding to the Keychain — or use its http .local address.")
            case .cancelled:
                throw CancellationError()
            default:
                throw ModuleError("Home Assistant isn't answering at \(host)",
                                  "Check it's running, and its address in Settings → Home Assistant. If macOS asked "
                                  + "about finding devices on your local network, allow it in Privacy & Security → Local Network.")
            }
        }
    }

    private func check(_ status: Int, _ data: Data) throws {
        switch status {
        case 200..<300: return
        case 401, 403:
            throw ModuleError("Home Assistant refused the token",
                              "Make a long-lived access token in Home Assistant — your profile, then Security — and "
                              + "paste it in Settings → Home Assistant.")
        default:
            throw ModuleError("Home Assistant answered \(status)", Self.message(in: data))
        }
    }

    // MARK: JSON

    static func decodeState(_ data: Data) throws -> EntityState {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), let state = state(value) else {
            throw ModuleError("Home Assistant's answer couldn't be read")
        }
        return state
    }

    static func state(_ value: JSONValue) -> EntityState? {
        guard case .object(let fields) = value, let id = fields["entity_id"]?.stringValue else { return nil }
        var attributes: [String: JSONValue] = [:]
        if case .object(let found)? = fields["attributes"] { attributes = found }
        return EntityState(entityID: id, state: fields["state"]?.stringValue ?? "", attributes: attributes,
                           lastChanged: fields["last_changed"]?.stringValue.flatMap(date))
    }

    private static func date(_ text: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: text) { return date }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: text)
    }

    /// Home Assistant's own words about a refusal.
    static func message(in data: Data) -> String? {
        if case .object(let fields)? = try? JSONDecoder().decode(JSONValue.self, from: data),
           let message = fields["message"]?.stringValue {
            return message
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// A value as JSONSerialization takes it.
    static func plain(_ value: JSONValue) -> Any {
        switch value {
        case .string(let text): return text
        case .number(let number): return number == number.rounded() && abs(number) < 1e15 ? Int(number) as Any : number
        case .bool(let flag): return flag
        case .array(let items): return items.map(plain)
        case .object(let fields): return fields.mapValues(plain)
        case .null: return NSNull()
        }
    }

    /// An attribute as text: 21.5, "heat", "a, b".
    static func text(_ value: JSONValue) -> String {
        switch value {
        case .array(let items): return items.map(text).joined(separator: ", ")
        case .object, .null:
            guard case .object = value,
                  let data = try? JSONSerialization.data(withJSONObject: plain(value), options: [.sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        default: return value.stringValue ?? ""
        }
    }
}
