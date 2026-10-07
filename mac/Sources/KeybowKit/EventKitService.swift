import AppKit
import EventKit

/// Calendar events and reminders through EventKit: no Calendar or Reminders app
/// to launch, and real dates rather than scripted ones.
///
/// EventKit needs usage descriptions in the app's Info.plist, and crashes a
/// process that asks without them, so it is only used from the packaged app.
/// A development run (`swift run`) falls back to AppleScript.
public actor EventKitService {
    public static let shared = EventKitService()

    public nonisolated static var isAvailable: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["NSCalendarsFullAccessUsageDescription"] != nil
            && info["NSRemindersFullAccessUsageDescription"] != nil
    }

    public struct AccessError: Error {
        public let message: String
        public let detail: String

        public init(message: String, detail: String) {
            self.message = message
            self.detail = detail
        }
    }

    public struct CreatedEvent: Sendable {
        public let identifier: String
        public let calendarTitle: String
        /// Set when the name matched more than one calendar.
        public let note: String?
    }

    public struct CreatedReminder: Sendable {
        public let listTitle: String
        public let usedDefault: Bool
    }

    private var store = EKEventStore()
    /// The access the current store was created under. A store keeps the
    /// access it started with, so a change in System Settings while the app
    /// runs needs a fresh one.
    private var storeAccess: [EKEntityType: EKAuthorizationStatus] = [:]

    // MARK: - Access

    /// Full access is needed for both: to find a calendar or list by name, and
    /// to open the new event afterwards. Asks the first time; after that, says
    /// how to change a refusal.
    public func ensureAccess(to type: EKEntityType) async throws {
        let label = type == .event ? "Calendars" : "Reminders"
        let status = EKEventStore.authorizationStatus(for: type)
        if let known = storeAccess[type], known != status {
            store = EKEventStore()
            storeAccess = [:]
        }
        storeAccess[type] = status

        switch status {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = type == .event
                ? try await store.requestFullAccessToEvents()
                : try await store.requestFullAccessToReminders()
            storeAccess[type] = EKEventStore.authorizationStatus(for: type)
            if !granted {
                throw AccessError(message: "KeybowNotes wasn't given full access to \(label)",
                                  detail: "Allow it in System Settings → Privacy & Security → \(label).")
            }
        case .writeOnly:
            throw AccessError(message: "KeybowNotes can only add to \(label), not read them",
                              detail: "Choose Full Access in System Settings → Privacy & Security → \(label).")
        default:
            throw AccessError(message: "KeybowNotes isn't allowed to use \(label)",
                              detail: "Allow it in System Settings → Privacy & Security → \(label).")
        }
    }

    public nonisolated static func status(for type: EKEntityType) -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: type)
    }

    // MARK: - Choices for the settings window

    public struct Choice: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        /// The account it belongs to: iCloud, Google, On My Mac…
        public let account: String
        public let colour: KeyColour
    }

    /// Calendars that can be added to, grouped by account. Empty without access.
    public func writableCalendars() -> [Choice] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return choices(store.calendars(for: .event).filter(\.allowsContentModifications))
    }

    public func reminderLists() -> [Choice] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return [] }
        return choices(store.calendars(for: .reminder).filter(\.allowsContentModifications))
    }

    private func choices(_ calendars: [EKCalendar]) -> [Choice] {
        calendars.map { calendar in
            let colour = calendar.color.usingColorSpace(.sRGB)
            return Choice(
                id: calendar.calendarIdentifier, title: calendar.title, account: calendar.source.title,
                colour: KeyColour(red: UInt8((colour?.redComponent ?? 0.5) * 255),
                                  green: UInt8((colour?.greenComponent ?? 0.5) * 255),
                                  blue: UInt8((colour?.blueComponent ?? 0.5) * 255))
            )
        }
        .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    // MARK: - Events

    public func createEvent(title: String, start: Date, duration: TimeInterval, alertMinutes: Int?,
                            calendarID: String, calendarName: String, notes: String) async throws -> CreatedEvent {
        try await ensureAccess(to: .event)
        let (calendar, note) = try findCalendar(id: calendarID, name: calendarName)

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(duration)
        event.calendar = calendar
        if !notes.isEmpty { event.notes = notes }
        if let alertMinutes { event.alarms = [EKAlarm(relativeOffset: -TimeInterval(alertMinutes) * 60)] }
        try store.save(event, span: .thisEvent, commit: true)

        return CreatedEvent(identifier: event.eventIdentifier ?? "", calendarTitle: calendar.title, note: note)
    }

    private func findCalendar(id: String, name: String) throws -> (EKCalendar, String?) {
        if !id.isEmpty {
            guard let calendar = store.calendar(withIdentifier: id) else {
                throw AccessError(message: "There's no calendar with the ID in the config", detail: id)
            }
            return (calendar, nil)
        }
        if !name.isEmpty {
            let writable = store.calendars(for: .event).filter { $0.title == name && $0.allowsContentModifications }
            guard let first = writable.first else {
                throw AccessError(message: "There's no calendar called “\(name)” that can be added to",
                                  detail: "Check the name, or use calendarId.")
            }
            // Two calendars can share a name (one per account); say which was used.
            let note = writable.count > 1
                ? "\(writable.count) calendars are called “\(name)”; used the one in \(first.source.title). Use calendarId to choose."
                : nil
            return (first, note)
        }
        guard let fallback = store.defaultCalendarForNewEvents else {
            throw AccessError(message: "There's no default calendar", detail: "Set one in Calendar → Settings.")
        }
        return (fallback, nil)
    }

    // MARK: - Reminders

    public func createReminder(title: String, notes: String, due: Date?, list: String) async throws -> CreatedReminder {
        try await ensureAccess(to: .reminder)

        // A list can be named, or given by identifier (as the settings window stores it).
        var target = list.isEmpty ? nil
            : store.calendar(withIdentifier: list) ?? store.calendars(for: .reminder).first { $0.title == list }
        let usedDefault = target == nil
        if target == nil { target = store.defaultCalendarForNewReminders() }
        guard let target else {
            throw AccessError(message: "There's no Reminders list to add to", detail: "Create one in Reminders.")
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = target
        if !notes.isEmpty { reminder.notes = notes }
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            // The alert is what makes a timer go off.
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return CreatedReminder(listTitle: target.title, usedDefault: usedDefault && !list.isEmpty)
    }
}

// MARK: - Reading, for values and the actions that use them

/// An event, as read from the calendar: what `{{event}}` and `{{agenda}}`
/// are made from.
public struct CalendarEvent: Equatable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String
    public var notes: String
    public var url: URL?
    /// Everyone invited but you, by name — or address, when there's no name.
    /// Rooms aren't people, and are left out.
    public var attendees: [String]
    /// Nil when it's you, or nobody.
    public var organizer: String?
    public var calendar: String
    /// You said no.
    public var declined: Bool
    public var canceled: Bool
    /// Its calendar can be changed: not a subscription, or someone else's.
    public var canEdit: Bool

    public init(id: String = UUID().uuidString, title: String, start: Date, end: Date, isAllDay: Bool = false,
                location: String = "", notes: String = "", url: URL? = nil, attendees: [String] = [],
                organizer: String? = nil, calendar: String = "Calendar", declined: Bool = false, canceled: Bool = false,
                canEdit: Bool = true) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.url = url
        self.attendees = attendees
        self.organizer = organizer
        self.calendar = calendar
        self.declined = declined
        self.canceled = canceled
        self.canEdit = canEdit
    }
}

/// A reminder not yet done.
public struct CalendarReminder: Equatable, Sendable {
    public var id: String
    public var title: String
    public var list: String
    public var due: Date?
    /// Due at a time, not just on a day.
    public var dueHasTime: Bool
    public var notes: String

    public init(id: String = UUID().uuidString, title: String, list: String = "Reminders", due: Date? = nil,
                dueHasTime: Bool = true, notes: String = "") {
        self.id = id
        self.title = title
        self.list = list
        self.due = due
        self.dueHasTime = dueHasTime
        self.notes = notes
    }
}

/// Where events and reminders are read and changed: EventKit in the app,
/// something made up in tests.
public protocol CalendarSource: Sendable {
    /// Every event that's on at some point between these, all calendars.
    func events(from start: Date, to end: Date) async throws -> [CalendarEvent]
    /// Every reminder not yet done, all lists.
    func incompleteReminders() async throws -> [CalendarReminder]
    func completeReminder(id: String) async throws
    /// Adds a paragraph to an event's notes: the occurrence starting then,
    /// for one that repeats.
    func appendToNotes(ofEvent id: String, startingAt start: Date, text: String) async throws
}

extension EventKitService: CalendarSource {
    public func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        try await ensureAccess(to: .event)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map(Self.snapshot)
    }

    public func incompleteReminders() async throws -> [CalendarReminder] {
        try await ensureAccess(to: .reminder)
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(Self.snapshot))
            }
        }
    }

    public func completeReminder(id: String) async throws {
        try await ensureAccess(to: .reminder)
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw AccessError(message: "That reminder isn't there any more", detail: "It may have been done or deleted.")
        }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
    }

    public func appendToNotes(ofEvent id: String, startingAt start: Date, text: String) async throws {
        try await ensureAccess(to: .event)
        // A repeating event's occurrences share an identifier: the one that
        // starts then is the one meant.
        let nearby = store.predicateForEvents(withStart: start.addingTimeInterval(-60), end: start.addingTimeInterval(60),
                                              calendars: nil)
        guard let event = store.events(matching: nearby).first(where: { $0.eventIdentifier == id })
                ?? store.event(withIdentifier: id) else {
            throw AccessError(message: "That event isn't there any more", detail: "It may have been moved or deleted.")
        }
        guard event.calendar.allowsContentModifications else {
            throw AccessError(message: "“\(event.title ?? "That event")” can't be changed",
                              detail: "Its calendar, \(event.calendar.title), is read-only.")
        }
        let notes = event.notes ?? ""
        event.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : notes + "\n\n" + text
        try store.save(event, span: .thisEvent, commit: true)
    }

    private static func snapshot(_ event: EKEvent) -> CalendarEvent {
        let people = (event.attendees ?? []).filter { $0.participantType != .room && $0.participantType != .resource }
        return CalendarEvent(
            id: event.eventIdentifier ?? "", title: event.title ?? "", start: event.startDate, end: event.endDate,
            isAllDay: event.isAllDay, location: event.location ?? "", notes: event.notes ?? "", url: event.url,
            attendees: people.filter { !$0.isCurrentUser }.map(name),
            organizer: event.organizer.flatMap { $0.isCurrentUser ? nil : name($0) },
            calendar: event.calendar.title,
            declined: people.first { $0.isCurrentUser }?.participantStatus == .declined,
            canceled: event.status == .canceled, canEdit: event.calendar.allowsContentModifications)
    }

    private static func snapshot(_ reminder: EKReminder) -> CalendarReminder {
        let components = reminder.dueDateComponents
        return CalendarReminder(
            id: reminder.calendarItemIdentifier, title: reminder.title ?? "", list: reminder.calendar.title,
            due: components.flatMap { Calendar.current.date(from: $0) },
            dueHasTime: components?.hour != nil, notes: reminder.notes ?? "")
    }

    private static func name(_ person: EKParticipant) -> String {
        if let name = person.name, !name.isEmpty { return name }
        let address = person.url.absoluteString
        return address.hasPrefix("mailto:") ? String(address.dropFirst("mailto:".count)) : address
    }
}
