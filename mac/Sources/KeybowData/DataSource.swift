import Foundation
import KeybowKit

/// An API to fetch a value from: `{{api.weather}}`.
public struct DataSource: Codable, Identifiable, Equatable, Sendable {
    /// How the source's API key is sent, if it has one.
    public enum KeyUse: String, Codable, CaseIterable, Sendable {
        case none
        /// `Authorization: Bearer <key>`
        case bearer
        /// A header of its own: `X-API-Key: <key>`
        case header
        /// A query parameter: `?appid=<key>`
        case query

        public var title: String {
            switch self {
            case .none: return "No key"
            case .bearer: return "Bearer token"
            case .header: return "In a header"
            case .query: return "In the URL's query"
            }
        }
    }

    public var id = UUID()
    /// Used in templates: `{{api.<name>}}`. Letters, digits, - and _.
    public var name: String
    /// HTTPS, and may hold placeholders: `…/weather?city={{city}}`.
    public var url: String
    public var keyUse: KeyUse = .none
    /// The header or query parameter the key goes in.
    public var keyName: String = ""
    /// What the person wants from the response, in their own words — kept to
    /// find the value again if the rule ever stops working.
    public var wanted: String = ""
    public var rule: ExtractionRule?
    /// Claude's account of the rule, for the person.
    public var ruleNote: String = ""
    /// How long a response is reused; 0 fetches every time.
    public var cacheSeconds: Int = 0
    /// Values for the URL's placeholders when fetching a sample or testing.
    public var sampleValues: [String: String] = [:]
    public var lastValue: String?
    public var lastChecked: Date?
    /// Why the rule last failed to find the value; nil while it works.
    public var broken: String?

    public init(name: String, url: String = "") {
        self.name = name
        self.url = url
    }

    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// The placeholders the URL needs values for: not the clock's.
    public var urlNames: Set<String> { Template.names(in: url).subtracting(Template.builtInNames) }
}

/// A response, as fetched.
public struct Fetched: Sendable, Equatable {
    public let body: Data
    public let contentType: String?
    public let at: Date

    public var text: String { String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self) }
}

/// Sends a request — URLSession in the app, a stand-in in tests.
public protocol DataTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// URLSession, refusing to follow a redirect to another server: the API key
/// travels with the request, and mustn't be handed to a host it wasn't for.
public final class SameHostTransport: NSObject, DataTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    public override init() {}

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        request.url?.host == task.originalRequest?.url?.host ? request : nil
    }
}

/// Fetches sources, keeping responses for as long as each source says.
public final class DataFetcher: @unchecked Sendable {
    /// The most of a response that's kept or read: 5 MB.
    static let maximumSize = 5_000_000
    static let timeout: TimeInterval = 20

    private let transport: DataTransport
    private let lock = NSLock()
    private var cache: [String: Fetched] = [:]

    public init(transport: DataTransport = SameHostTransport()) {
        self.transport = transport
    }

    /// The request for a source: its URL with placeholders filled in —
    /// encoded, as in any link — and its key where the API expects it.
    public static func request(for source: DataSource, params: [String: String], key: String?) throws -> URLRequest {
        let template = source.url.trimmingCharacters(in: .whitespaces)
        let whole = Template.isSinglePlaceholder(template)
        let expanded = Template.expand(template, params: params, encode: whole ? nil : Template.linkEncoded)
        if let missing = expanded.missing.first {
            throw ModuleError("“\(source.name)” needs a value for {{\(missing)}}", "Its URL uses it.")
        }
        guard var components = URLComponents(string: expanded.text), let host = components.host, !host.isEmpty else {
            throw ModuleError("“\(source.name)” has a URL that can't be read", expanded.text)
        }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard components.scheme == "https" || (components.scheme == "http" && local) else {
            throw ModuleError("“\(source.name)” must use https", "Keys and values shouldn't travel unencrypted.")
        }

        var headers: [String: String] = [:]
        if source.keyUse != .none {
            guard let key, !key.isEmpty else {
                throw ModuleError("“\(source.name)” needs its API key", "Add it in Data Sources.")
            }
            let name = source.keyName.trimmingCharacters(in: .whitespaces)
            switch source.keyUse {
            case .bearer:
                headers["Authorization"] = "Bearer \(key)"
            case .header:
                headers[name.isEmpty ? "X-API-Key" : name] = key
            case .query:
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: name.isEmpty ? "key" : name, value: key)]
            case .none:
                break
            }
        }
        guard let url = components.url else { throw ModuleError("“\(source.name)” has a URL that can't be read") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json, application/xml;q=0.9, text/*;q=0.8, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("KeybowNotes", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// The response, from the cache while it's fresh.
    public func fetch(_ source: DataSource, params: [String: String], key: String?, now: Date = Date(),
                      useCache: Bool = true) async throws -> Fetched {
        let request = try Self.request(for: source, params: params, key: key)
        let cacheKey = request.url?.absoluteString ?? source.url
        if useCache, source.cacheSeconds > 0, let kept = lock.withLock({ cache[cacheKey] }),
           now.timeIntervalSince(kept.at) < TimeInterval(source.cacheSeconds) {
            return kept
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw ModuleError("Couldn't reach “\(source.name)”", error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if (300..<400).contains(status) {
            throw ModuleError("“\(source.name)” redirected to another server",
                              "It isn't followed, so your key stays with the server it's for.")
        }
        guard (200..<300).contains(status) else {
            let hint: String?
            switch status {
            case 401: hint = "Check its API key in Data Sources."
            case 403: hint = "Check its API key, and that your plan with the API includes what's asked for."
            case 404: hint = "Check its URL, and the values that go into it."
            case 429: hint = "It's had too many requests; a longer cache may help."
            default: hint = nil
            }
            // The server's own reason first: it knows why.
            let said = Self.serverMessage(in: data, key: key).map { "It says: “\($0)”" }
            let detail = [said, hint].compactMap { $0 }.joined(separator: " ")
            throw ModuleError("“\(source.name)” answered HTTP \(status)", detail.isEmpty ? nil : detail)
        }
        guard data.count <= Self.maximumSize else {
            throw ModuleError("“\(source.name)” sent more than 5 MB", "That's too much to read for one value.")
        }
        let fetched = Fetched(body: data, contentType: http?.value(forHTTPHeaderField: "Content-Type"), at: now)
        if source.cacheSeconds > 0 { lock.withLock { cache[cacheKey] = fetched } }
        return fetched
    }

    /// What a server said about a failure, if it said something readable: a
    /// JSON error's message, or a short plain-text body — not an HTML page.
    /// Never the key, should the server repeat it.
    static func serverMessage(in data: Data, key: String?) -> String? {
        var text: String?
        if let json = try? JSONSerialization.jsonObject(with: data) {
            text = message(inJSON: json)
        } else if !ExtractionRule.looksLikeHTML(data) {
            text = String(decoding: data.prefix(1000), as: UTF8.self)
        }
        guard var message = text?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else { return nil }
        message = message.split(whereSeparator: \.isNewline).joined(separator: " ")
        if let key, !key.isEmpty { message = message.replacingOccurrences(of: key, with: "‹key›") }
        return message.count > 300 ? String(message.prefix(300)) + "…" : message
    }

    /// The fields APIs put their error messages in, likeliest first.
    private static let messageFields = ["message", "error_description", "detail", "error_message", "status_message",
                                        "error", "errors", "description", "title", "status"]

    private static func message(inJSON json: Any) -> String? {
        if let list = json as? [Any] {
            return list.first.flatMap { ($0 as? String) ?? message(inJSON: $0) }
        }
        guard let object = json as? [String: Any] else { return nil }
        for field in messageFields {
            switch object[field] {
            case let text as String where !text.isEmpty:
                return text
            case let nested as [String: Any]:
                if let text = message(inJSON: nested) { return text }
            case let list as [Any]:
                if let text = message(inJSON: list) { return text }
            default:
                continue
            }
        }
        return nil
    }

    /// Forgets a source's responses: its URL or key changed.
    public func forget() {
        lock.withLock { cache.removeAll() }
    }
}
