import Foundation
import KeybowKit

/// Sends a request and hands back what came back — URLSession in the app, a
/// stand-in in tests.
public protocol ClaudeTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

public struct URLSessionTransport: ClaudeTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

/// `{{#ai}}…{{/ai}}` blocks, answered by Claude through the Messages API.
///
///   {{#ai}}Summarise in one line: {{selection}}{{/ai}}
///   {{#ai model="sonnet-5" effort="medium"}}…{{/ai}}
///
/// The contents are filled in first — placeholders and any blocks inside —
/// then sent as the prompt; the reply takes the block's place as plain text.
/// The API key is kept in the Keychain by the host; the model and effort
/// default to the Settings window's choices.
public final class ClaudeModule: KeybowModule, @unchecked Sendable {
    public static let id = "ai"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Room for the thinking as well as the reply: thinking counts toward it.
    static let maxTokens = 16_000
    static let timeout: TimeInterval = 120

    /// The reply goes straight into a note, the clipboard or what's being
    /// typed, so it should be only the text asked for.
    static let system = """
        Your reply is placed directly into the user's text where they asked for it — a note, \
        the clipboard, or a document they're typing in — so give only the text asked for, \
        with no preamble, sign-off, or remarks about the request.
        """

    struct Model: Equatable {
        let id: String
        let alias: String
        let title: String
        /// Takes `output_config.effort`; Haiku 4.5 rejects it.
        let effort: Bool
        /// Takes `fallbacks: "default"`, which re-runs a request its safety
        /// classifiers decline on the model Anthropic recommends.
        let fallbacks: Bool
    }

    static let models = [
        Model(id: "claude-opus-5-5", alias: "opus-5.5", title: "Claude Opus 5.5", effort: true, fallbacks: true),
        Model(id: "claude-opus-5", alias: "opus-5", title: "Claude Opus 5", effort: true, fallbacks: true),
        Model(id: "claude-sonnet-5", alias: "sonnet-5", title: "Claude Sonnet 5", effort: true, fallbacks: false),
        Model(id: "claude-haiku-4-5", alias: "haiku-4.5", title: "Claude Haiku 4.5", effort: false, fallbacks: false),
        Model(id: "claude-fable-5-1", alias: "fable-5.1", title: "Claude Fable 5.1", effort: true, fallbacks: true),
    ]
    static let defaultModel = "opus-5.5"
    static let efforts = ["low", "medium", "high", "xhigh", "max"]
    static let defaultEffort = "low"
    static let attributes: Set<String> = ["model", "effort", "source"]

    public let manifest = ModuleManifest(
        id: id, name: "Claude",
        blocks: [ModuleBlockType(name: "ai", title: "Claude")],
        settings: [
            ModuleSetting(key: "apiKey", title: "API key", kind: .secret, help: """
                Your Anthropic API key, kept in the Keychain. Make one in the Claude Console — in a workspace \
                with a spend limit, so a mistake can't run up a bill.
                """),
            ModuleSetting(key: "model", title: "Model",
                          kind: .choice(models.map { .init($0.alias, $0.title) }), defaultValue: defaultModel, help: """
                The model for {{#ai}} blocks that don't name one.
                Example: {{#ai model="sonnet-5"}}…{{/ai}} names its own.
                """),
            ModuleSetting(key: "effort", title: "Effort",
                          kind: .choice(efforts.map { .init($0, $0.capitalized) }), defaultValue: defaultEffort, help: """
                How hard the model thinks before replying. Low is quickest and cheapest, and plenty for \
                summaries; higher suits harder writing.
                Example: {{#ai effort="high"}}…{{/ai}} sets its own.
                """),
        ])

    private let transport: ClaudeTransport
    private var host: ModuleHost?

    public init(transport: ClaudeTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func start(host: ModuleHost) {
        self.host = host
    }

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        ModuleSummary(verb: "Ask Claude", subject: request.leaf)
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        .failure("Claude answers {{#ai}} blocks in templates; it isn't an action of its own.")
    }

    public func standIn(for call: TemplateBlockCall) -> String { "‹Claude's reply›" }

    // MARK: - Replying

    public func reply(to call: TemplateBlockCall) async throws -> String {
        try await send(try makeRequest(for: call))
    }

    // MARK: - For other modules

    /// Asks Claude something on another module's behalf, with the Settings
    /// window's model and effort. With a `schema`, the reply is JSON that
    /// matches it (structured outputs). Other modules find this through
    /// `ModuleRegistry.shared.module(id: ClaudeModule.id) as? ClaudeModule`.
    public func ask(system: String, prompt: String, schema: [String: Any]? = nil) async throws -> String {
        let modelName = host?.setting("model", for: Self.id) ?? Self.defaultModel
        let model = Self.model(named: modelName) ?? Self.model(named: Self.defaultModel)!
        let effort = host?.setting("effort", for: Self.id) ?? Self.defaultEffort
        return try await send(try request(model: model, effort: effort, system: system, prompt: prompt, schema: schema))
    }

    /// Whether there's a key to ask with.
    public var isReady: Bool {
        !(host?.secret("apiKey", for: Self.id) ?? "").isEmpty
    }

    // MARK: - Sending

    private func send(_ request: URLRequest) async throws -> String {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                throw ModuleError("Can't reach Claude", "There's no internet connection.")
            case .timedOut:
                throw ModuleError("Claude took too long to reply", "Nothing came back in \(Int(Self.timeout)) seconds.")
            default:
                throw ModuleError("Can't reach Claude", error.localizedDescription)
            }
        }
        return try Self.text(from: data, response: response)
    }

    /// The request for one block: the model and effort it names, or the
    /// Settings window's, and the key from the Keychain.
    func makeRequest(for call: TemplateBlockCall) throws -> URLRequest {
        if let unknown = call.attributes.keys.sorted().first(where: { !Self.attributes.contains($0) }) {
            throw ModuleError("{{#ai}} doesn't know “\(unknown)”", "It takes model, effort and source.")
        }
        if let source = call.attributes["source"], !["claude", "anthropic"].contains(source.lowercased()) {
            throw ModuleError("{{#ai}} can only ask Claude", "“\(source)” isn't a source it knows.")
        }
        let modelName = call.attributes["model"] ?? host?.setting("model", for: Self.id) ?? Self.defaultModel
        guard let model = Self.model(named: modelName) else {
            throw ModuleError("“\(modelName)” isn't a Claude model this knows",
                              "Try " + Self.models.map(\.alias).joined(separator: ", ") + ".")
        }
        let effort = (call.attributes["effort"] ?? host?.setting("effort", for: Self.id) ?? Self.defaultEffort).lowercased()
        guard Self.efforts.contains(effort) else {
            throw ModuleError("“\(effort)” isn't an effort level", "Use " + Self.efforts.joined(separator: ", ") + ".")
        }
        let prompt = call.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ModuleError("A {{#ai}} block is empty", "There's nothing to ask.") }
        return try request(model: model, effort: effort, system: Self.system, prompt: prompt, schema: nil)
    }

    func request(model: Model, effort: String, system: String, prompt: String,
                 schema: [String: Any]?) throws -> URLRequest {
        guard let key = host?.secret("apiKey", for: Self.id), !key.isEmpty else {
            throw ModuleError("Claude needs an API key", "Make one in the Claude Console, then add it in Settings → Claude.")
        }

        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": Self.maxTokens,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
        ]
        // Thinking is left to the model — always on for Opus 5.5 — and effort
        // is the control for how much, and so for speed and cost.
        var outputConfig: [String: Any] = [:]
        if model.effort { outputConfig["effort"] = effort }
        if let schema { outputConfig["format"] = ["type": "json_schema", "schema": schema] }
        if !outputConfig.isEmpty { body["output_config"] = outputConfig }
        if model.fallbacks { body["fallbacks"] = "default" }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if model.fallbacks { request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// "Opus 5.5", "opus-5.5", "claude-opus-5-5" — or a family, "opus", for
    /// its newest. Any other `claude-…` ID is passed through as written.
    static func model(named name: String) -> Model? {
        func key(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: "claude", with: "")
                .filter { $0.isLetter || $0.isNumber }
        }
        let wanted = key(name)
        if let known = models.first(where: { key($0.id) == wanted || key($0.alias) == wanted }) { return known }
        if let family = ["opus": "opus-5.5", "sonnet": "sonnet-5", "haiku": "haiku-4.5", "fable": "fable-5.1"][wanted] {
            return models.first { $0.alias == family }
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("claude-"), !trimmed.contains(" ") {
            return Model(id: trimmed, alias: trimmed, title: trimmed, effort: false, fallbacks: false)
        }
        return nil
    }

    /// The reply's text, or why there isn't any.
    static func text(from data: Data, response: URLResponse) throws -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
            switch status {
            case 401: throw ModuleError("Claude didn't accept the API key", "Check it in Settings → Claude.")
            case 403: throw ModuleError("The API key isn't allowed to do that", message)
            case 404: throw ModuleError("Claude doesn't recognise that model", message)
            case 413: throw ModuleError("That's too much text to send to Claude", message)
            case 429:
                let wait = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after")
                throw ModuleError("Too many requests to Claude just now",
                                  wait.map { "Try again in \($0) seconds." } ?? message)
            case 500..., 529: throw ModuleError("Claude is busy or unavailable", message ?? "Try again shortly.")
            default: throw ModuleError("Claude couldn't reply (HTTP \(status))", message)
            }
        }
        guard let json else { throw ModuleError("Claude's reply couldn't be read") }

        // A decline is a normal response: check before reading the text.
        let stop = json["stop_reason"] as? String
        if stop == "refusal" {
            let details = json["stop_details"] as? [String: Any]
            throw ModuleError("Claude declined this request",
                              (details?["explanation"] as? String) ?? (details?["category"] as? String))
        }
        // Text blocks only: thinking and fallback blocks aren't the reply.
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stop == "max_tokens" {
            throw ModuleError("Claude's reply was cut off", "It ran past its length limit; ask for something shorter.")
        }
        guard !text.isEmpty else { throw ModuleError("Claude's reply was empty") }
        return text
    }
}
