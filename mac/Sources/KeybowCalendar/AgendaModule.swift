import AppKit
import KeybowKit

/// Your calendar and reminders, read: values for any action, and three
/// actions of their own.
///
///   {{event}}            the meeting under way, else the next today: its title
///   {{event.start}}      14:00 — and .end, .time (14:00–14:45), .date,
///                        .location, .link, .attendees, .organizer, .notes,
///                        .calendar
///   {{event.next}}       the next meeting to start, today or tomorrow — and
///                        the same parts: {{event.next.start}}
///   {{agenda}}           the rest of today, with reminders due and overdue
///   {{agenda.today}}     all of today; {{agenda.tomorrow}} tomorrow
///   {{reminder}}         the reminder due next, or overdue — and .due, .list,
///                        .notes
///
///   Standup notes [Join]                 join the meeting's video call
///   Decision [Add to Event, text: …]     add to the meeting's notes
///   Called the bank [Done]               tick off the reminder due next
///
/// Read only when an action uses them, through EventKit, which needs
/// KeybowNotes.app: a development build can't ask for access.
public final class AgendaModule: KeybowModule, @unchecked Sendable {
    public static let id = "agenda"

    static let eventParts = ["title", "start", "end", "time", "date", "location", "link", "attendees", "organizer",
                             "notes", "calendar"]
    static let reminderParts = ["title", "due", "list", "notes"]

    /// Every value it gives.
    public static let names: [String] = {
        var names = ["event"]
        names += eventParts.map { "event.\($0)" }
        names.append("event.next")
        names += eventParts.map { "event.next.\($0)" }
        names += ["agenda", "agenda.today", "agenda.tomorrow", "reminder"]
        names += reminderParts.map { "reminder.\($0)" }
        return names
    }()

    private static let which = ModuleField(
        key: "which", title: "Which meeting", kind: .choice(["now", "next"]),
        hint: "now: the one under way, else the next today", help: """
            now — the meeting under way, or the next today; in a meeting's last five minutes, the next if it starts \
            within ten. next — the next meeting to start, whatever's under way.
            Example: next
            """)

    public let manifest = ModuleManifest(
        id: id, name: "Meetings and Agenda",
        actionTypes: [
            ModuleActionType(
                type: "calendar.join", title: "Join meeting", keywords: ["Join", "Join Meeting"], symbol: "video",
                fields: [which]),
            ModuleActionType(
                type: "calendar.addNote", title: "Add to the meeting's notes", keywords: ["Add to Event", "Event Note"],
                symbol: "note.text.badge.plus",
                fields: [
                    which,
                    ModuleField(key: "template", title: "Template", help: """
                        A file in the templates folder to add, filled in when the key is pressed.
                        Example: decision.md
                        """),
                    ModuleField(key: "text", title: "Text", hint: "empty adds the label — {{time}}, {{selection}}…",
                                help: """
                        What to add to the meeting's notes, as its own paragraph.
                        Example: {{time}} — {{selection}}
                        """),
                ],
                takesText: true),
            ModuleActionType(
                type: "reminders.complete", title: "Reminder done", keywords: ["Done", "Complete Reminder", "Tick Off"],
                symbol: "checkmark.circle",
                fields: [
                    ModuleField(key: "title", title: "Reminder", hint: "empty: the one due next", help: """
                        Words from the title of the reminder to tick off. Left out, it's the one due next, or \
                        overdue — {{reminder}}.
                        Example: Call the bank
                        """),
                    ModuleField(key: "list", title: "List", hint: "empty: the lists in Settings", help: """
                        The Reminders list to look in. Left out, the lists chosen in Settings, else all.
                        Example: Errands
                        """, offersChoices: true),
                ]),
        ],
        settings: [
            ModuleSetting(key: "calendars", title: "Calendars", kind: .several(all: "Every calendar"), help: """
                Where keys look for your meetings: {{event}}, {{agenda}} and Join. Birthdays and holidays are \
                calendars too, so tick only the ones that hold meetings if those get in the way.
                """),
            ModuleSetting(key: "lists", title: "Reminder lists", kind: .several(all: "Every list"), help: """
                Where keys look for what's due: {{reminder}}, {{agenda}} and Done.
                """),
        ],
        fetches: ["event", "agenda", "reminder"],
        symbol: "calendar.badge.clock")

    private let source: CalendarSource?
    private let open: @Sendable (URL) async throws -> Void
    private var host: ModuleHost?

    /// `source` is where events come from: EventKit, in the app. `open`
    /// opens a meeting's link: the Mac's default for it, unless a test says.
    public init(source: CalendarSource? = nil, open: (@Sendable (URL) async throws -> Void)? = nil) {
        self.source = source ?? (EventKitService.isAvailable ? EventKitService.shared : nil)
        self.open = open ?? { url in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open(url, configuration: configuration)
        }
    }

    public func start(host: ModuleHost) {
        self.host = host
    }

    /// "Work, Family" → their names, lowercased; empty for every one.
    /// A Done key's lists to choose from, in the tree editor.
    public func choices(for field: String, type: String, fields: [String: String]) async throws -> [FieldChoice] {
        guard type == "reminders.complete", field == "list" else { return [] }
        return try await access { try await self.calendarSource().allReminderLists() }.choices
    }

    /// The person's calendars, or Reminders lists, to tick in Settings: one
    /// a name, since that's how they're kept and matched, with the accounts
    /// that have one by that name.
    public func choices(forSetting key: String) async throws -> [FieldChoice] {
        let lists: [CalendarList]
        switch key {
        case "calendars": lists = try await access { try await self.calendarSource().allCalendars() }
        case "lists": lists = try await access { try await self.calendarSource().allReminderLists() }
        default: return []
        }
        return lists.choices.map { FieldChoice($0.value, title: "\($0.value) — \($0.title ?? "")") }
    }

    private func chosen(_ setting: String) -> Set<String> {
        let text = host?.setting(setting, for: Self.id) ?? ""
        return Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    private func calendarSource() throws -> CalendarSource {
        guard let source else {
            throw ModuleError("Your calendar is read by KeybowNotes.app",
                              "A development build can't ask macOS for access to Calendars and Reminders.")
        }
        return source
    }

    /// Today's and tomorrow's events, in the calendars chosen.
    private func events(around now: Date) async throws -> [CalendarEvent] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 2, to: today) ?? now.addingTimeInterval(2 * 86_400)
        let names = chosen("calendars")
        return try await access { try await self.calendarSource().events(from: today, to: end) }
            .filter { names.isEmpty || names.contains($0.calendar.lowercased()) }
    }

    private func reminders(list: String? = nil) async throws -> [CalendarReminder] {
        let names = list.map { [$0.lowercased()] } ?? chosen("lists")
        return try await access { try await self.calendarSource().incompleteReminders() }
            .filter { names.isEmpty || names.contains($0.list.lowercased()) }
    }

    /// EventKit's refusals, as a module says them.
    private func access<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as EventKitService.AccessError {
            throw ModuleError(error.message, error.detail)
        }
    }

    // MARK: - Values

    public func fetch(_ names: [String], params: [String: String], now: Date) async throws -> [String: String] {
        for name in names where !Self.names.contains(name) {
            throw ModuleError("There's no {{\(name)}}", "Meetings and Agenda gives {{event.…}}, {{agenda}} and {{reminder}}.")
        }
        var values: [String: String] = [:]
        if names.contains(where: { $0.hasPrefix("event") || $0.hasPrefix("agenda") }) {
            let events = try await events(around: now)
            if let event = Meetings.current(events, now: now) { values.merge(Self.values(of: event, as: "event")) { a, _ in a } }
            if let next = Meetings.next(events, now: now) { values.merge(Self.values(of: next, as: "event.next")) { a, _ in a } }
            if names.contains(where: { $0.hasPrefix("agenda") }) {
                // Without access to Reminders, the day's events still say most of it.
                let reminders = (try? await reminders()) ?? []
                let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
                values["agenda"] = Meetings.agenda(events: events, reminders: reminders, day: now, from: now, overdue: true)
                values["agenda.today"] = Meetings.agenda(events: events, reminders: reminders, day: now, from: nil,
                                                         overdue: true)
                values["agenda.tomorrow"] = Meetings.agenda(events: events, reminders: reminders, day: tomorrow,
                                                            from: nil, overdue: false)
            }
        }
        if names.contains(where: { $0.hasPrefix("reminder") }), let next = Meetings.nextReminder(try await reminders()) {
            values.merge(Self.values(of: next)) { a, _ in a }
        }
        // What isn't there is empty, so {{event|No meeting}} gets its fallback.
        return Dictionary(uniqueKeysWithValues: names.map { ($0, values[$0] ?? "") })
    }

    static func values(of event: CalendarEvent, as prefix: String, locale: Locale = .current) -> [String: String] {
        let time = Meetings.formatter("HH:mm", locale)
        let start = time.string(from: event.start)
        let end = time.string(from: event.end)
        let parts: [String: String] = [
            "title": event.title,
            "start": start,
            "end": end,
            "time": "\(start)–\(end)",
            "date": Meetings.formatter("d MMM yyyy", locale).string(from: event.start),
            "location": event.location,
            "link": Meetings.joinLink(event)?.absoluteString ?? "",
            "attendees": event.attendees.joined(separator: ", "),
            "organizer": event.organizer ?? "",
            "notes": event.notes,
            "calendar": event.calendar,
        ]
        var values = [prefix: event.title]
        for (part, value) in parts { values["\(prefix).\(part)"] = value }
        return values
    }

    static func values(of reminder: CalendarReminder, locale: Locale = .current) -> [String: String] {
        var due = ""
        if let date = reminder.due {
            due = Meetings.formatter(reminder.dueHasTime ? "d MMM yyyy, HH:mm" : "d MMM yyyy", locale).string(from: date)
        }
        return ["reminder": reminder.title, "reminder.title": reminder.title, "reminder.due": due,
                "reminder.list": reminder.list, "reminder.notes": reminder.notes]
    }

    public func fetchSubject(for names: [String]) -> String {
        let reminders = names.contains { $0.hasPrefix("reminder") }
        let calendar = names.contains { $0.hasPrefix("event") || $0.hasPrefix("agenda") }
        switch (calendar, reminders) {
        case (true, true): return "your calendar and reminders"
        case (false, true): return "your reminders"
        default: return "your calendar"
        }
    }

    public func standIn(forValue name: String) -> String {
        switch name {
        case "event", "event.title": return "‹the meeting›"
        case "event.next", "event.next.title": return "‹the next meeting›"
        case "agenda", "agenda.today": return "‹today’s agenda›"
        case "agenda.tomorrow": return "‹tomorrow’s agenda›"
        case "reminder", "reminder.title": return "‹the reminder due next›"
        default:
            let part = name.split(separator: ".").last.map(String.init) ?? name
            return name.hasPrefix("reminder") ? "‹its \(part)›" : "‹the meeting’s \(part)›"
        }
    }

    // MARK: - Actions

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        let meeting = request.field("which") == "next" ? "the next meeting" : "the meeting"
        switch request.type {
        case "calendar.join":
            return ModuleSummary(verb: "Join", subject: meeting)
        case "calendar.addNote":
            let text = request.field("text") ?? request.leaf
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return ModuleSummary(verb: "Add to \(meeting)", subject: line.count > 50 ? String(line.prefix(50)) + "…" : line)
        default:
            return ModuleSummary(verb: "Complete", subject: request.field("title").map { "“\($0)”" } ?? "the reminder due next",
                                 details: request.field("list").map { ["in \($0)"] } ?? [])
        }
    }

    public func problem(with request: ModuleRequest) -> String? {
        if let which = request.field("which"), !["now", "next"].contains(which.lowercased()) {
            return "“\(which)” isn't a meeting to choose: now or next."
        }
        return nil
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        do {
            switch request.type {
            case "calendar.join": return try await join(request, now: now)
            case "calendar.addNote": return try await addNote(request, now: now)
            case "reminders.complete": return try await complete(request)
            default: return .failure("Meetings and Agenda doesn't do “\(request.type)”")
            }
        } catch let error as ModuleError {
            return .failure(error.message, error.detail)
        } catch {
            return .failure("Your calendar couldn't be changed", error.localizedDescription)
        }
    }

    /// The meeting meant: the one under way, else the next today — or the
    /// next, whatever's under way.
    private func meeting(_ request: ModuleRequest, now: Date) async throws -> CalendarEvent {
        let events = try await events(around: now)
        if request.field("which")?.lowercased() == "next" {
            guard let next = Meetings.next(events, now: now) else {
                throw ModuleError("There's no meeting coming up", "Nothing else today or tomorrow.")
            }
            return next
        }
        guard let event = Meetings.current(events, now: now) else {
            throw ModuleError("There's no meeting now", "Nothing's under way, and nothing else is on today.")
        }
        return event
    }

    private func join(_ request: ModuleRequest, now: Date) async throws -> ActionOutcome {
        let event = try await meeting(request, now: now)
        guard let link = Meetings.joinLink(event) else {
            throw ModuleError("“\(event.title)” has no link to join",
                              "No video call link in its URL, location or notes.")
        }
        try await open(link)
        let service = Meetings.service(link).map { " on \($0)" } ?? ""
        return .success("Joining “\(event.title)”\(service)", Self.when(event, now: now))
    }

    private func addNote(_ request: ModuleRequest, now: Date) async throws -> ActionOutcome {
        let text = request.field("text") ?? request.leaf
        guard !text.isEmpty else { throw ModuleError("There's nothing to add") }
        let event = try await meeting(request, now: now)
        guard event.canEdit else {
            throw ModuleError("“\(event.title)” can't be changed", "Its calendar, \(event.calendar), is read-only.")
        }
        try await access { try await self.calendarSource().appendToNotes(ofEvent: event.id, startingAt: event.start, text: text) }
        return .success("Added to “\(event.title)”", Self.when(event, now: now))
    }

    private func complete(_ request: ModuleRequest) async throws -> ActionOutcome {
        let list = request.field("list")
        let reminders = try await reminders(list: list)
        let reminder: CalendarReminder
        if let words = request.field("title") {
            let matching = reminders.filter { $0.title.range(of: words, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            // An exact title first, then the one due soonest, then any.
            guard let found = matching.first(where: { $0.title.caseInsensitiveCompare(words) == .orderedSame })
                    ?? Meetings.nextReminder(matching) ?? matching.first else {
                throw ModuleError("There's no reminder “\(words)” to do", list.map { "Looked in \($0)." })
            }
            reminder = found
        } else {
            guard let next = Meetings.nextReminder(reminders) else {
                throw ModuleError("Nothing's due", (list.map { "Nothing in \($0) has a date. " } ?? "")
                                  + "Name the reminder with title, to tick off one without a date.")
            }
            reminder = next
        }
        try await access { try await self.calendarSource().completeReminder(id: reminder.id) }
        return .success("Done: \(reminder.title)", "in \(reminder.list)")
    }

    /// "now, until 14:45", "at 14:00", "tomorrow at 09:30".
    static func when(_ event: CalendarEvent, now: Date, locale: Locale = .current) -> String {
        let time = Meetings.formatter("HH:mm", locale)
        if event.start <= now { return "now, until \(time.string(from: event.end))" }
        if Calendar.current.isDate(event.start, inSameDayAs: now) { return "at \(time.string(from: event.start))" }
        return "tomorrow at \(time.string(from: event.start))"
    }
}
