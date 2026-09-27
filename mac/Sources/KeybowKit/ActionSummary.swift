import Foundation

/// A human-readable account of what a selection's action will do, with the
/// template values filled in: "New event · Meeting · Sat 26 Sep, 14:40".
///
/// Used by the overlay and the CLI before actions exist, and later to confirm
/// what is about to happen during the commit window.
public struct ActionSummary: Equatable, Sendable {
    public let type: String
    /// "New note", "New event", "Open"…
    public let verb: String
    /// The thing itself: the note's title, the event, the app.
    public let subject: String
    public let details: [String]
    /// Values the action needs that the config does not supply yet.
    public let missing: [String]

    /// `environment` holds values fetched when the key was pressed — the
    /// selected text, the clipboard. Without them, stand-ins show where they'll go.
    public init(selection: ResolvedSelection, config: KeybowConfig, now: Date = Date(),
                calendar: Calendar = .current, environment: [String: String] = [:]) {
        let action = selection.action ?? ActionSpec(type: "none", fields: [:])
        var missing: [String] = []
        let params = Self.standIns.merging(environment) { _, fetched in fetched }
            .merging(selection.params) { _, fromTree in fromTree }

        func expand(_ text: String?) -> String {
            guard let text else { return "" }
            let result = Template.expand(text, params: params, now: now, calendar: calendar)
            for name in result.missing where !missing.contains(name) { missing.append(name) }
            return result.text
        }
        func field(_ key: String) -> String { expand(action.string(key)) }
        func nested(_ key: String, _ inner: String) -> String {
            guard case .object(let object)? = action.fields[key] else { return "" }
            return expand(object[inner]?.stringValue)
        }
        func when(_ key: String) -> String? {
            let phrase = field(key)
            guard !phrase.isEmpty else { return nil }
            guard let date = DateExpression.resolve(phrase, now: now, rules: config.dateRules, calendar: calendar) else {
                return "\"\(phrase)\" (not a date I understand)"
            }
            return Self.dateFormatter(calendar).string(from: date)
        }

        var verb = action.type
        var subject = selection.labels.last ?? ""
        var details: [String] = []

        switch action.type {
        case "notes.create":
            verb = "New note"
            subject = field("title")
            let folder = field("folder")
            if !folder.isEmpty { details.append("in \(folder)") }
            if let template = action.string("template") { details.append("from \(template)") }
        case "notes.append":
            verb = "Add to note"
            subject = nested("find", "byName")
            let folder = field("folder")
            if !folder.isEmpty { details.append("in \(folder)") }
            if let template = action.string("template") { details.append("from \(template)") }
        case "calendar.createEvent":
            verb = "New event"
            subject = field("title")
            if let start = when("start") { details.append(start) }
            if case .number(let minutes)? = action.fields["alertMinutes"] {
                details.append("alert \(Int(minutes)) min before")
            }
        case "reminders.create":
            verb = "New reminder"
            subject = field("title")
            if let due = when("due") { details.append("due \(due)") }
            let list = field("list")
            if !list.isEmpty { details.append("in \(list)") }
        case "messages.compose":
            verb = "Message"
            subject = selection.params["contact.name"] ?? selection.labels.last ?? ""
            let to = field("to")
            if !to.isEmpty { details.append(to) }
            let body = field("body")
            if !body.isEmpty { details.append("\u{201C}\(body)\u{201D}") }
        case "phone.call":
            verb = field("via").lowercased() == "facetime" ? "FaceTime" : "Call"
            subject = selection.params["contact.name"] ?? selection.labels.last ?? ""
            let to = field("to")
            if !to.isEmpty { details.append(to) }
        case "mail.compose":
            verb = "Email"
            subject = selection.params["contact.name"] ?? selection.labels.last ?? ""
            let to = field("to")
            if !to.isEmpty { details.append(to) }
        case "app.open":
            verb = "Open"
            subject = field("app")
            let target = field("target")
            let open = field("open")
            if !open.isEmpty { details.append(open) }
            if !target.isEmpty { details.append("→ \(target)") }
            if open.isEmpty && target.isEmpty && subject != selection.labels.last {
                details.append(selection.labels.last ?? "")
            }
        case "shortcut":
            verb = "Run shortcut"
            subject = field("name")
        case "url.open":
            verb = "Open link"
            let url = field("url")
            if !url.isEmpty && url != subject { details.append(url) }
        case "clock.timer":
            verb = "Start timer"
            var phrase = field("duration")
            if phrase.isEmpty { phrase = field("due") }
            if phrase.isEmpty { phrase = selection.labels.last ?? "" }
            if let seconds = DateExpression.timerLength(phrase, now: now, rules: config.dateRules, calendar: calendar) {
                subject = DateExpression.describe(seconds: seconds)
                details.append(seconds > 24 * 3600 ? "too long: Clock's timers stop at 24 hours" : "in Clock")
            } else {
                details.append("“\(phrase)” isn't a length of time")
            }
        case "maps.search":
            verb = "Search Maps"
            let query = field("query")
            subject = query.isEmpty ? (selection.labels.last ?? "") : query
        case "music.play":
            verb = "Play"
            let album = field("album")
            if !album.isEmpty {
                subject = album
                let artist = field("artist")
                details.append(artist.isEmpty ? "album" : "album by \(artist)")
            } else {
                let playlist = field("playlist")
                subject = playlist.isEmpty ? (selection.labels.last ?? "") : playlist
                details.append("playlist")
                if case .bool(let shuffle)? = action.fields["shuffle"] { details.append(shuffle ? "shuffled" : "in order") }
            }
        case "clipboard.copy":
            verb = "Copy"
            if let template = action.string("template") {
                details.append("from \(template)")
            } else if action.string("text") != nil {
                let text = field("text").replacingOccurrences(of: "\n", with: " ⏎ ")
                details.append("\u{201C}\(text.count > 60 ? String(text.prefix(60)) + "…" : text)\u{201D}")
            }
        default:
            break
        }

        self.type = action.type
        self.verb = verb
        self.subject = subject.isEmpty ? (selection.labels.last ?? "") : subject
        self.details = details
        self.missing = missing
    }

    private static let standIns = [
        "selection": "‹selected text›", "clipboard": "‹clipboard›", "frontApp": "‹front app›",
    ]

    private static func dateFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE d MMM, HH:mm"
        return formatter
    }
}
