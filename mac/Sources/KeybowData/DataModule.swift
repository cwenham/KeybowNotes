import Foundation
import KeybowAI
import KeybowKit

/// Values from APIs: `{{api.weather}}` is what the "weather" source's rule
/// finds in its response; `{{api.weather.raw}}` is the whole response, for an
/// `{{#ai}}` block to read. Sources are set up in their own window — a URL, a
/// key if it needs one, and a description of the value — where Claude writes
/// the rule once. After that each key press fetches and applies the rule on
/// the Mac. When a rule stops finding its value the action stops, the source
/// is marked, and the window offers to find it again.
public final class DataModule: KeybowModule, @unchecked Sendable {
    public static let id = "api"
    /// Posted, with the module as its object, when a source changes.
    public static let changed = Notification.Name("KeybowData.DataModule.changed")

    public let manifest = ModuleManifest(id: id, name: "Data Sources", fetches: [id])

    let fetcher: DataFetcher
    private let lock = NSLock()
    private var stored: [DataSource] = []
    private var host: ModuleHost?
    /// Opens the window; tests can leave it be.
    public var openWindow: (@MainActor (DataModule) -> Void)? = { DataSourcesWindow.show($0) }

    public init(fetcher: DataFetcher = DataFetcher()) {
        self.fetcher = fetcher
    }

    public func start(host: ModuleHost) {
        self.host = host
        if let data = host.load("sources", for: Self.id),
           let saved = try? JSONDecoder().decode([DataSource].self, from: data) {
            lock.withLock { stored = saved }
        }
    }

    // MARK: - Sources, for the window

    public var sources: [DataSource] { lock.withLock { stored } }

    public func source(named name: String) -> DataSource? {
        sources.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Adds it, or replaces the one with its id.
    public func save(_ source: DataSource) {
        lock.withLock {
            if let index = stored.firstIndex(where: { $0.id == source.id }) { stored[index] = source } else { stored.append(source) }
        }
        persist()
    }

    public func remove(_ id: UUID) {
        _ = setKey(nil, for: id)
        lock.withLock { stored.removeAll { $0.id == id } }
        persist()
    }

    private func persist() {
        let data = lock.withLock { try? JSONEncoder().encode(stored) }
        host?.save(data, as: "sources", for: Self.id)
        host?.statusChanged()
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    public func key(for id: UUID) -> String? {
        host?.secret("key.\(id.uuidString)", for: Self.id)
    }

    /// Nil on success, else why not.
    public func setKey(_ key: String?, for id: UUID) -> String? {
        fetcher.forget()
        return host?.setSecret(key, "key.\(id.uuidString)", for: Self.id)
    }

    /// A fresh response, with the source's sample values in its URL — and
    /// values other modules fetch, `{{location.latitude}}`, where it has none.
    public func sample(_ source: DataSource) async throws -> Fetched {
        var params = source.sampleValues
        let registry = ModuleRegistry.shared
        let fetched = registry.fetchedNames(in: source.urlNames).filter { params[$0] == nil && registry.module(fetching: $0) !== self }
        if !fetched.isEmpty {
            params.merge(try await registry.fetch(fetched, params: params, now: Date())) { given, _ in given }
        }
        return try await fetcher.fetch(source, params: params, key: key(for: source.id), useCache: false)
    }

    /// Claude's rule for what the source wants, checked against a sample.
    public func findRule(for source: DataSource, in sample: Fetched) async throws -> RuleFinder.Proposal {
        guard let claude = ModuleRegistry.shared.module(id: ClaudeModule.id) as? ClaudeModule, claude.isReady else {
            throw ModuleError("Finding the value needs Claude", "Add your Anthropic API key in Settings → Claude.")
        }
        let finder = RuleFinder { system, prompt, schema in
            try await claude.ask(system: system, prompt: prompt, schema: schema)
        }
        return try await finder.find(source.wanted, in: sample, secrets: [key(for: source.id)].compactMap { $0 })
    }

    /// Fetches the source with its sample values and applies its rule, noting
    /// the value — or that the rule is broken.
    @discardableResult
    public func test(_ source: DataSource) async throws -> String {
        let fetched = try await sample(source)
        return try extract(source, from: fetched)
    }

    // MARK: - Fetching values

    public func fetch(_ names: [String], params: [String: String], now: Date) async throws -> [String: String] {
        var wanted: [(name: String, source: DataSource, raw: Bool)] = []
        for name in names {
            let (sourceName, raw) = Self.parse(name)
            guard let source = source(named: sourceName) else {
                throw ModuleError("There's no data source called “\(sourceName)”", "Add it in Data Sources, in the menu bar.")
            }
            if !raw, source.rule == nil {
                throw ModuleError("“\(source.name)” has no rule yet", "Open Data Sources and use Find It.")
            }
            wanted.append((name, source, raw))
        }

        // Each source fetched once, all at once.
        let sources = Dictionary(wanted.map { ($0.source.id, $0.source) }, uniquingKeysWith: { first, _ in first })
        let responses = try await withThrowingTaskGroup(of: (UUID, Fetched).self) { group in
            for source in sources.values {
                let key = key(for: source.id)
                group.addTask { [fetcher] in (source.id, try await fetcher.fetch(source, params: params, key: key, now: now)) }
            }
            var responses: [UUID: Fetched] = [:]
            for try await (id, fetched) in group { responses[id] = fetched }
            return responses
        }

        var values: [String: String] = [:]
        for item in wanted {
            guard let fetched = responses[item.source.id] else { continue }
            values[item.name] = item.raw ? fetched.text : try extract(item.source, from: fetched)
        }
        return values
    }

    /// The rule's value, or — if it finds nothing — the source marked broken
    /// and an error that says where to fix it.
    private func extract(_ source: DataSource, from fetched: Fetched) throws -> String {
        guard let rule = source.rule else { throw ModuleError("“\(source.name)” has no rule yet", "Use Find It first.") }
        var reason: String?
        var value = ""
        do {
            value = try rule.value(in: fetched.body, contentType: fetched.contentType)
            if value.isEmpty { reason = "Its rule found nothing in the latest response." }
        } catch {
            reason = "\(error)"
        }
        var updated = self.source(named: source.name) ?? source
        updated.lastChecked = fetched.at
        if let reason {
            updated.broken = reason
            save(updated)
            throw ModuleError("“\(source.name)” didn't find its value",
                              "The API may have changed. Open Data Sources in the menu bar and use Find It Again.")
        }
        updated.lastValue = value
        updated.broken = nil
        save(updated)
        return value
    }

    /// `api.weather` → ("weather", false); `api.weather.raw` → ("weather", true).
    static func parse(_ name: String) -> (source: String, raw: Bool) {
        var rest = name.hasPrefix(id + ".") ? String(name.dropFirst(id.count + 1)) : name
        let raw = rest.hasSuffix(".raw")
        if raw { rest = String(rest.dropLast(4)) }
        return (rest, raw)
    }

    public func valuesNeeded(toFetch names: [String]) -> Set<String> {
        var needed = Set<String>()
        for name in names {
            if let source = source(named: Self.parse(name).source) { needed.formUnion(source.urlNames) }
        }
        return needed
    }

    public func fetchSubject(for names: [String]) -> String {
        var sources: [String] = []
        for name in names where !sources.contains(Self.parse(name).source) { sources.append(Self.parse(name).source) }
        return sources.joined(separator: ", ")
    }

    public func standIn(forValue name: String) -> String {
        let (source, raw) = Self.parse(name)
        return raw ? "‹\(source) response›" : "‹\(source)›"
    }

    // MARK: - The menu

    public func menuItems(now: Date) -> [ModuleMenuItem] {
        let broken = sources.filter { $0.broken != nil }
        return [ModuleMenuItem(id: "open", title: "Edit Data Sources…", isEnabled: true)]
            + broken.map { .information("⚠︎ \($0.name) needs fixing") }
    }

    public func performMenuItem(_ id: String, now: Date) -> ActionOutcome? {
        guard id == "open" else { return nil }
        MainActor.assumeIsolated { openWindow?(self) }
        return nil
    }

    // MARK: - Not an action

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        ModuleSummary(verb: "Fetch", subject: request.leaf)
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        .failure("Data sources give values to other actions; they aren't actions themselves.")
    }
}
