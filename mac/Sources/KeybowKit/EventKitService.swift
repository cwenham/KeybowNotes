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
