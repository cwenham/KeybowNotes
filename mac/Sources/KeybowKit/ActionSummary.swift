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

    public init(selection: ResolvedSelection, config: KeybowConfig, now: Date = Date(),
                calendar: Calendar = .current) {
        let action = selection.action ?? ActionSpec(type: "none", fields: [:])
        var missing: [String] = []

        func expand(_ text: String?) -> String {
            guard let text else { return "" }
            let result = Template.expand(text, params: selection.params, now: now, calendar: calendar)
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
        default:
            break
        }

        self.type = action.type
        self.verb = verb
        self.subject = subject.isEmpty ? (selection.labels.last ?? "") : subject
        self.details = details
        self.missing = missing
    }

    private static func dateFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE d MMM, HH:mm"
        return formatter
    }
}
