import Foundation
import KeybowKit

/// `{{quote file="quotes.md"}}`: a portion of a file — a paragraph, or a list
/// item — picked each time a key uses it.
///
///   {{quote file="fortunes.txt"}}                       any paragraph, at random
///   {{quote file="quotes.md" heading="Stoics"}}         an item under “Stoics”
///   {{quote file="reading.html" order=sequential}}      the next item, in turn
///
/// `file` is found in the templates folder beside the tree, unless it's a full
/// or `~/` path. Attribute values can hold placeholders — `heading="{{leaf}}"`
/// picks from the list named by the key chosen. In sequence, the place in each
/// list is kept in this module's part of `state.json`, and starts again from
/// the top once the list is done. At random, the same item never comes twice
/// running.
public final class QuoteModule: KeybowModule, @unchecked Sendable {
    public static let id = "quote"
    static let attributes: Set<String> = ["file", "heading", "order"]
    /// The most of a file that's read: a list of quotes, not a book.
    static let maximumSize = 5_000_000

    public let manifest = ModuleManifest(id: id, name: "Quotes", fetches: [id])

    /// What's kept between runs, per list: `<path>#<heading>`.
    struct Saved: Codable, Equatable {
        /// The next item to give, in sequence.
        var next: [String: Int] = [:]
        /// The item given last, at random.
        var last: [String: Int] = [:]
    }

    enum Order: String { case random, sequential }

    private let lock = NSLock()
    private var saved = Saved()
    private var host: ModuleHost?
    /// Picks a number in the range — `Int.random` but for tests.
    private let random: @Sendable (Range<Int>) -> Int

    public init(random: @escaping @Sendable (Range<Int>) -> Int = { Int.random(in: $0) }) {
        self.random = random
    }

    public func start(host: ModuleHost) {
        self.host = host
        if let data = host.load("positions", for: Self.id), let loaded = try? JSONDecoder().decode(Saved.self, from: data) {
            lock.withLock { saved = loaded }
        }
    }

    // MARK: - Fetching

    struct Request {
        let url: URL
        let heading: String?
        let order: Order

        /// Which list: a file, narrowed by a heading.
        var list: String { url.path + "#" + (heading.map(TextPortions.normalised) ?? "") }
    }

    public func fetch(_ names: [String], params: [String: String], now: Date) async throws -> [String: String] {
        var values: [String: String] = [:]
        // The same list, the same way, twice in one press: one pick.
        var picked: [String: String] = [:]
        for name in names {
            let request = try self.request(for: name, params: params, now: now)
            let pick = "\(request.order.rawValue) \(request.list)"
            if let value = picked[pick] {
                values[name] = value
                continue
            }
            let value = try choose(from: portions(for: request), in: request)
            picked[pick] = value
            values[name] = value
        }
        let data = lock.withLock { try? JSONEncoder().encode(saved) }
        host?.save(data, as: "positions", for: Self.id)
        return values
    }

    func request(for name: String, params: [String: String], now: Date) throws -> Request {
        guard let call = Template.operatorCall(name), call.name == Self.id else {
            throw ModuleError("{{\(name)}} needs a file to quote from",
                              "Write it as {{quote file='quotes.txt'}}, with the file in the templates folder beside tree.md.")
        }
        if let unknown = call.attributes.keys.sorted().first(where: { !Self.attributes.contains($0) }) {
            throw ModuleError("{{quote}} doesn't take “\(unknown)”", "It takes file, heading and order.")
        }
        func value(_ key: String) throws -> String? {
            guard let raw = call.attributes[key] else { return nil }
            let expanded = Template.expand(raw, params: params, now: now)
            if let missing = expanded.missing.first {
                throw ModuleError("{{quote}}'s \(key) needs a value for {{\(missing)}}")
            }
            let text = expanded.text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        guard let file = try value("file") else {
            throw ModuleError("{{quote}} needs a file", "Write it as {{quote file='quotes.txt'}}.")
        }
        let orderName = try value("order")?.lowercased() ?? Order.random.rawValue
        guard let order = Order(rawValue: orderName) else {
            throw ModuleError("{{quote}}'s order is random or sequential, not “\(orderName)”")
        }
        return Request(url: try Self.resolve(file, in: host?.templatesFolder), heading: try value("heading"), order: order)
    }

    /// A full or `~/` path as it is; anything else in the templates folder.
    static func resolve(_ file: String, in folder: URL?) throws -> URL {
        let path = (file as NSString).expandingTildeInPath
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        guard let folder else {
            throw ModuleError("There's no templates folder to find “\(file)” in", "Give its full path instead.")
        }
        return folder.appendingPathComponent(file).standardizedFileURL
    }

    func portions(for request: Request) throws -> [String] {
        let name = request.url.lastPathComponent
        let size = (try? request.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maximumSize else { throw ModuleError("“\(name)” is too big to quote from", "It's over 5 MB.") }
        let data: Data
        do {
            data = try Data(contentsOf: request.url)
        } catch {
            throw ModuleError("There's no “\(name)” to quote from",
                              "Looked for \((request.url.path as NSString).abbreviatingWithTildeInPath).")
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)

        let portions: [String]
        do {
            portions = try TextPortions.portions(of: text, format: TextPortions.Format(fileExtension: request.url.pathExtension),
                                                 heading: request.heading)
        } catch TextPortions.Problem.headingsNeedStructure {
            throw ModuleError("“\(name)” is plain text, with no headings to pick by",
                              "Headings work in Markdown (.md) and HTML files.")
        } catch TextPortions.Problem.noHeading(let heading, let available) {
            throw ModuleError("“\(name)” has no heading “\(heading)” with a list under it",
                              available.isEmpty ? "It has no headings over its lists."
                                  : "It has " + available.prefix(8).map { "“\($0)”" }.joined(separator: ", ") + ".")
        } catch TextPortions.Problem.unreadableHTML(let reason) {
            throw ModuleError("“\(name)” isn't HTML that can be read", reason)
        }
        guard !portions.isEmpty else {
            let what = TextPortions.Format(fileExtension: request.url.pathExtension) == .plain ? "no paragraphs" : "no list items"
            throw ModuleError("“\(name)” has \(what)\(request.heading.map { " under “\($0)”" } ?? "") to quote")
        }
        return portions
    }

    func choose(from portions: [String], in request: Request) -> String {
        lock.withLock {
            let count = portions.count
            switch request.order {
            case .sequential:
                // A list that shrank starts again from the top.
                let index = (saved.next[request.list] ?? 0) < count ? (saved.next[request.list] ?? 0) : 0
                saved.next[request.list] = (index + 1) % count
                return portions[index]
            case .random:
                var index = 0
                if count > 1 {
                    // Any but the last one given, each as likely as the others.
                    index = random(0..<(count - 1))
                    if let last = saved.last[request.list], last < count, index >= last { index += 1 }
                }
                saved.last[request.list] = index
                return portions[index]
            }
        }
    }

    public func valuesNeeded(toFetch names: [String]) -> Set<String> {
        var needed = Set<String>()
        for name in names {
            for value in Template.operatorCall(name)?.attributes.values ?? [:].values {
                needed.formUnion(Template.names(in: value))
            }
        }
        return needed
    }

    public func standIn(forValue name: String) -> String {
        guard let call = Template.operatorCall(name), let file = call.attributes["file"],
              !file.contains("{{") else { return "‹a quote›" }
        let heading = call.attributes["heading"].flatMap { $0.contains("{{") ? nil : $0 }
        return "‹a quote from \((file as NSString).lastPathComponent)\(heading.map { ", \($0)" } ?? "")›"
    }

    public func fetchSubject(for names: [String]) -> String { "a quote" }

    // MARK: - Not an action

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        ModuleSummary(verb: "Quote", subject: request.leaf)
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        .failure("{{quote}} gives a value to other actions; it isn't an action itself.")
    }
}
