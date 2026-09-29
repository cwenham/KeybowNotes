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
        // The sample's values are ones that should find something.
        return try extract(source, from: fetched, emptyIsBroken: true)
    }

    // MARK: - Fetching values

    public func fetch(_ names: [String], params: [String: String], now: Date) async throws -> [String: String] {
        /// One use of a source: its values, and which fetch answers it.
        struct Use {
            let name: String
            let source: DataSource
            let raw: Bool
            let given: [String: String]
            /// The same source with the same values is fetched once.
            var fetch: String { source.id.uuidString + given.sorted { $0.key < $1.key }.map { " \($0.key)=\($0.value)" }.joined() }
        }
        var uses: [Use] = []
        for name in names {
            let (sourceName, raw, attributes) = Self.parse(name)
            guard let source = source(named: sourceName) else {
                throw ModuleError("There's no data source called “\(sourceName)”", "Add it in Data Sources, in the menu bar.")
            }
            if !raw, source.rule == nil {
                throw ModuleError("“\(source.name)” has no rule yet", "Open Data Sources and use Find It.")
            }
            uses.append(Use(name: name, source: source, raw: raw,
                            given: try Self.values(of: attributes, for: source, params: params, now: now)))
        }

        // All at once, each distinct URL once.
        let responses = try await withThrowingTaskGroup(of: (String, Fetched).self) { group in
            var started = Set<String>()
            for use in uses where started.insert(use.fetch).inserted {
                let key = key(for: use.source.id)
                let values = params.merging(use.given) { _, given in given }
                group.addTask { [fetcher] in (use.fetch, try await fetcher.fetch(use.source, params: values, key: key, now: now)) }
            }
            var responses: [String: Fetched] = [:]
            for try await (fetch, fetched) in group { responses[fetch] = fetched }
            return responses
        }

        var values: [String: String] = [:]
        for use in uses {
            guard let fetched = responses[use.fetch] else { continue }
            values[use.name] = use.raw ? fetched.text
                : try extract(use.source, from: fetched, given: use.given, emptyIsBroken: use.source.urlNames.isEmpty)
        }
        return values
    }

    /// What a use's attributes give its URL — `term={{selection}}`, filled in —
    /// each for a placeholder the URL has.
    static func values(of attributes: [String: String], for source: DataSource, params: [String: String],
                       now: Date) throws -> [String: String] {
        var values: [String: String] = [:]
        for (key, text) in attributes.sorted(by: { $0.key < $1.key }) {
            guard source.urlNames.contains(key) else {
                let names = source.urlNames.sorted().map { "{{\($0)}}" }
                throw ModuleError("“\(source.name)”'s URL has no {{\(key)}}",
                                  names.isEmpty ? "It takes no values." : "It uses " + names.joined(separator: ", ") + ".")
            }
            let expanded = Template.expand(text, params: params, now: now)
            if let missing = expanded.missing.first {
                throw ModuleError("“\(source.name)” needs a value for {{\(key)}}",
                                  missing == "selection" ? "It's given {{selection}}, and nothing is selected."
                                      : "It's given {{\(missing)}}, which has no value.")
            }
            values[key] = expanded.text
        }
        return values
    }

    /// The rule's value, or — if it finds nothing — the source marked broken
    /// and an error that says where to fix it. A source whose URL takes values
    /// may rightly find nothing for some — a search with no results — so
    /// unless `emptyIsBroken`, finding nothing only stops the action; a
    /// response the rule can't read at all still marks it.
    private func extract(_ source: DataSource, from fetched: Fetched, given: [String: String] = [:],
                         emptyIsBroken: Bool) throws -> String {
        guard let rule = source.rule else { throw ModuleError("“\(source.name)” has no rule yet", "Use Find It first.") }
        var reason: String?
        var value = ""
        do {
            value = try rule.value(in: fetched.body, contentType: fetched.contentType)
            if value.isEmpty {
                if !emptyIsBroken {
                    // The values go in the detail, which the log never gets: they can be the selection.
                    let asked = given.sorted { $0.key < $1.key }.map { "\($0.key) “\($0.value)”" }.joined(separator: ", ")
                    throw ModuleError("“\(source.name)” found nothing",
                                      (asked.isEmpty ? "Nothing" : "Nothing for \(asked)")
                                          + ". If there should be, the API may have changed: try Test Now in Data Sources.")
                }
                reason = "Its rule found nothing in the latest response."
            }
        } catch let error as ModuleError {
            throw error
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

    /// `api.weather` → ("weather", false, [:]); `api.weather.raw` →
    /// ("weather", true, [:]); `api.wikipedia term={{selection}}` →
    /// ("wikipedia", false, [term: {{selection}}]).
    static func parse(_ name: String) -> (source: String, raw: Bool, attributes: [String: String]) {
        let call = Template.operatorCall(name)
        let base = call?.name ?? name
        var rest = base.hasPrefix(id + ".") ? String(base.dropFirst(id.count + 1)) : base
        let raw = rest.hasSuffix(".raw")
        if raw { rest = String(rest.dropLast(4)) }
        return (rest, raw, call?.attributes ?? [:])
    }

    /// The URL's values its attributes don't give, and whatever those use.
    public func valuesNeeded(toFetch names: [String]) -> Set<String> {
        var needed = Set<String>()
        for name in names {
            let (sourceName, _, attributes) = Self.parse(name)
            if let source = source(named: sourceName) { needed.formUnion(source.urlNames.subtracting(attributes.keys)) }
            for value in attributes.values { needed.formUnion(Template.names(in: value)) }
        }
        return needed
    }

    public func fetchSubject(for names: [String]) -> String {
        var sources: [String] = []
        for name in names where !sources.contains(Self.parse(name).source) { sources.append(Self.parse(name).source) }
        return sources.joined(separator: ", ")
    }

    public func standIn(forValue name: String) -> String {
        let (source, raw, _) = Self.parse(name)
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
