import Foundation
import KeybowKit

/// `{{#ai}}…{{/ai}}` blocks, answered by Claude through the Messages API.
///
///   {{#ai}}Summarise in one line: {{selection}}{{/ai}}
///   {{#ai model="sonnet-5" effort="medium"}}…{{/ai}}
///
/// The contents are filled in first — placeholders and any blocks inside —
/// then sent as the prompt; the reply takes the block's place as plain text.
/// An image or PDF in them — {{clipboard}} holding a screenshot — goes as
/// itself, where it's written among the text.
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
        ],
        symbol: "sparkles")

    private let transport: HTTPTransport
    private var host: ModuleHost?

    public init(transport: HTTPTransport = SameHostTransport()) {
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
    /// `effort`, `maxTokens` and `timeout` raise the Settings window's — and
    /// the blocks' limits — for work that's bigger: drafting a whole tree.
    public func ask(system: String, prompt: String, schema: [String: Any]? = nil, effort atLeast: String? = nil,
                    maxTokens: Int? = nil, timeout: TimeInterval? = nil) async throws -> String {
        let modelName = host?.setting("model", for: Self.id) ?? Self.defaultModel
        let model = Self.model(named: modelName) ?? Self.model(named: Self.defaultModel)!
        var effort = host?.setting("effort", for: Self.id) ?? Self.defaultEffort
        if let atLeast, let wanted = Self.efforts.firstIndex(of: atLeast), let set = Self.efforts.firstIndex(of: effort),
           wanted > set {
            effort = atLeast
        }
        return try await send(try request(model: model, effort: effort, system: system, prompt: prompt, schema: schema,
                                          maxTokens: maxTokens ?? Self.maxTokens, timeout: timeout ?? Self.timeout))
    }

    /// A tool Claude may use while it works out its reply: its definition —
    /// name, description and input schema — and what answers it. A thrown
    /// error's text goes back to Claude as the tool's failure, for it to
    /// work around.
    public struct Tool: @unchecked Sendable {
        public let definition: [String: Any]
        public let answer: @Sendable ([String: Any]) async throws -> String

        public init(_ definition: [String: Any], answer: @escaping @Sendable ([String: Any]) async throws -> String) {
            self.definition = definition
            self.answer = answer
        }

        var name: String { definition["name"] as? String ?? "" }
    }

    /// How many times Claude may turn to its tools for one reply.
    static let toolRounds = 12

    /// A conversation: turns in order, the person's first, alternating —
    /// ("user", text), ("assistant", text). The system prompt is cached, so a
    /// long one is only paid for in full the first time in a few minutes.
    /// With `tools`, Claude may use them before it replies: each is answered,
    /// and it carries on, until it has its reply.
    public func converse(system: String, turns: [(role: String, text: String)], tools: [Tool] = [],
                         effort atLeast: String? = nil, maxTokens: Int? = nil,
                         timeout: TimeInterval? = nil) async throws -> String {
        let modelName = host?.setting("model", for: Self.id) ?? Self.defaultModel
        let model = Self.model(named: modelName) ?? Self.model(named: Self.defaultModel)!
        var effort = host?.setting("effort", for: Self.id) ?? Self.defaultEffort
        if let atLeast, let wanted = Self.efforts.firstIndex(of: atLeast), let set = Self.efforts.firstIndex(of: effort),
           wanted > set {
            effort = atLeast
        }
        // The first turn is cached too: it carries the person's tree and
        // what's here, and stays the same for the whole conversation.
        var messages: [[String: Any]] = turns.enumerated().map { index, turn in
            guard index == 0 else { return ["role": turn.role, "content": turn.text] }
            return ["role": turn.role,
                    "content": [["type": "text", "text": turn.text, "cache_control": ["type": "ephemeral"]]]]
        }
        let cached: [[String: Any]] = [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]]
        for _ in 0..<Self.toolRounds {
            let reply = try await reply(to: try request(
                model: model, effort: effort, system: cached, messages: messages, schema: nil,
                tools: tools.map(\.definition), maxTokens: maxTokens ?? Self.maxTokens, timeout: timeout ?? Self.timeout))
            guard reply["stop_reason"] as? String == "tool_use", !tools.isEmpty else { return try Self.text(of: reply) }
            // Its turn as it came — thinking and all — then every answer in
            // one turn of the person's.
            let content = reply["content"] as? [[String: Any]] ?? []
            messages.append(["role": "assistant", "content": content])
            var results: [[String: Any]] = []
            for block in content where block["type"] as? String == "tool_use" {
                var result: [String: Any] = ["type": "tool_result", "tool_use_id": block["id"] as? String ?? ""]
                let name = block["name"] as? String ?? ""
                if let tool = tools.first(where: { $0.name == name }) {
                    do {
                        result["content"] = try await tool.answer(block["input"] as? [String: Any] ?? [:])
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        result["content"] = "\(error)"
                        result["is_error"] = true
                    }
                } else {
                    result["content"] = "There's no tool called \(name)."
                    result["is_error"] = true
                }
                results.append(result)
            }
            messages.append(["role": "user", "content": results])
        }
        throw ModuleError("Claude kept looking things up without replying", "Ask again, perhaps more simply.")
    }

    /// Whether there's a key to ask with.
    public var isReady: Bool {
        !(host?.secret("apiKey", for: Self.id) ?? "").isEmpty
    }

    /// What the person lets Claude see, as it stands in Settings → Privacy.
    public var sharing: Sharing {
        Sharing { host?.setting($0, for: Self.id) }
    }

    /// A block that would send what the person keeps from Claude — the
    /// selected text, the clipboard, where they are — is refused before
    /// anything is read.
    public func refusal(forBlock name: String, using names: Set<String>) -> String? {
        guard let kept = sharing.kept(of: names) else { return nil }
        return "This key would send {{\(kept.name)}} to Claude, and Settings → Privacy keeps \(kept.what) from it."
    }

    // MARK: - Sending

    private func send(_ request: URLRequest) async throws -> String {
        try Self.text(of: try await reply(to: request))
    }

    /// The reply, whole: its content blocks and why it stopped.
    private func reply(to request: URLRequest) async throws -> [String: Any] {
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
                throw ModuleError("Claude took too long to reply", "Nothing came back in \(Int(request.timeoutInterval)) seconds.")
            default:
                throw ModuleError("Can't reach Claude", error.localizedDescription)
            }
        }
        return try Self.reply(from: data, response: response)
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
        // Only known once the clipboard's read: it may hold text, or not.
        if MediaToken.contains(prompt), !sharing.media {
            throw ModuleError("Images and PDFs aren't sent to Claude", "Settings → Privacy keeps them from it.")
        }
        return try request(model: model, effort: effort, system: Self.system, prompt: prompt, schema: nil)
    }

    func request(model: Model, effort: String, system: String, prompt: String,
                 schema: [String: Any]?, maxTokens: Int = maxTokens, timeout: TimeInterval = timeout) throws -> URLRequest {
        try request(model: model, effort: effort, system: system,
                    messages: [["role": "user", "content": try Self.content(prompt)]], schema: schema,
                    maxTokens: maxTokens, timeout: timeout)
    }

    /// `system` is text, or blocks of it — cached ones among them.
    func request(model: Model, effort: String, system: Any, messages: [[String: Any]],
                 schema: [String: Any]?, tools: [[String: Any]] = [], maxTokens: Int,
                 timeout: TimeInterval) throws -> URLRequest {
        guard let key = host?.secret("apiKey", for: Self.id), !key.isEmpty else {
            throw ModuleError("Claude needs an API key", "Make one in the Claude Console, then add it in Settings → Claude.")
        }

        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages,
        ]
        // Before the system prompt in what's cached: the same each time.
        if !tools.isEmpty { body["tools"] = tools }
        // Thinking is left to the model — always on for Opus 5.5 — and effort
        // is the control for how much, and so for speed and cost.
        var outputConfig: [String: Any] = [:]
        if model.effort { outputConfig["effort"] = effort }
        if let schema { outputConfig["format"] = ["type": "json_schema", "schema": schema] }
        if !outputConfig.isEmpty { body["output_config"] = outputConfig }
        if model.fallbacks { body["fallbacks"] = "default" }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if model.fallbacks { request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// The prompt as Claude takes it: the text alone — or, with images or PDFs
    /// in it, text, image and document blocks in the order they're written.
    static func content(_ prompt: String) throws -> Any {
        guard MediaToken.contains(prompt) else { return prompt }
        var blocks: [[String: Any]] = []
        for part in MediaToken.parts(of: prompt) {
            switch part {
            case .text(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
            case .media(let item):
                if let problem = item.problem { throw ModuleError("Claude can't take that \(item.kind == .pdf ? "PDF" : "image")", problem) }
                let source: [String: Any] = ["type": "base64", "media_type": item.mediaType,
                                             "data": item.data.base64EncodedString()]
                blocks.append(["type": item.kind == .pdf ? "document" : "image", "source": source])
            case .missing:
                throw ModuleError("The image to send is no longer to hand", "Copy it again, then press the key again.")
            }
        }
        return blocks
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
        try text(of: reply(from: data, response: response))
    }

    /// The reply as it came, or why it couldn't be had: a refusal is one.
    static func reply(from data: Data, response: URLResponse) throws -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
            switch status {
            case 401: throw ModuleError("Claude didn't accept the API key", "Check it in Settings → Claude.")
            case 403: throw ModuleError("The API key isn't allowed to do that", message)
            case 404: throw ModuleError("Claude doesn't recognise that model", message)
            case 413: throw ModuleError("That's too much to send to Claude", message)
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
        return json
    }

    /// The reply's text: its text blocks, together.
    static func text(of json: [String: Any]) throws -> String {
        let stop = json["stop_reason"] as? String
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
