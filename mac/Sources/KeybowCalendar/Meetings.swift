import Foundation
import KeybowKit

/// Which meeting is meant, its link, and the day laid out — worked out from
/// events and reminders as read, so it can be tried without a calendar.
enum Meetings {
    /// Events that are meetings to go to: not all day, not declined, not
    /// called off.
    static func attended(_ events: [CalendarEvent]) -> [CalendarEvent] {
        events.filter { !$0.isAllDay && !$0.declined && !$0.canceled }
    }

    /// The meeting under way — or, in its last five minutes, the next if that
    /// starts within ten — else the next to start today.
    static func current(_ events: [CalendarEvent], now: Date, calendar: Calendar = .current) -> CalendarEvent? {
        let meetings = attended(events)
        let underWay = meetings.filter { $0.start <= now && now < $0.end }.max { $0.start < $1.start }
        let upcoming = meetings.filter { $0.start > now && calendar.isDate($0.start, inSameDayAs: now) }
            .min { $0.start < $1.start }
        if let underWay {
            if let upcoming, underWay.end.timeIntervalSince(now) <= 5 * 60, upcoming.start.timeIntervalSince(now) <= 10 * 60 {
                return upcoming
            }
            return underWay
        }
        return upcoming
    }

    /// The next meeting to start, whatever's under way.
    static func next(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        attended(events).filter { $0.start > now }.min { $0.start < $1.start }
    }

    // MARK: Links

    /// The link to join it by: a video call's, in its URL, location or notes,
    /// else whatever link its URL is.
    static func joinLink(_ event: CalendarEvent) -> URL? {
        if let url = event.url, isMeeting(url) { return url }
        for text in [event.location, event.notes] {
            if let found = links(in: text).first(where: isMeeting) { return found }
        }
        if let url = event.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return url }
        return nil
    }

    /// What kind of call a link joins: "Zoom", "Google Meet".
    static func service(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if on("zoom.us") || on("zoom.com") || on("zoomgov.com") {
            return ["/j/", "/my/", "/s/", "/w/", "/wc/"].contains { path.hasPrefix($0) } ? "Zoom" : nil
        }
        if on("meet.google.com") { return path.count > 1 ? "Google Meet" : nil }
        if on("teams.microsoft.com") || on("teams.live.com") {
            return path.contains("meetup-join") || path.hasPrefix("/meet/") || path.hasPrefix("/l/meet") ? "Teams" : nil
        }
        if on("webex.com") { return path.contains("/meet") || path.contains("j.php") || path.contains("/join") ? "Webex" : nil }
        if on("facetime.apple.com") { return path.hasPrefix("/join") ? "FaceTime" : nil }
        if on("whereby.com") { return path.count > 1 ? "Whereby" : nil }
        if on("meet.jit.si") { return path.count > 1 ? "Jitsi" : nil }
        if on("chime.aws") { return path.count > 1 ? "Chime" : nil }
        if on("gotomeeting.com") || on("meet.goto.com") || on("gotomeet.me") { return "GoTo Meeting" }
        if on("bluejeans.com") { return path.count > 1 ? "BlueJeans" : nil }
        return nil
    }

    static func isMeeting(_ url: URL) -> Bool { service(url) != nil }

    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func links(in text: String) -> [URL] {
        guard !text.isEmpty else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    // MARK: Reminders

    /// The reminder to do next: overdue or due soonest. One with no date
    /// isn't next for anything.
    static func nextReminder(_ reminders: [CalendarReminder]) -> CalendarReminder? {
        reminders.filter { $0.due != nil }.min { $0.due! < $1.due! }
    }

    // MARK: The day

    /// A day's events and reminders as a Markdown list — from `now` on, for
    /// the rest of today — or empty when there's nothing. `overdue` adds the
    /// reminders from days before.
    static func agenda(events: [CalendarEvent], reminders: [CalendarReminder], day: Date, from now: Date?,
                       overdue: Bool, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let start = calendar.dateInterval(of: .day, for: day) else { return "" }
        let time = formatter("HH:mm", locale)
        let shortDay = formatter("d MMM", locale)

        let today = events.filter { !$0.declined && !$0.canceled && $0.start < start.end && $0.end > start.start }
            .filter { event in now.map { event.isAllDay || event.end > $0 } ?? true }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start, $0.title) < ($1.isAllDay ? 0 : 1, $1.start, $1.title) }
        var lines: [String] = today.map { event in
            if event.isAllDay { return "- All day: \(event.title)" }
            var line = "- \(time.string(from: event.start))–\(time.string(from: event.end)) \(event.title)"
            if let now, event.start <= now, now < event.end { line += " (now)" }
            return line
        }

        let due = reminders.filter { reminder in
            guard let date = reminder.due else { return false }
            return date < start.end && (overdue || date >= start.start)
        }.sorted { ($0.due!, $0.title) < ($1.due!, $1.title) }
        if !due.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("**Reminders**")
            for reminder in due {
                let date = reminder.due!
                if date < start.start {
                    lines.append("- \(reminder.title), overdue since \(shortDay.string(from: date))")
                } else if reminder.dueHasTime {
                    let late = now.map { date < $0 } ?? false
                    lines.append("- \(reminder.title), \(late ? "overdue since " : "")\(time.string(from: date))")
                } else {
                    lines.append("- \(reminder.title)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func formatter(_ format: String, _ locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = format
        return formatter
    }
}
