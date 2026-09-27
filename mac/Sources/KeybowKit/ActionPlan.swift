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
    /// A call through the paired iPhone, or FaceTime audio. macOS asks first.
    case placeCall(to: String, faceTime: Bool)
    case composeMail(to: String, subject: String, body: String)
    /// `open` is a file path (already expanded) or a URL; empty just launches the app.
    case openApp(name: String, bundleID: String, open: String)
    case runShortcut(name: String, input: String)
    /// A web link in the default browser, any other link in the app that
    /// handles it, or a file in its default app.
    case openLink(URL)
    case copyToClipboard(String)
    /// A timer in Clock, started by a helper shortcut: Clock can't be
    /// scripted, but Shortcuts' Start Timer action reaches it.
    case startTimer(seconds: Int, shortcut: String)
    case searchMaps(String)
    /// Nil leaves Music's shuffle setting as it is.
    case playPlaylist(String, shuffle: Bool?)
    /// An album from the library, in disc and track order; `artist` narrows
    /// it down when two albums share a name.
    case playAlbum(String, artist: String)
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
    /// `{{selection}}` was needed but nothing was selected in the named app.
    case nothingSelected(app: String, for: String)
    case notALink(String)
    case notALength(String)
    case timerTooLong(String)

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
        case .nothingSelected(let app, let field):
            return "Nothing is selected\(app.isEmpty ? "" : " in \(app)"), and the \(field) needs it."
        case .notALength(let text):
            return "“\(text)” isn't a length of time or a time of day."
        case .timerTooLong(let text):
            return "“\(text)” is more than 24 hours away; Clock's timers stop at 24 hours."
        case .notALink(let text):
            return "“\(text.count > 60 ? String(text.prefix(60)) + "…" : text)” isn't a link."
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
    /// Used when an action names no calendar or list: identifiers chosen in
    /// the settings window. Empty means the system's own defaults.
    public var defaultCalendarID: String
    public var defaultReminderListID: String

    public init(templatesDirectory: URL?, now: Date = Date(), calendar: Calendar = .current,
                environment: [String: String] = [:], defaultCalendarID: String = "",
                defaultReminderListID: String = "") {
        self.templatesDirectory = templatesDirectory
        self.now = now
        self.calendar = calendar
        self.environment = environment
        self.defaultCalendarID = defaultCalendarID
        self.defaultReminderListID = defaultReminderListID
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

    /// The shortcut that starts a Clock timer, unless an action names another.
    public static let timerShortcut = "KeybowNotes Timer"

    /// Every placeholder the selection's action could use — in its fields and
    /// its template file — so values that are costly to fetch, like the
    /// selected text, are fetched only when something asks for them.
    public static func placeholders(for selection: ResolvedSelection, context: ActionContext) -> Set<String> {
        guard let action = selection.action else { return [] }
        var names = Set<String>()
        func collect(_ value: JSONValue) {
            switch value {
            case .string(let text): names.formUnion(Template.names(in: text))
            case .array(let items): items.forEach(collect)
            case .object(let fields): fields.values.forEach(collect)
            default: break
            }
        }
        action.fields.values.forEach(collect)
        if let name = action.string("template"), !name.isEmpty,
           let url = Planner.templateURL(name, in: context.templatesDirectory),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            names.formUnion(Template.names(in: text))
        }
        return names
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
            // A template that opens with a "#" heading names the note: its author
            // wrote that heading to be the title. Otherwise the action's title,
            // then the leaf's label.
            let (templateTitle, templateBody) = try templateParts()
            var title = templateTitle ?? ""
            if title.isEmpty { title = optional("title") }
            if title.isEmpty { title = selection.labels.last ?? "" }
            guard !title.isEmpty else { throw ActionPlanError.empty("note title") }
            return .createNote(location, title: title, html: NotesHTML.title(title) + NotesHTML.from(markdown: templateBody))

        case "notes.append":
            let location = noteLocation()
            let name = try required(nested("find", "byName"), for: "note to add to")
            var entry = try templateText()
            if entry == nil { entry = optional("entry") }
            // With no entry text given: a note named after the leaf (a character,
            // a project) needs only the time, while a note shared by many leaves
            // (monthly check-ins) needs the path to say which one was chosen.
            let standard = name == selection.labels.last ? "**{{datetime}}**" : "**{{datetime}}** — {{path}}"
            let markdown = entry?.isEmpty == false ? entry! : standard
            let entryHTML = "<div><br></div>" + NotesHTML.from(markdown: expanded(markdown))
            return .appendToNote(location, name: name, entryHTML: entryHTML, titleHTML: NotesHTML.title(name),
                                 createIfMissing: boolField("createIfMissing", default: true), guards: guards())

        case "reminders.create":
            let title = try required(action.string("title"), for: "reminder title")
            let due = try date(optional("due"))
            var list = optional("list")
            if list.isEmpty { list = context.defaultReminderListID }
            return .createReminder(title: title, notes: optional("notes"), due: due, list: list)

        case "calendar.createEvent":
            let title = try required(action.string("title"), for: "event title")
            let phrase = try required(action.string("start"), for: "event's date")
            guard let start = try date(phrase) else { throw ActionPlanError.empty("event's date") }
            let duration = DateExpression.duration(optional("duration")) ?? 30 * 60
            var alert: Int?
            if case .number(let minutes)? = action.fields["alertMinutes"] { alert = Int(minutes) }
            var calendarID = optional("calendarId")
            let calendarName = optional("calendar")
            if calendarID.isEmpty && calendarName.isEmpty { calendarID = context.defaultCalendarID }
            return .createEvent(title: title, start: start, duration: duration, alertMinutes: alert,
                                calendarID: calendarID, calendarName: calendarName,
                                notes: optional("notes"), show: boolField("show", default: true))

        case "messages.compose":
            let to = try required(action.string("to"), for: "message recipient")
            return .composeMessage(to: to, body: try templateText() ?? optional("body"))

        case "mail.compose":
            let to = optional("to")
            if to.isEmpty { warnings.append("No address for \(selection.labels.last ?? "the recipient"); the draft has no recipient.") }
            return .composeMail(to: to, subject: optional("subject"), body: try templateText() ?? optional("body"))

        case "phone.call":
            let to = try required(action.string("to"), for: "number to call")
            return .placeCall(to: to, faceTime: optional("via").lowercased() == "facetime")

        case "app.open":
            let name = optional("app")
            let bundleID = optional("bundleId")
            guard !name.isEmpty || !bundleID.isEmpty else { throw ActionPlanError.empty("app to open") }
            var open = optional("open", encode: linkEncoding(for: action.string("open")))
            if open.isEmpty { open = optional("url", encode: linkEncoding(for: action.string("url"))) }
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

        case "url.open":
            let text = try required(action.string("url"), for: "link", encode: linkEncoding(for: action.string("url")))
            return .openLink(try link(text))

        case "clock.timer":
            // The same phrases as a reminder's due: a length, or a time to run until.
            // A reminder branch keeps working when it switches to Timer.
            var phrase = optional("duration")
            if phrase.isEmpty { phrase = optional("due") }
            if phrase.isEmpty { phrase = selection.labels.last ?? "" }
            guard let seconds = DateExpression.timerLength(phrase, now: context.now, rules: config.dateRules,
                                                           calendar: context.calendar) else {
                throw ActionPlanError.notALength(phrase)
            }
            guard seconds <= 24 * 3600 else { throw ActionPlanError.timerTooLong(phrase) }
            var shortcut = optional("shortcut")
            if shortcut.isEmpty { shortcut = ActionPlanner.timerShortcut }
            return .startTimer(seconds: Int(seconds.rounded()), shortcut: shortcut)

        case "maps.search":
            var query = action.string("query") ?? "{{leaf}}"
            if query.isEmpty { query = "{{leaf}}" }
            return .searchMaps(try required(query, for: "place to search for"))

        case "music.play":
            let album = optional("album")
            if !album.isEmpty { return .playAlbum(album, artist: optional("artist")) }
            var playlist = optional("playlist")
            if playlist.isEmpty { playlist = selection.labels.last ?? "" }
            guard !playlist.isEmpty else { throw ActionPlanError.empty("playlist") }
            var shuffle: Bool?
            if case .bool(let value)? = action.fields["shuffle"] { shuffle = value }
            return .playPlaylist(playlist, shuffle: shuffle)

        case "clipboard.copy":
            // A template, then the text field, then the label itself: a list of
            // snippets can be copied by name alone.
            if let text = try templateText() { return .copyToClipboard(text) }
            if let text = action.string("text") {
                let result = expand(text)
                if !result.missing.isEmpty { throw missingError(result.missing, for: "text to copy") }
                guard !result.text.isEmpty else { throw ActionPlanError.empty("text to copy") }
                return .copyToClipboard(result.text)
            }
            return .copyToClipboard(selection.labels.last ?? "")

        default:
            throw ActionPlanError.unsupported(action.type)
        }
    }

    // MARK: - Values

    private func expand(_ text: String, encode: ((String) -> String)? = nil) -> Template.Result {
        let params = context.environment.merging(selection.params) { _, fromTree in fromTree }
        return Template.expand(text, params: params, now: context.now, calendar: context.calendar, encode: encode)
    }

    private mutating func expanded(_ text: String, encode: ((String) -> String)? = nil) -> String {
        let result = expand(text, encode: encode)
        var missing = result.missing
        if missing.contains("selection") {
            missing.removeAll { $0 == "selection" }
            warnings.append("Nothing was selected\(frontApp.isEmpty ? "" : " in \(frontApp)"), so {{selection}} was left empty.")
        }
        if !missing.isEmpty {
            warnings.append("No value for \(missing.joined(separator: ", ")).")
        }
        return result.text
    }

    /// An optional field: missing placeholders become a warning, not a failure.
    private mutating func optional(_ key: String, encode: ((String) -> String)? = nil) -> String {
        guard let text = action.string(key) else { return "" }
        return expanded(text, encode: encode).trimmingCharacters(in: .whitespaces)
    }

    /// A field the action cannot do without.
    private func required(_ text: String?, for purpose: String, encode: ((String) -> String)? = nil) throws -> String {
        guard let text else { throw ActionPlanError.empty(purpose) }
        let result = expand(text, encode: encode)
        if !result.missing.isEmpty { throw missingError(result.missing, for: purpose) }
        let value = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ActionPlanError.empty(purpose) }
        return value
    }

    private var frontApp: String { context.environment["frontApp"] ?? "" }

    private func missingError(_ names: [String], for purpose: String) -> ActionPlanError {
        names.contains("selection") ? .nothingSelected(app: frontApp, for: purpose) : .missing(names, for: purpose)
    }

    // MARK: - Links

    /// Values placed inside a link are percent-encoded, so a selected phrase
    /// with spaces or an & becomes one search term. Not when the field is a
    /// single placeholder — `{{selection}}` is then the link itself — and not
    /// for a path, or anything that doesn't start with a scheme like https:.
    private func linkEncoding(for text: String?) -> ((String) -> String)? {
        guard let text = text?.trimmingCharacters(in: .whitespaces),
              !Template.isSinglePlaceholder(text), Self.hasScheme(text) else { return nil }
        return Template.linkEncoded
    }

    /// `https:`, `mailto:`, `things:` — a scheme written at the start.
    static func hasScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":"), let first = text.first, first.isASCII, first.isLetter else { return false }
        return text[..<colon].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }
    }

    /// A link, a path, or a bare address like "example.com/page".
    private func link(_ text: String) throws -> URL {
        if text.hasPrefix("/") || text.hasPrefix("~") {
            return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        }
        if Self.hasScheme(text), !text.contains(where: \.isWhitespace), let url = URL(string: text) {
            return url
        }
        // Selected text like "apple.com/mac": a web address without its https.
        let bare = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        if !text.contains(where: \.isWhitespace), bare.contains("."), !bare.hasPrefix("."), !bare.hasSuffix("."),
           let url = URL(string: "https://" + text) {
            return url
        }
        throw ActionPlanError.notALink(text)
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

        guard let url = Self.templateURL(name, in: context.templatesDirectory) else {
            throw ActionPlanError.templateNotFound(name)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ActionPlanError.templateNotFound(url.path)
        }
        return expanded(text)
    }

    /// Relative names are found in the templates folder; nil without one.
    static func templateURL(_ name: String, in directory: URL?) -> URL? {
        if name.hasPrefix("/") || name.hasPrefix("~") {
            return URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
        }
        return directory?.appendingPathComponent(name)
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
