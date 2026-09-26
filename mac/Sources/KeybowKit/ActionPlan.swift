import Foundation

/// Where Notes should put something: an account (empty for the default) and a
/// folder path, outermost first (empty for the account's default folder).
public struct NoteLocation: Equatable, Sendable {
    public let account: String
    public let folders: [String]

    public var description: String {
        folders.isEmpty ? "the default folder" : folders.joined(separator: "/")
    }
}

public struct AppendGuards: Equatable, Sendable {
    /// Refuse to rewrite a note whose HTML body is longer than this. Appending
    /// round-trips the whole body; see spikes/FINDINGS.md.
    public let maxCharacters: Int
    /// Refuse notes with inline images, which appending turns into attachments.
    public let refuseInlineImages: Bool

    public static let standard = AppendGuards(maxCharacters: 262_144, refuseInlineImages: true)
}

/// Exactly what to do, with every value decided. Planning is pure and tested;
/// `ActionRunner` carries a plan out.
public enum ActionPlan: Equatable, Sendable {
    case createNote(NoteLocation, title: String, html: String)
    /// `titleHTML` starts the note when it has to be created first.
    case appendToNote(NoteLocation, name: String, entryHTML: String, titleHTML: String,
                      createIfMissing: Bool, guards: AppendGuards)
    case createReminder(title: String, notes: String, due: Date?, list: String)
    case createEvent(title: String, start: Date, duration: TimeInterval, alertMinutes: Int?,
                     calendarID: String, calendarName: String, notes: String, show: Bool)
    case composeMessage(to: String, body: String)
    case composeMail(to: String, subject: String, body: String)
    /// `open` is a file path (already expanded) or a URL; empty just launches the app.
    case openApp(name: String, bundleID: String, open: String)
    case runShortcut(name: String, input: String)
}

public struct PlannedAction: Equatable, Sendable {
    public let plan: ActionPlan
    /// Things that were not needed but look wrong: a missing optional value.
    public let warnings: [String]
}

public enum ActionPlanError: Error, Equatable, CustomStringConvertible {
    /// Placeholders with no value, for a field the action cannot do without.
    case missing([String], for: String)
    case empty(String)
    case unreadableDate(String)
    case templateNotFound(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .missing(let names, let field):
            return "The config has no value for \(names.joined(separator: ", ")), needed for the \(field)."
        case .empty(let field):
            return "The \(field) came out empty."
        case .unreadableDate(let phrase):
            return "\"\(phrase)\" isn't a date I understand."
        case .templateNotFound(let path):
            return "No template at \(path)."
        case .unsupported(let type):
            return "\"\(type)\" isn't an action I know how to run."
        }
    }
}

public struct ActionContext: Sendable {
    /// Relative template names are looked up here — normally "templates" next
    /// to the config file.
    public var templatesDirectory: URL?
    public var now: Date
    public var calendar: Calendar
    /// Values from outside the tree — the clipboard, the frontmost app. The
    /// lowest precedence: anything the tree defines under the same name wins.
    public var environment: [String: String]

    public init(templatesDirectory: URL?, now: Date = Date(), calendar: Calendar = .current,
                environment: [String: String] = [:]) {
        self.templatesDirectory = templatesDirectory
        self.now = now
        self.calendar = calendar
        self.environment = environment
    }
}

public enum ActionPlanner {
    public static func plan(_ selection: ResolvedSelection, config: KeybowConfig,
                            context: ActionContext) throws -> PlannedAction {
        guard let action = selection.action else { throw ActionPlanError.unsupported("(no action)") }
        var planner = Planner(action: action, selection: selection, config: config, context: context)
        let plan = try planner.make()
        return PlannedAction(plan: plan, warnings: planner.warnings)
    }
}

private struct Planner {
    let action: ActionSpec
    let selection: ResolvedSelection
    let config: KeybowConfig
    let context: ActionContext
    var warnings: [String] = []

    init(action: ActionSpec, selection: ResolvedSelection, config: KeybowConfig, context: ActionContext) {
        self.action = action
        self.selection = selection
        self.config = config
        self.context = context
    }

    mutating func make() throws -> ActionPlan {
        switch action.type {
        case "notes.create":
            let location = noteLocation()
            let (templateTitle, templateBody) = try templateParts()
            var title = optional("title")
            if title.isEmpty { title = templateTitle ?? "" }
            if title.isEmpty { title = selection.labels.last ?? "" }
            guard !title.isEmpty else { throw ActionPlanError.empty("note title") }
            return .createNote(location, title: title, html: NotesHTML.title(title) + NotesHTML.from(markdown: templateBody))

        case "notes.append":
            let location = noteLocation()
            let name = try required(nested("find", "byName"), for: "note to add to")
            var entry = try templateText()
            if entry == nil { entry = optional("entry") }
            let markdown = entry?.isEmpty == false ? entry! : "**{{datetime}}** — {{path}}"
            let entryHTML = "<div><br></div>" + NotesHTML.from(markdown: expanded(markdown))
            return .appendToNote(location, name: name, entryHTML: entryHTML, titleHTML: NotesHTML.title(name),
                                 createIfMissing: boolField("createIfMissing", default: true), guards: guards())

        case "reminders.create":
            let title = try required(action.string("title"), for: "reminder title")
            let due = try date(optional("due"))
            return .createReminder(title: title, notes: optional("notes"), due: due, list: optional("list"))

        case "calendar.createEvent":
            let title = try required(action.string("title"), for: "event title")
            let phrase = try required(action.string("start"), for: "event's date")
            guard let start = try date(phrase) else { throw ActionPlanError.empty("event's date") }
            let duration = DateExpression.duration(optional("duration")) ?? 30 * 60
            var alert: Int?
            if case .number(let minutes)? = action.fields["alertMinutes"] { alert = Int(minutes) }
            return .createEvent(title: title, start: start, duration: duration, alertMinutes: alert,
                                calendarID: optional("calendarId"), calendarName: optional("calendar"),
                                notes: optional("notes"), show: boolField("show", default: true))

        case "messages.compose":
            let to = try required(action.string("to"), for: "message recipient")
            return .composeMessage(to: to, body: optional("body"))

        case "mail.compose":
            let to = optional("to")
            if to.isEmpty { warnings.append("No address for \(selection.labels.last ?? "the recipient"); the draft has no recipient.") }
            return .composeMail(to: to, subject: optional("subject"), body: optional("body"))

        case "app.open":
            let name = optional("app")
            let bundleID = optional("bundleId")
            guard !name.isEmpty || !bundleID.isEmpty else { throw ActionPlanError.empty("app to open") }
            var open = optional("open")
            if open.isEmpty { open = optional("url") }
            let target = optional("target")
            if open.isEmpty && !target.isEmpty {
                warnings.append("No URL for \"\(target)\" yet, so just opening \(name.isEmpty ? "the app" : name).")
            }
            if !open.isEmpty && !open.contains("://") {
                open = (open as NSString).expandingTildeInPath
            }
            return .openApp(name: name, bundleID: bundleID, open: open)

        case "shortcut":
            let name = try required(action.string("name"), for: "shortcut name")
            return .runShortcut(name: name, input: optional("input"))

        default:
            throw ActionPlanError.unsupported(action.type)
        }
    }

    // MARK: - Values

    private func expand(_ text: String) -> Template.Result {
        let params = context.environment.merging(selection.params) { _, fromTree in fromTree }
        return Template.expand(text, params: params, now: context.now, calendar: context.calendar)
    }

    private mutating func expanded(_ text: String) -> String {
        let result = expand(text)
        if !result.missing.isEmpty {
            warnings.append("No value for \(result.missing.joined(separator: ", ")).")
        }
        return result.text
    }

    /// An optional field: missing placeholders become a warning, not a failure.
    private mutating func optional(_ key: String) -> String {
        guard let text = action.string(key) else { return "" }
        return expanded(text).trimmingCharacters(in: .whitespaces)
    }

    /// A field the action cannot do without.
    private func required(_ text: String?, for purpose: String) throws -> String {
        guard let text else { throw ActionPlanError.empty(purpose) }
        let result = expand(text)
        if !result.missing.isEmpty { throw ActionPlanError.missing(result.missing, for: purpose) }
        let value = result.text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { throw ActionPlanError.empty(purpose) }
        return value
    }

    private func nested(_ key: String, _ inner: String) -> String? {
        guard case .object(let object)? = action.fields[key] else { return nil }
        return object[inner]?.stringValue
    }

    private func boolField(_ key: String, default fallback: Bool) -> Bool {
        if case .bool(let value)? = action.fields[key] { return value }
        return fallback
    }

    private func date(_ phrase: String) throws -> Date? {
        guard !phrase.isEmpty else { return nil }
        guard let date = DateExpression.resolve(phrase, now: context.now, rules: config.dateRules,
                                                calendar: context.calendar) else {
            throw ActionPlanError.unreadableDate(phrase)
        }
        return date
    }

    private mutating func noteLocation() -> NoteLocation {
        var account = optional("account")
        if account.isEmpty, case .object(let notes)? = config.defaults["notes"] {
            account = notes["account"]?.stringValue ?? ""
        }
        let folders = optional("folder")
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return NoteLocation(account: account, folders: folders)
    }

    private func guards() -> AppendGuards {
        guard case .object(let object)? = action.fields["guards"] else { return .standard }
        var maxCharacters = AppendGuards.standard.maxCharacters
        var refuseImages = AppendGuards.standard.refuseInlineImages
        if case .number(let value)? = object["maxBodyBytes"] { maxCharacters = Int(value) }
        if case .bool(let value)? = object["refuseInlineImages"] { refuseImages = value }
        return AppendGuards(maxCharacters: maxCharacters, refuseInlineImages: refuseImages)
    }

    // MARK: - Templates

    /// The template, expanded, or nil when the action names none.
    private mutating func templateText() throws -> String? {
        let name = action.string("template") ?? ""
        guard !name.isEmpty else { return nil }

        let url: URL
        if name.hasPrefix("/") || name.hasPrefix("~") {
            url = URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
        } else if let directory = context.templatesDirectory {
            url = directory.appendingPathComponent(name)
        } else {
            throw ActionPlanError.templateNotFound(name)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ActionPlanError.templateNotFound(url.path)
        }
        return expanded(text)
    }

    /// Splits a template into a title — its first line, if a heading — and the rest.
    private mutating func templateParts() throws -> (String?, String) {
        guard let text = try templateText() else { return (nil, "") }
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.first, first.hasPrefix("# ") else { return (nil, text) }
        return (String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces),
                lines.dropFirst().joined(separator: "\n"))
    }
}
