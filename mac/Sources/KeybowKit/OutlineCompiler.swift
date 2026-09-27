import Foundation

/// What one bracket item means, in its place in the tree — for highlighting.
public enum AnnotationRole: Equatable, Sendable {
    /// `Calendar`, `Notes`… — the type it names.
    case actionType(String)
    /// `append`, `new`.
    case noteMode(String)
    case template
    case alert(minutes: Int)
    case app(name: String, installed: Bool)
    /// `https://…` written as a word: the link to open.
    case link
    /// A channel or place inside the app being opened.
    case target
    case listReference(exists: Bool)
    /// A recognised action field: `duration: 1h`, `find.byName: …`.
    case field
    case colour(valid: Bool)
    /// Any other `key: value`: a value for templates.
    case parameter
    case unknown
}

/// What the compiler learned about one node.
public struct OutlineNodeInfo: Sendable {
    /// Which tree it's in, or nil when it's in a list.
    public let tree: TreeKind?
    public let listName: String?
    /// Slot indices from the top of its tree or list.
    public let path: [Int]
    /// One per annotation, in the same order.
    public let roles: [AnnotationRole]
    public let diagnostics: [OutlineDiagnostic]
    /// The action type in force here, after this node's own annotations.
    public let actionType: String?
}

public struct OutlineCompilation: Sendable {
    public let json: String
    /// The config the JSON loads to — nil if it didn't, with the reason.
    public let config: KeybowConfig?
    public let configError: String?
    public let nodes: [UUID: OutlineNodeInfo]
    /// Things decided that a person should check.
    public let inferences: [String]
    /// Values nobody has supplied yet: phone numbers, paths, URLs.
    public let todo: [String]
    public let warnings: [String]

    public var diagnostics: [OutlineDiagnostic] {
        nodes.values.flatMap(\.diagnostics).sorted { $0.line < $1.line }
    }
}

public enum OutlineCompiler {
    /// Keywords naming an action type.
    public static let actionTypeWords: [String: String] = [
        "notes": "notes.create",
        "calendar": "calendar.createEvent",
        "reminders": "reminders.create",
        "messages": "messages.compose",
        "mail": "mail.compose",
        "call": "phone.call",
        "facetime": "phone.call",
        "link": "url.open",
        "browser": "url.open",
        "copy": "clipboard.copy",
        "clipboard": "clipboard.copy",
        "timer": "clock.timer",
        "maps": "maps.search",
        "music": "music.play",
    ]

    /// `key: value` pairs that set an action field rather than a template value.
    public static let actionFields: Set<String> = [
        "type", "folder", "title", "template", "account", "entry", "createIfMissing",
        "find.byName", "guards.maxBodyBytes", "guards.refuseInlineImages",
        "start", "duration", "alertMinutes", "calendar", "calendarId", "notes", "show",
        "due", "list", "to", "body", "subject",
        "app", "bundleId", "open", "url", "target", "name", "input", "via", "text",
        "shortcut", "query", "playlist", "album", "artist", "shuffle",
    ]
    /// A built-in action field, or one a module adds.
    public static func isActionField(_ key: String) -> Bool {
        actionFields.contains(key) || ModuleRegistry.shared.fields.contains { $0.key == key }
    }

    /// The type a keyword names, built in or from a module.
    public static func actionType(forKeyword word: String) -> String? {
        let lower = word.lowercased()
        return actionTypeWords[lower] ?? ModuleRegistry.shared.keywords[lower]
    }

    static func isNumericField(_ key: String) -> Bool {
        numericFields.contains(key) || ModuleRegistry.shared.fields.contains { $0.key == key && $0.kind == .number }
    }

    static func isBooleanField(_ key: String) -> Bool {
        booleanFields.contains(key) || ModuleRegistry.shared.fields.contains { $0.key == key && $0.kind == .flag }
    }

    static let numericFields: Set<String> = ["alertMinutes", "guards.maxBodyBytes"]
    static let booleanFields: Set<String> = ["createIfMissing", "show", "guards.refuseInlineImages", "shuffle"]
    static let numericDefaults: Set<String> = [
        "commitDelayMs", "idleTimeoutMs", "longPressCancelMs", "dates.todayOffsetMinutes", "dates.roundToMinutes",
    ]
    static let palette = ["0060ff", "00c060", "ff8c00", "b060ff"]

    /// The role of one annotation, given what the node inherits. Shared by the
    /// compiler and by the editor's highlighting as you type.
    public static func role(of annotation: Annotation, inheritedType: String?, inheritedApp: OutlineConverter.AppMatch?,
                            listNames: Set<String>,
                            locateApp: (String) -> OutlineConverter.AppMatch? = AppLocator.locate) -> AnnotationRole {
        switch annotation {
        case .word(let word):
            let lower = word.lowercased()
            if word.hasPrefix("@") { return .listReference(exists: listNames.contains(String(word.dropFirst()))) }
            if let minutes = alertMinutes(lower) { return .alert(minutes: minutes) }
            if word.contains("://") { return .link }
            if lower.hasSuffix(".md") { return .template }
            if lower == "append" { return .noteMode("notes.append") }
            if lower == "new" || lower == "create" { return .noteMode("notes.create") }
            if let type = actionType(forKeyword: lower) { return .actionType(type) }
            if let app = locateApp(word) { return .app(name: app.name, installed: app.installed) }
            if inheritedType == "app.open" { return .target }
            if word.first?.isUppercase == true { return .app(name: word, installed: false) }
            return .unknown
        case .pair(let key, let value):
            if key == "colour" || key == "color" { return .colour(valid: KeyColour(hex: value) != nil) }
            if isActionField(key) { return .field }
            return .parameter
        }
    }

    /// "5 min alert", "20 minute alert", "1 hour alert" → minutes.
    public static func alertMinutes(_ text: String) -> Int? {
        guard text.hasSuffix("alert") else { return nil }
        let words = text.split(separator: " ")
        guard words.count >= 3, let value = Int(words[0]) else { return nil }
        switch words[1] {
        case "m", "min", "mins", "minute", "minutes": return value
        case "h", "hr", "hour", "hours": return value * 60
        default: return nil
        }
    }

    public static func compile(_ document: OutlineDocument,
                               locateApp: @escaping (String) -> OutlineConverter.AppMatch? = AppLocator.locate)
    -> OutlineCompilation {
        var compiler = Compiler(document: document, locateApp: locateApp)
        let json = compiler.run()
        var config: KeybowConfig?
        var configError: String?
        do {
            config = try KeybowConfig.parse(Data(json.utf8))
        } catch let error as ConfigError {
            configError = error.description
        } catch {
            configError = "\(error)"
        }
        return OutlineCompilation(json: json, config: config, configError: configError, nodes: compiler.infos,
                                  inferences: compiler.inferences, todo: compiler.todo, warnings: compiler.warnings)
    }
}

// MARK: - The pass

private struct Compiler {
    struct Context {
        var type: String?
        var app: OutlineConverter.AppMatch?
    }

    let document: OutlineDocument
    let locateApp: (String) -> OutlineConverter.AppMatch?
    let listNames: Set<String>

    var infos: [UUID: OutlineNodeInfo] = [:]
    var inferences: [String] = []
    var todo: [String] = []
    var warnings: [String] = []
    /// People and projects the tree refers to, and what each needs.
    var neededContacts: [(name: String, fields: [String])] = []
    var neededProjects: [String] = []
    var reportedApps: Set<String> = []

    init(document: OutlineDocument, locateApp: @escaping (String) -> OutlineConverter.AppMatch?) {
        self.document = document
        self.locateApp = locateApp
        self.listNames = Set(document.lists.map(\.name))
    }

    mutating func run() -> String {
        var trees: [(String, OrderedJSON)] = []
        for kind in TreeKind.allCases {
            let roots = document.roots(kind)
            guard roots.contains(where: { $0 != nil }) else { continue }
            let nodes = roots.enumerated().compactMap { slot, node -> OrderedJSON? in
                guard let node else { return nil }
                return compile(node, slot: slot, path: [slot], tree: kind, list: nil,
                               context: Context(), colour: OutlineCompiler.palette[slot % OutlineCompiler.palette.count])
            }
            trees.append((kind.rawValue, .array(nodes)))
        }

        var lists: [(String, OrderedJSON)] = []
        for list in document.lists {
            let nodes = list.nodes.enumerated().compactMap { slot, node -> OrderedJSON? in
                guard let node else { return nil }
                return compile(node, slot: slot, path: [slot], tree: nil, list: list.name, context: Context(), colour: nil)
            }
            lists.append((list.name, .array(nodes)))
        }

        var output: [(String, OrderedJSON)] = [("version", .number(Double(KeybowConfig.supportedVersion)))]
        if !document.defaults.isEmpty { output.append(("defaults", defaultsJSON())) }
        let contacts = entriesJSON(document.contacts, needed: neededContacts, kind: "contacts")
        if !contacts.isEmpty { output.append(("contacts", .object(contacts))) }
        let projects = entriesJSON(document.projects, needed: neededProjects.map { ($0, ["path"]) }, kind: "projects")
        if !projects.isEmpty { output.append(("projects", .object(projects))) }
        if !lists.isEmpty { output.append(("lists", .object(lists))) }
        output.append(("trees", .object(trees)))
        return OrderedJSON.object(output).render() + "\n"
    }

    // MARK: Nodes

    private mutating func compile(_ node: OutlineNode, slot: Int, path: [Int], tree: TreeKind?, list: String?,
                                  context inherited: Context, colour paletteColour: String?) -> OrderedJSON {
        var context = inherited
        var action: [(String, OrderedJSON)] = []
        var nested: [(String, [(String, OrderedJSON)])] = []
        var params: [(String, OrderedJSON)] = []
        var colour = paletteColour
        var declaredType: String?
        var roles: [AnnotationRole] = []
        var diagnostics: [OutlineDiagnostic] = []
        let where_ = "line \(node.line)"

        func note(_ severity: OutlineDiagnostic.Severity, _ message: String) {
            diagnostics.append(.init(severity, line: node.line, message, node: node.id))
        }
        func set(_ key: String, _ value: OrderedJSON) {
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                if let index = nested.firstIndex(where: { $0.0 == parts[0] }) {
                    nested[index].1.removeAll { $0.0 == parts[1] }
                    nested[index].1.append((parts[1], value))
                } else {
                    nested.append((parts[0], [(parts[1], value)]))
                }
            } else {
                action.removeAll { $0.0 == key }
                action.append((key, value))
            }
        }
        func declare(_ type: String) {
            declaredType = type
            context.type = type
            if type != "app.open" { context.app = nil }
        }

        for annotation in node.annotations {
            let role = OutlineCompiler.role(of: annotation, inheritedType: context.type, inheritedApp: context.app,
                                            listNames: listNames, locateApp: locateApp)
            roles.append(role)
            switch (annotation, role) {
            case (_, .listReference(let exists)):
                if !exists, case .word(let word) = annotation {
                    note(.error, "There's no list called “\(word.dropFirst())”.")
                }
            case (_, .alert(let minutes)):
                set("alertMinutes", .number(Double(minutes)))
            case (.word(let word), .template):
                set("template", .string(word))
                let lower = word.lowercased()
                // A template named Append… or New… says which it means.
                if declaredType == nil, lower.hasPrefix("append") {
                    declare("notes.append")
                    inferences.append("\(where_): “\(node.label)” appends to a note, from the template name \(word)")
                } else if declaredType == nil, lower.hasPrefix("new") {
                    declare("notes.create")
                    inferences.append("\(where_): “\(node.label)” creates a new note, from the template name \(word)")
                }
            case (_, .noteMode(let type)), (_, .actionType(let type)):
                declare(type)
                // FaceTime is a call type of its own; Call means the iPhone.
                if case .word(let word) = annotation, word.lowercased() == "facetime" { set("via", .string("facetime")) }
            case (.word(let word), .app(let name, let installed)):
                declare("app.open")
                let match = locateApp(word) ?? OutlineConverter.AppMatch(name: name, installed: false, isService: false)
                context.app = match
                set("app", .string(match.name))
                if let bundle = match.bundleIdentifier { set("bundleId", .string(bundle)) }
                if !installed {
                    let message = locateApp(word) == nil
                        ? "Assuming “\(word)” is an app, but it isn't installed."
                        : "\(match.name) isn't installed."
                    note(.warning, message)
                    warnings.append("\(where_): \(message)")
                } else if Self.normalised(word) != Self.normalised(match.name), !reportedApps.contains(word) {
                    reportedApps.insert(word)
                    inferences.append("“\(word)” opens \(match.name), the one installed here")
                }
            case (.word(let word), .target):
                set("target", .string(word))
            case (.word(let word), .link):
                set("url", .string(word))
            case (.word(let word), .unknown):
                params.append(("note", .string(word)))
                note(.warning, "Didn't understand “\(word)”; kept as a note.")
                warnings.append("\(where_): didn't understand “\(word)” on “\(node.label)”")
            case (.pair(_, let value), .colour(let valid)):
                if valid { colour = value } else { note(.error, "“\(value)” isn't a colour; use rrggbb.") }
            case (.pair(let key, let value), .field):
                if key == "type" {
                    declare(value)
                } else if OutlineCompiler.isNumericField(key), let number = Double(value) {
                    set(key, .number(number))
                } else if OutlineCompiler.isBooleanField(key) {
                    set(key, .bool(["true", "yes", "on", "1"].contains(value.lowercased())))
                } else {
                    set(key, .string(value))
                    if key == "app", let app = locateApp(value) {
                        context.app = app
                        if let bundle = app.bundleIdentifier { set("bundleId", .string(bundle)) }
                    }
                }
            case (.pair(let key, let value), .parameter):
                params.removeAll { $0.0 == key }
                params.append((key, .string(value)))
            default:
                break
            }
        }
        // A link with nothing else to open it: open it in the browser.
        if context.type == nil, action.contains(where: { $0.0 == "url" }) { declare("url.open") }
        for (name, fields) in nested { set(name, .object(fields)) }
        if let declaredType { action.removeAll { $0.0 == "type" }; action.insert(("type", .string(declaredType)), at: 0) }

        let listReference = node.listReference
        if listReference != nil && node.hasChildren {
            note(.error, "Takes its children from @\(listReference!) and has its own; one or the other.")
        }

        // What a leaf means, given what it inherits.
        if node.isLeaf {
            leafValues(node, context: context, declaredHere: declaredType != nil, action: action, params: &params,
                       inList: list != nil, note: note)
        }

        var fields: [(String, OrderedJSON)] = [("label", .string(node.label)), ("key", .number(Double(slot)))]
        if let colour { fields.append(("colour", .string(colour))) }
        if !params.isEmpty { fields.append(("params", .object(params))) }
        if !action.isEmpty { fields.append(("action", .object(action))) }
        if let listReference {
            fields.append(("children", .string("@" + listReference)))
        } else if node.hasChildren {
            let children = node.children.enumerated().compactMap { childSlot, child -> OrderedJSON? in
                guard let child else { return nil }
                return compile(child, slot: childSlot, path: path + [childSlot], tree: tree, list: list,
                               context: context, colour: nil)
            }
            fields.append(("children", .array(children)))
        }

        infos[node.id] = OutlineNodeInfo(tree: tree, listName: list, path: path, roles: roles,
                                         diagnostics: diagnostics, actionType: context.type)
        return .object(fields)
    }

    private mutating func leafValues(_ node: OutlineNode, context: Context, declaredHere: Bool,
                                     action: [(String, OrderedJSON)], params: inout [(String, OrderedJSON)],
                                     inList: Bool,
                                     note: (OutlineDiagnostic.Severity, String) -> Void) {
        let paramKeys = Set(params.map(\.0))
        func has(_ key: String) -> Bool { action.contains { $0.0 == key } || paramKeys.contains(key) }
        let where_ = "line \(node.line)"

        // A date-like label in a list: likely a `when`, whatever uses the list.
        if inList, !has("when"), DateExpression.resolve(node.label.lowercased(), now: Date()) != nil {
            params.append(("when", .string(node.label.lowercased())))
            return
        }

        switch context.type {
        case "calendar.createEvent":
            guard !has("when"), !has("start") else { return }
            let phrase = node.label.lowercased()
            if DateExpression.resolve(phrase, now: Date()) != nil {
                params.append(("when", .string(phrase)))
            } else {
                note(.warning, "An event with no date: add “when: …” or “start: …”.")
                todo.append("\(where_): “\(node.label)” is an event with no date; add when: or start:")
            }
        case "messages.compose", "phone.call":
            if !has("to"), !has("contact") { addContact(node.label, field: "phone") }
        case "mail.compose":
            if !has("to"), !has("contact") { addContact(node.label, field: "email") }
        case "app.open":
            guard let app = context.app else { return }
            if has("open") || has("url") || has("project") { return }
            let justTheApp = declaredHere && (Self.normalised(node.label) == Self.normalised(app.name)
                || node.annotations.contains { if case .word(let w) = $0 { return Self.normalised(w) == Self.normalised(node.label) }; return false })
            if justTheApp { return }
            if app.isService {
                let message = has("target")
                    ? "Needs a URL for \(app.name) to open this; add “open: …”."
                    : "Needs a URL for \(app.name) to open; add “open: …”."
                note(.note, message)
                todo.append("\(where_): “\(node.label)” — \(message)")
            } else if !neededProjects.contains(node.label) {
                neededProjects.append(node.label)
            }
        default:
            break
        }
    }

    private mutating func addContact(_ name: String, field: String) {
        if let index = neededContacts.firstIndex(where: { $0.name == name }) {
            if !neededContacts[index].fields.contains(field) { neededContacts[index].fields.append(field) }
        } else {
            neededContacts.append((name, [field]))
        }
    }

    static func normalised(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "")
    }

    // MARK: Sections

    /// Contacts or projects: every entry written in the outline, plus an empty
    /// one for anyone the tree mentions who isn't there yet.
    private mutating func entriesJSON(_ entries: [OutlineEntry], needed: [(name: String, fields: [String])],
                                      kind: String) -> [(String, OrderedJSON)] {
        var result: [(String, OrderedJSON)] = []
        var written = Set<String>()
        for entry in entries {
            written.insert(entry.name)
            var fields: [(String, OrderedJSON)] = entry.fields.compactMap {
                guard case .pair(let key, let value) = $0 else { return nil }
                return (key, .string(value))
            }
            let wanted = needed.first { $0.name == entry.name }?.fields ?? []
            for field in wanted where !fields.contains(where: { $0.0 == field }) {
                fields.append((field, .string("")))
            }
            let blank = fields.filter { $0.1.isEmptyString }.map(\.0)
            if !blank.isEmpty { todo.append("\(kind): “\(entry.name)” needs \(blank.joined(separator: " and "))") }
            result.append((entry.name, .object(fields)))
        }
        for (name, fields) in needed where !written.contains(name) {
            result.append((name, .object(fields.map { ($0, .string("")) })))
            todo.append("\(kind): “\(name)” needs \(fields.joined(separator: " and ")) — add it under # \(kind)")
        }
        return result
    }

    /// `dates.defaultTime: 09:00` → { "dates": { "defaultTime": "09:00" } }.
    /// `types.calendar.createEvent.duration: 1h` → the type's name keeps its dot.
    private func defaultsJSON() -> OrderedJSON {
        var top: [(String, OrderedJSON)] = []
        var groups: [(String, [(String, OrderedJSON)])] = []
        var types: [(String, [(String, OrderedJSON)])] = []

        func add(_ value: OrderedJSON, key: String, to list: inout [(String, [(String, OrderedJSON)])], group: String) {
            if let index = list.firstIndex(where: { $0.0 == group }) {
                list[index].1.append((key, value))
            } else {
                list.append((group, [(key, value)]))
            }
        }

        for case .pair(let key, let value) in document.defaults {
            let typed: OrderedJSON = OutlineCompiler.numericDefaults.contains(key)
                ? (Double(value).map(OrderedJSON.number) ?? .string(value)) : .string(value)
            if key.hasPrefix("types.") {
                let rest = key.dropFirst("types.".count)
                guard let lastDot = rest.lastIndex(of: ".") else { continue }
                add(typed, key: String(rest[rest.index(after: lastDot)...]), to: &types, group: String(rest[..<lastDot]))
                continue
            }
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                add(typed, key: parts[1], to: &groups, group: parts[0])
            } else {
                top.append((key, typed))
            }
        }
        var result = top + groups.map { ($0.0, OrderedJSON.object($0.1)) }
        if !types.isEmpty { result.append(("types", .object(types.map { ($0.0, .object($0.1)) }))) }
        return .object(result)
    }
}

extension OrderedJSON {
    var isEmptyString: Bool {
        if case .string(let text) = self { return text.isEmpty }
        return false
    }
}
