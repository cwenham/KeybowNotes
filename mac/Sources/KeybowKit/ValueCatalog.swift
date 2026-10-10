import Foundation

/// A value that fields and templates can use — `{{leaf}}`, `{{date}}`,
/// `{{home.<domain>.<entity>}}` — described for someone choosing one: the
/// tree editor's list of values and its completion, and the agents' catalog.
/// Those built in are described in `ValueCatalog.builtIn`; a module describes
/// its own in its manifest.
public struct ValueEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Written as it is, perhaps with a fallback: `{{leaf}}`, `{{leaf|none}}`.
        case value
        /// A name with attributes: `{{quote file="quotes.md"}}`.
        case call
        /// Wraps text, and a reply takes its place: `{{#ai}}…{{/ai}}`.
        case block
    }

    /// As written between the braces. A part to fill in is in angle
    /// brackets, and stands for one part of a dotted name: `contact.<field>`,
    /// `api.<source>.raw`.
    public let name: String
    /// What it is, in a few words: "The key's label".
    public let title: String
    /// What it holds, and when it's empty.
    public let help: String
    /// How it's written, at its most useful: `{{date:EEEE d MMMM}}`.
    public let example: String
    /// What it gives, made up: "Standup". Empty when there's nothing to show.
    public let sample: String
    public let kind: Kind
    /// Fetched by a module when an action uses it — perhaps taking a moment —
    /// and shown in previews as a stand-in.
    public let fetched: Bool
    /// For a call or a block, and a value that takes them: what can go in
    /// its opening tag.
    public let attributes: [ValueAttribute]
    /// For a date or a time: formats to choose from, with what each gives.
    public let formats: [ValueFormat]
    /// For a family, `api.<source>`: its members are each listed by name, so
    /// a name none of them starts is a mistake, not one yet to be found.
    public let membersListed: Bool
    /// Where it's listed: "This key", "Date and time", the module's name.
    /// A module's are listed under its name.
    public internal(set) var group: String

    public init(_ name: String, title: String, help: String, example: String? = nil, sample: String = "",
                kind: Kind = .value, fetched: Bool = false, attributes: [ValueAttribute] = [],
                formats: [ValueFormat] = [], membersListed: Bool = false, group: String = "") {
        self.name = name
        self.title = title
        self.help = help
        self.example = example ?? (kind == .block ? "{{#\(name)}}…{{/\(name)}}" : "{{\(name)}}")
        self.sample = sample
        self.kind = kind
        self.fetched = fetched
        self.attributes = attributes
        self.formats = formats
        self.membersListed = membersListed
        self.group = group
    }

    /// What's put in for it, ready to fill in: `{{leaf}}`,
    /// `{{quote file=''}}`, `{{#ai}}{{/ai}}`. Single quotes, so it goes in an
    /// outline's quoted value as it is.
    public var insertion: String {
        switch kind {
        case .value: return "{{\(name)}}"
        case .call:
            let required = attributes.filter(\.required).map { " \($0.name)=''" }.joined()
            return "{{\(name)\(required)}}"
        case .block: return "{{#\(name)}}{{/\(name)}}"
        }
    }

    /// The parts of its name to fill in: `<domain>` and `<entity>`.
    public var holes: Int { name.filter { $0 == "<" }.count }

    /// Whether it describes this name: the name itself, or with each part to
    /// fill in standing for one part of a dotted name.
    func describes(_ given: String) -> Bool {
        guard holes > 0 else { return given == name }
        let given = given.split(separator: ".", omittingEmptySubsequences: false)
        let own = name.split(separator: ".", omittingEmptySubsequences: false)
        return given.count == own.count && zip(given, own).allSatisfy { given, own in
            own.hasPrefix("<") && own.hasSuffix(">") ? !given.isEmpty : given == own
        }
    }
}

/// What can go in a call's or a block's opening tag: `file="quotes.md"`.
public struct ValueAttribute: Equatable, Sendable {
    public let name: String
    public let help: String
    public let example: String
    /// The words it takes, when there are only a few.
    public let choices: [String]
    public let required: Bool

    public init(_ name: String, help: String, example: String = "", choices: [String] = [], required: Bool = false) {
        self.name = name
        self.help = help
        self.example = example
        self.choices = choices
        self.required = required
    }
}

/// A date format and what it gives: `EEEE d MMMM`, "Saturday 26 September".
public struct ValueFormat: Equatable, Sendable {
    public let pattern: String
    public let sample: String

    public init(_ pattern: String, _ sample: String) {
        self.pattern = pattern
        self.sample = sample
    }
}

/// Every value fields and templates can use here: those built in, and
/// those of the modules in a registry, data sources by name.
public struct ValueCatalog: Sendable {
    public let entries: [ValueEntry]

    public init(entries: [ValueEntry]) {
        self.entries = entries
    }

    public init(registry: ModuleRegistry = .shared) {
        self.init(modules: registry.all)
    }

    public init(modules: [KeybowModule]) {
        let given = modules.flatMap { module in
            (module.manifest.values + module.namedValues()).map { entry in
                var entry = entry
                if entry.group.isEmpty { entry.group = module.manifest.name }
                return entry
            }
        }
        self.init(entries: Self.builtIn + given)
    }

    /// The groups, in the order they're listed.
    public var groups: [String] {
        var seen = Set<String>()
        return entries.map(\.group).filter { seen.insert($0).inserted }
    }

    public func entries(in group: String) -> [ValueEntry] {
        entries.filter { $0.group == group }
    }

    /// What describes a name, as `Template.names` gives it — `leaf`, `date`
    /// without its format, `home.sensor.outdoor_temperature.unit`,
    /// `quote file="quotes.md"` — or a block's, with `block`. The name
    /// itself first; else the entry with the fewest parts to fill in, and
    /// of those the one that says most: `home.<domain>.<entity>.unit` over
    /// `home.<domain>.<entity>.<attribute>`.
    public func entry(named name: String, block: Bool = false) -> ValueEntry? {
        // A call's name is its first word; what follows is attributes.
        let name = String(name.prefix { !$0.isWhitespace })
        let candidates = entries.filter { ($0.kind == .block) == block && $0.describes(name) }
        return candidates.min { first, second in
            first.holes != second.holes ? first.holes < second.holes : first.name.count > second.name.count
        }
    }

    /// The names among these with nothing to describe them: for a module's
    /// tests, so what it gives stays described.
    public func undescribed(_ names: [String], blocks: Bool = false) -> [String] {
        names.filter { entry(named: $0, block: blocks) == nil }
    }
}

// MARK: - At a key

extension ValueCatalog {
    /// The values for one key: what the tree sets on the way to it — `area`
    /// from `area: work` on Work, the deeper winning — and the fields of its
    /// contact or project beyond those always described, each by name, with
    /// what it's set to; then the rest.
    public func atKey(_ selection: ResolvedSelection, config: KeybowConfig) -> ValueCatalog {
        var own: [ValueEntry] = []
        var setOn: [String: String] = [:]
        for node in config.nodes(in: selection.tree, along: selection.path) ?? [] {
            for name in node.params.keys { setOn[name] = node.label }
        }
        for (name, label) in setOn.sorted(by: { $0.key < $1.key }) {
            own.append(ValueEntry(name, title: name, help: "Set on \(label), for it and every key under it.",
                                  sample: selection.params[name] ?? "", group: "Set in the tree"))
        }
        // What the keys under a branch set: `when` on Today and Tomorrow, for
        // the branch's {{when}}.
        var below: [String: [(label: String, value: String)]] = [:]
        var pending = selection.node.children.compactMap { $0 }
        while let node = pending.popLast() {
            for (name, value) in node.params where setOn[name] == nil { below[name, default: []].append((node.label, value)) }
            pending += node.children.compactMap { $0 }
        }
        for (name, setters) in below.sorted(by: { $0.key < $1.key }) {
            let labels = setters.map(\.label)
            let which = labels.count <= 3 ? labels.joined(separator: ", ") : labels.prefix(2).joined(separator: ", ")
                + " and \(labels.count - 2) more"
            own.append(ValueEntry(name, title: name, help: "Set on keys under it: \(which). Each key has its own.",
                                  sample: setters.first?.value ?? "", group: "Set below"))
        }
        for (prefix, group) in [("contact.", "Contact"), ("project.", "Project")] {
            let fields = selection.params.keys.filter { $0.hasPrefix(prefix) && setOn[$0] == nil }
            for name in fields.sorted() where !entries.contains(where: { $0.holes == 0 && $0.name == name }) {
                let owner = selection.params[prefix + "name"] ?? ""
                own.append(ValueEntry(name, title: String(name.dropFirst(prefix.count)),
                                      help: "A field of \(owner)'s, in # \(group.lowercased())s.",
                                      sample: selection.params[name] ?? "", group: group))
            }
        }
        return ValueCatalog(entries: own + entries)
    }

    /// What text comes to for a key now, as previews show it: filled in from
    /// the tree, the clock and the modules' values, with stand-ins for what's
    /// only known when the key is pressed. Nothing is read, fetched or asked.
    public static func preview(of text: String, params: [String: String], registry: ModuleRegistry = .shared,
                               now: Date = Date(), calendar: Calendar = .current) -> Template.Result {
        ActionSummary.preview(text, params: ActionSummary.previewParams(params, registry: registry, now: now),
                              registry: registry, now: now, calendar: calendar)
    }
}

// MARK: - Built in

extension ValueCatalog {
    static let dateFormats = [
        ValueFormat("d MMM yyyy", "26 Sep 2026"), ValueFormat("d MMMM yyyy", "26 September 2026"),
        ValueFormat("EEEE d MMMM", "Saturday 26 September"), ValueFormat("EEE d MMM", "Sat 26 Sep"),
        ValueFormat("yyyy-MM-dd", "2026-09-26"), ValueFormat("dd/MM/yyyy", "26/09/2026"),
        ValueFormat("MMMM yyyy", "September 2026"),
    ]
    static let timeFormats = [ValueFormat("HH:mm", "14:07"), ValueFormat("HH:mm:ss", "14:07:00"), ValueFormat("h:mm a", "2:07 pm")]
    static let dateTimeFormats = [
        ValueFormat("d MMM yyyy, HH:mm", "26 Sep 2026, 14:07"), ValueFormat("yyyy-MM-dd HH:mm", "2026-09-26 14:07"),
        ValueFormat("EEEE d MMMM 'at' HH:mm", "Saturday 26 September at 14:07"),
    ]
    static let weekdayFormats = [ValueFormat("EEEE", "Saturday"), ValueFormat("EEE", "Sat")]

    private static let formatNote = "A format after a colon changes how it's written, in Unicode's date patterns."

    /// Those every action has, whatever modules are here. The samples are
    /// for Work › Meetings › Standup, pressed at 14:07 on Saturday 26
    /// September 2026.
    public static let builtIn: [ValueEntry] = {
        func key(_ name: String, _ title: String, _ help: String, _ sample: String) -> ValueEntry {
            ValueEntry(name, title: title, help: help, sample: sample, group: "This key")
        }
        func when(_ name: String, _ title: String, _ help: String, _ sample: String, _ formats: [ValueFormat] = [],
                  example: String? = nil) -> ValueEntry {
            ValueEntry(name, title: title, help: formats.isEmpty ? help : help + " " + formatNote, example: example,
                       sample: sample, formats: formats, group: "Date and time")
        }
        func mac(_ name: String, _ title: String, _ help: String, _ sample: String) -> ValueEntry {
            ValueEntry(name, title: title, help: help, sample: sample, group: "What you were doing")
        }
        func entry(_ name: String, _ title: String, _ help: String, _ sample: String, _ group: String,
                   example: String? = nil) -> ValueEntry {
            ValueEntry(name, title: title, help: help, example: example, sample: sample, group: group)
        }
        return [
            key("leaf", "The key's label", "The label of the key pressed: the last in the path.", "Standup"),
            key("parent", "The label above it",
                "The label pressed before it. A key on the tree's first row is its own parent.", "Meetings"),
            key("path", "The whole path", "Every label pressed, separated by “ / ”.", "Work / Meetings / Standup"),
            key("folderPath", "The path as folders",
                "The labels separated by /, for a Notes folder or a file's path. A / inside a label becomes -.",
                "Work/Meetings/Standup"),
            key("parentPath", "The folders above it", "The path as folders, without the key's own label.", "Work/Meetings"),
            key("level1", "The first label", "The label pressed first, on the tree's first row.", "Work"),
            key("level2", "The second label", "The second label pressed. Empty when the path is shorter.", "Meetings"),
            key("level3", "The third label", "The third label pressed. Empty when the path is shorter.", "Standup"),
            key("level4", "The fourth label", "The fourth label pressed. Empty when the path is shorter.", ""),
            key("tree", "Which tree", "The tree the key is in: main, row2, row3 or bottom.", "main"),

            entry("contact.name", "The contact's name", """
                The person this key is about: the deepest label on the path that's in # contacts, \
                or the one a contact: value names. Empty when there's none.
                """, "Alex Example", "Contact"),
            entry("contact.phone", "Their phone number", "From their entry in # contacts.", "+44 7700 900123", "Contact"),
            entry("contact.email", "Their email address", "From their entry in # contacts.", "alex@example.com", "Contact"),
            entry("contact.<field>", "Another of their fields", "Anything else their entry in # contacts holds, by its name.",
                  "", "Contact", example: "{{contact.discord}}"),
            entry("project.name", "The project's name", """
                The project this key is about: the deepest label on the path that's in # projects, \
                or the one a project: value names. Empty when there's none.
                """, "ProjectA", "Project"),
            entry("project.path", "Its folder", "From its entry in # projects.", "~/Projects/ProjectA", "Project"),
            entry("project.<field>", "Another of its fields", "Anything else its entry in # projects holds, by its name.",
                  "", "Project", example: "{{project.url}}"),

            when("date", "The date", "When the key is pressed.", "26 Sep 2026", dateFormats,
                 example: "{{date:EEEE d MMMM}}"),
            when("time", "The time", "When the key is pressed.", "14:07", timeFormats, example: "{{time:h:mm a}}"),
            when("datetime", "The date and time", "When the key is pressed.", "26 Sep 2026, 14:07", dateTimeFormats,
                 example: "{{datetime:yyyy-MM-dd HH:mm}}"),
            when("weekday", "The day of the week", "When the key is pressed.", "Saturday", weekdayFormats,
                 example: "{{weekday:EEE}}"),
            when("isoWeek", "The week of the year", "The ISO week number when the key is pressed, 1 to 53.", "39"),

            mac("selection", "The selected text", """
                The text selected in the app in front when the key is pressed, trimmed. Read only when an action \
                uses it. With nothing selected it's missing, which stops most actions: {{selection|}} makes empty fine.
                """, "the notes from today"),
            mac("clipboard", "The clipboard", """
                What's on the clipboard when the key is pressed: its text, trimmed — or an image or a PDF, which a \
                {{#ai}} block sends as itself, and anything else describes.
                """, "https://example.com/report"),
            mac("frontApp", "The app in front", "The app in front when the key is pressed.", "Safari"),
        ]
    }()
}
