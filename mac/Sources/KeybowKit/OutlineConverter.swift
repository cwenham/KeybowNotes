import Foundation

/// Converts a numbered outline into a config file.
///
///     # main                        ← optional; also "# row 2", "# row 3", "# bottom"
///     1. Work
///        1. Meeting (Calendar, 5 min alert)
///           1. Today
///        3.                         ← an empty key
///        4. Notes
///           1. Work log (worklog.md)
///
/// Numbers are key positions (1-4, left to right). Indentation is nesting.
/// Brackets hold annotations, comma-separated:
///
///   Notes, Calendar, Reminders, Messages, Mail   the action type
///   an app name (Rider, VSCode, KiCad…)          open the leaf in that app
///   something.md                                 a template file
///   5 min alert / 1 hour alert                   an alert before an event
///   append / new                                 append to a note / create one
///   anything else under an app                   a channel or target in it
///
/// Annotations apply to everything beneath, until something deeper overrides
/// them. Lines that are not numbered items are ignored, as are headings that do
/// not name a tree, so a title line is fine.
public enum OutlineConverter {
    public struct AppMatch: Equatable {
        public let name: String
        public let installed: Bool
        /// Leaves under a service app (Discord, Mastodon…) are channels or
        /// targets; under anything else they are projects with a file to open.
        public let isService: Bool
        /// Lets the app be found wherever it is installed, at run time.
        public let bundleIdentifier: String?

        public init(name: String, installed: Bool, isService: Bool, bundleIdentifier: String? = nil) {
            self.name = name
            self.installed = installed
            self.isService = isService
            self.bundleIdentifier = bundleIdentifier
        }
    }

    public struct Result {
        public let json: String
        /// Things the converter decided that a person should check.
        public let inferences: [String]
        /// Values it could not know: paths, phone numbers, URLs.
        public let todo: [String]
        public let warnings: [String]
    }

    public enum ConversionError: Error, CustomStringConvertible {
        case badKeyNumber(line: Int, number: Int)
        case duplicateKey(line: Int, number: Int)

        public var description: String {
            switch self {
            case .badKeyNumber(let line, let number):
                return "line \(line): item \(number) — keys are numbered 1 to 4"
            case .duplicateKey(let line, let number):
                return "line \(line): a second item \(number) at the same level"
            }
        }
    }

    public static func convert(
        _ outline: String,
        locateApp: @escaping (String) -> AppMatch? = AppLocator.locate
    ) throws -> Result {
        let parsed = try parse(outline)
        var emitter = Emitter(locateApp: locateApp)

        var trees: [(String, OrderedJSON)] = []
        for kind in TreeKind.allCases {
            guard let items = parsed[kind], !items.isEmpty else { continue }
            let nodes = items.enumerated().map { index, item in
                emitter.node(item, context: Emitter.Context(type: nil, app: nil),
                             colour: Emitter.palette[index % Emitter.palette.count])
            }
            trees.append((kind.rawValue, .array(nodes)))
        }

        var document: [(String, OrderedJSON)] = [
            ("version", .number(Double(KeybowConfig.supportedVersion))),
            ("defaults", .object([
                ("colour", .string("202020")),
                ("commitDelayMs", .number(1000)),
                ("idleTimeoutMs", .number(10000)),
                ("longPressCancelMs", .number(1500)),
                ("dates", .object([("todayOffsetMinutes", .number(30)), ("defaultTime", .string("09:00"))])),
            ])),
        ]
        if !emitter.contacts.isEmpty {
            let contacts: [(String, OrderedJSON)] = emitter.contacts.map { name, fields in
                (name, .object(fields.map { ($0, OrderedJSON.string("")) }))
            }
            document.append(("contacts", .object(contacts)))
        }
        if !emitter.projects.isEmpty {
            let projects: [(String, OrderedJSON)] = emitter.projects
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { ($0, .object([("path", .string(""))])) }
            document.append(("projects", .object(projects)))
        }
        document.append(("trees", .object(trees)))

        var todo: [String] = []
        for (name, fields) in emitter.contacts {
            todo.append("contacts.\"\(name)\": fill in \(fields.joined(separator: " and "))")
        }
        for name in emitter.projects.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            todo.append("projects.\"\(name)\": fill in the path to open")
        }
        todo.append(contentsOf: emitter.todo)

        return Result(
            json: OrderedJSON.object(document).render() + "\n",
            inferences: emitter.inferences,
            todo: todo,
            warnings: emitter.warnings
        )
    }

    // MARK: - Parsing

    final class Item {
        let label: String
        let key: Int
        let annotations: [String]
        let line: Int
        var children: [Item] = []

        init(label: String, key: Int, annotations: [String], line: Int) {
            self.label = label
            self.key = key
            self.annotations = annotations
            self.line = line
        }
    }

    static func parse(_ outline: String) throws -> [TreeKind: [Item]] {
        var trees: [TreeKind: [Item]] = [:]
        var tree = TreeKind.main
        var stack: [(indent: Int, item: Item)] = []

        for (offset, rawLine) in outline.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#") {
                let name = trimmed.drop(while: { $0 == "#" })
                    .replacingOccurrences(of: "tree", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespaces)
                // Headings that don't name a tree are titles; ignore them.
                if let kind = TreeKind(name: name) {
                    tree = kind
                    stack = []
                }
                continue
            }

            // "  3. Label (annotations)"
            let indent = line.prefix(while: { $0 == " " }).count
            let digits = trimmed.prefix(while: { $0.isNumber })
            guard !digits.isEmpty, trimmed.dropFirst(digits.count).first == "." else { continue }
            guard let number = Int(digits) else { continue }
            guard (1...KeybowProtocol.columns).contains(number) else {
                throw ConversionError.badKeyNumber(line: lineNumber, number: number)
            }
            let text = trimmed.dropFirst(digits.count + 1).trimmingCharacters(in: .whitespaces)

            while let last = stack.last, last.indent >= indent { stack.removeLast() }

            // An empty item keeps its key free and has nothing beneath it.
            guard !text.isEmpty else { continue }

            let (label, annotations) = splitAnnotations(text)
            let item = Item(label: label, key: number - 1, annotations: annotations, line: lineNumber)
            let siblings = stack.last?.item.children ?? trees[tree] ?? []
            if siblings.contains(where: { $0.key == item.key }) {
                throw ConversionError.duplicateKey(line: lineNumber, number: number)
            }
            if let parent = stack.last?.item {
                parent.children.append(item)
            } else {
                trees[tree, default: []].append(item)
            }
            stack.append((indent, item))
        }
        return trees
    }

    /// "Project A (Rider, 5 min alert)" → ("Project A", ["Rider", "5 min alert"])
    static func splitAnnotations(_ text: String) -> (String, [String]) {
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return (text, []) }
        let label = text[..<open].trimmingCharacters(in: .whitespaces)
        let inside = text[text.index(after: open)..<text.index(before: text.endIndex)]
        let annotations = inside.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (label.isEmpty ? text : label, annotations)
    }

    // MARK: - Emitting

    private struct Emitter {
        struct Context {
            var type: String?
            var app: AppMatch?
        }

        static let palette = ["0060ff", "00c060", "ff8c00", "b060ff"]
        static let actionTypes: [String: String] = [
            "notes": "notes.create",
            "calendar": "calendar.createEvent",
            "reminders": "reminders.create",
            "messages": "messages.compose",
            "mail": "mail.compose",
        ]

        let locateApp: (String) -> AppMatch?
        var contacts: [(String, [String])] = []
        var projects: [String] = []
        var inferences: [String] = []
        var todo: [String] = []
        var warnings: [String] = []
        private var reportedApps: Set<String> = []

        init(locateApp: @escaping (String) -> AppMatch?) {
            self.locateApp = locateApp
        }

        mutating func node(_ item: Item, context inherited: Context, colour: String?) -> OrderedJSON {
            var context = inherited
            var action: [(String, OrderedJSON)] = []
            var params: [(String, OrderedJSON)] = []
            var declaredType: String?

            func set(_ key: String, _ value: OrderedJSON) {
                action.removeAll { $0.0 == key }
                action.append((key, value))
            }
            func declare(_ type: String) {
                declaredType = type
                context.type = type
                if type != "app.open" { context.app = nil }
            }

            for annotation in item.annotations {
                let lower = annotation.lowercased()
                if let minutes = Self.alertMinutes(lower) {
                    set("alertMinutes", .number(Double(minutes)))
                } else if lower.hasSuffix(".md") {
                    set("template", .string(annotation))
                    // A template named Append… or New… says which it means.
                    if declaredType == nil, lower.hasPrefix("append") {
                        declare("notes.append")
                        inferences.append("line \(item.line): \"\(item.label)\" appends to a note, from the template name \(annotation)")
                    } else if declaredType == nil, lower.hasPrefix("new") {
                        declare("notes.create")
                        inferences.append("line \(item.line): \"\(item.label)\" creates a new note, from the template name \(annotation)")
                    }
                } else if lower == "append" {
                    declare("notes.append")
                } else if lower == "new" || lower == "create" {
                    declare("notes.create")
                } else if let type = Self.actionTypes[lower] {
                    declare(type)
                } else if let app = locateApp(annotation) {
                    declare("app.open")
                    context.app = app
                    set("app", .string(app.name))
                    if let bundle = app.bundleIdentifier { set("bundleId", .string(bundle)) }
                    if !app.installed {
                        warnings.append("line \(item.line): \(app.name) is not in /Applications")
                    } else if Self.normalised(annotation) != Self.normalised(app.name),
                              !reportedApps.contains(annotation) {
                        reportedApps.insert(annotation)
                        inferences.append("\"\(annotation)\" opens \(app.name), the one installed here")
                    }
                } else if context.type == "app.open" {
                    set("target", .string(annotation))
                    todo.append("line \(item.line): \"\(item.label) (\(annotation))\" needs a URL or path for \(context.app?.name ?? "the app") to open")
                } else if annotation.first?.isUppercase == true {
                    declare("app.open")
                    let app = AppMatch(name: annotation, installed: false, isService: false)
                    context.app = app
                    set("app", .string(annotation))
                    warnings.append("line \(item.line): assuming \"\(annotation)\" is an app, but it is not in /Applications")
                } else {
                    params.append(("note", .string(annotation)))
                    warnings.append("line \(item.line): did not understand \"(\(annotation))\" on \"\(item.label)\"; kept as params.note")
                }
            }
            if let declaredType { action.insert(("type", .string(declaredType)), at: 0) }

            // What does a leaf mean, given the action it inherits?
            if item.children.isEmpty {
                leafValues(item, context: context, declaredHere: declaredType != nil,
                           hasTarget: action.contains { $0.0 == "target" }, params: &params)
            }

            var fields: [(String, OrderedJSON)] = [("label", .string(item.label)), ("key", .number(Double(item.key)))]
            if let colour { fields.append(("colour", .string(colour))) }
            if !params.isEmpty { fields.append(("params", .object(params))) }
            if !action.isEmpty { fields.append(("action", .object(action))) }
            if !item.children.isEmpty {
                let children = item.children.map { node($0, context: context, colour: nil) }
                fields.append(("children", .array(children)))
            }
            return .object(fields)
        }

        private mutating func leafValues(_ item: Item, context: Context, declaredHere: Bool, hasTarget: Bool,
                                         params: inout [(String, OrderedJSON)]) {
            switch context.type {
            case "calendar.createEvent":
                let phrase = item.label.lowercased()
                if DateExpression.resolve(phrase, now: Date()) != nil {
                    params.append(("when", .string(phrase)))
                } else {
                    todo.append("line \(item.line): \"\(item.label)\" is an event with no date; add params.when")
                }
            case "messages.compose":
                addContact(item.label, field: "phone")
            case "mail.compose":
                addContact(item.label, field: "email")
            case "app.open":
                guard let app = context.app else { break }
                let justTheApp = declaredHere && (Self.normalised(item.label) == Self.normalised(app.name)
                    || item.annotations.contains { Self.normalised($0) == Self.normalised(item.label) })
                if justTheApp {
                    break
                } else if app.isService {
                    // A channel or page in the app. A bracketed target has
                    // already been noted; otherwise the label is all we have.
                    if !hasTarget {
                        todo.append("line \(item.line): \"\(item.label)\" needs a URL for \(app.name) to open")
                    }
                } else {
                    addProject(item.label)
                }
            default:
                break
            }
        }

        private mutating func addContact(_ name: String, field: String) {
            if let index = contacts.firstIndex(where: { $0.0 == name }) {
                if !contacts[index].1.contains(field) { contacts[index].1.append(field) }
            } else {
                contacts.append((name, [field]))
            }
        }

        private mutating func addProject(_ name: String) {
            if !projects.contains(name) { projects.append(name) }
        }

        static func normalised(_ name: String) -> String {
            name.lowercased().replacingOccurrences(of: " ", with: "")
        }

        /// "5 min alert", "20 minute alert", "1 hour alert" → minutes.
        static func alertMinutes(_ text: String) -> Int? {
            guard text.hasSuffix("alert") else { return nil }
            let words = text.split(separator: " ")
            guard words.count >= 3, let value = Int(words[0]) else { return nil }
            switch words[1] {
            case "m", "min", "mins", "minute", "minutes": return value
            case "h", "hr", "hour", "hours": return value * 60
            default: return nil
            }
        }
    }
}

/// Finds apps by the names people actually call them.
public enum AppLocator {
    private struct Known {
        let bundleNames: [String]
        let isService: Bool
    }

    /// Keys are lowercased with spaces removed.
    private static let known: [String: Known] = [
        "vscode": Known(bundleNames: ["Visual Studio Code"], isService: false),
        "visualstudiocode": Known(bundleNames: ["Visual Studio Code"], isService: false),
        "rider": Known(bundleNames: ["Rider"], isService: false),
        "prusaslicer": Known(bundleNames: ["PrusaSlicer", "Original Prusa Drivers/PrusaSlicer"], isService: false),
        "fusion": Known(bundleNames: ["Autodesk Fusion", "Autodesk Fusion 360"], isService: false),
        "fusion360": Known(bundleNames: ["Autodesk Fusion 360", "Autodesk Fusion"], isService: false),
        "kicad": Known(bundleNames: ["KiCad", "KiCad/KiCad"], isService: false),
        "thonny": Known(bundleNames: ["Thonny"], isService: false),
        "inkscape": Known(bundleNames: ["Inkscape"], isService: false),
        "lightburn": Known(bundleNames: ["LightBurn"], isService: false),
        "xcode": Known(bundleNames: ["Xcode"], isService: false),
        "claude": Known(bundleNames: ["Claude"], isService: true),
        "discord": Known(bundleNames: ["Discord"], isService: true),
        "mastodon": Known(bundleNames: ["Mastodon", "Ivory", "Ice Cubes"], isService: true),
        "meshtastic": Known(bundleNames: ["Meshtastic"], isService: true),
    ]

    private static var searchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
    }

    public static func locate(_ name: String) -> OutlineConverter.AppMatch? {
        let key = name.lowercased().replacingOccurrences(of: " ", with: "")
        let entry = known[key]
        let candidates = entry?.bundleNames ?? [name]

        for candidate in candidates {
            if let path = installedPath(candidate) {
                let display = candidate.split(separator: "/").last.map(String.init) ?? candidate
                return OutlineConverter.AppMatch(
                    name: display,
                    installed: true,
                    isService: entry?.isService ?? false,
                    bundleIdentifier: Bundle(url: path)?.bundleIdentifier
                )
            }
        }
        // A name we recognise, just not installed here.
        if let entry, let first = entry.bundleNames.first {
            return OutlineConverter.AppMatch(name: first, installed: false, isService: entry.isService)
        }
        return nil
    }

    private static func installedPath(_ name: String) -> URL? {
        let manager = FileManager.default
        for directory in searchDirectories {
            let direct = directory.appendingPathComponent(name + ".app")
            if manager.fileExists(atPath: direct.path) { return direct }
            // Some apps install inside a folder of their own: /Applications/KiCad/KiCad.app
            let nested = directory.appendingPathComponent(name).appendingPathComponent(name + ".app")
            if manager.fileExists(atPath: nested.path) { return nested }
        }
        return nil
    }
}

/// JSON with keys in a chosen order, printed compactly where it stays readable.
indirect enum OrderedJSON {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    func render(indent: Int = 0) -> String {
        let inline = renderInline()
        if !containsArray, inline.count + indent * 2 <= 100 { return inline }

        let pad = String(repeating: "  ", count: indent + 1)
        let closing = String(repeating: "  ", count: indent)
        switch self {
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + items.map { pad + $0.render(indent: indent + 1) }.joined(separator: ",\n") + "\n\(closing)]"
        case .object(let pairs):
            guard !pairs.isEmpty else { return "{}" }
            return "{\n" + pairs.map { pad + Self.quote($0.0) + ": " + $0.1.render(indent: indent + 1) }
                .joined(separator: ",\n") + "\n\(closing)}"
        default:
            return inline
        }
    }

    private var containsArray: Bool {
        switch self {
        case .array: return true
        case .object(let pairs): return pairs.contains { $0.1.containsArray }
        default: return false
        }
    }

    private func renderInline() -> String {
        switch self {
        case .string(let text): return Self.quote(text)
        case .number(let value):
            return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        case .array(let items): return "[" + items.map { $0.renderInline() }.joined(separator: ", ") + "]"
        case .object(let pairs):
            guard !pairs.isEmpty else { return "{}" }
            return "{ " + pairs.map { Self.quote($0.0) + ": " + $0.1.renderInline() }.joined(separator: ", ") + " }"
        }
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
