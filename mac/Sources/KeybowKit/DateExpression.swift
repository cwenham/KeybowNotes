import Foundation

/// Turns short phrases into dates, for events and reminders.
///
///   today            now + 30 minutes, rounded up to 5 (see DateRules)
///   tomorrow         tomorrow at 09:00
///   next week        a week today, 09:00
///   next month       a month today, 09:00
///   friday           the next Friday after today, 09:00 ("next friday" too)
///   +3d / +2w        days or weeks from today, 09:00
///   +90m / +2h       exactly that long from now
///   2026-10-01       that day, 09:00
///   now              right now
///
/// Any of the day forms can take a time: "tomorrow 14:00", "friday 2:30pm",
/// "today at 16:15". A time alone means today.
public enum DateExpression {
    public static func resolve(
        _ text: String,
        now: Date,
        rules: DateRules = DateRules(),
        calendar: Calendar = .current
    ) -> Date? {
        var tokens = text.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard !tokens.isEmpty else { return nil }

        // Peel off a trailing time, and an "at" before it.
        var clock: (hour: Int, minute: Int)?
        if let last = tokens.last, let parsed = parseClock(last) {
            clock = parsed
            tokens.removeLast()
            if tokens.last == "at" { tokens.removeLast() }
        }
        let base = tokens.joined(separator: " ")

        func at(_ day: Date) -> Date? {
            let hour = clock?.hour ?? rules.defaultHour
            let minute = clock?.minute ?? rules.defaultMinute
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        }

        switch base {
        case "":
            // A time on its own means today.
            return clock == nil ? nil : at(now)
        case "now":
            return clock == nil ? now : at(now)
        case "today":
            if clock != nil { return at(now) }
            return roundUp(now.addingTimeInterval(rules.todayOffset), to: rules.rounding)
        case "tomorrow":
            return calendar.date(byAdding: .day, value: 1, to: now).flatMap(at)
        case "next week":
            return calendar.date(byAdding: .day, value: 7, to: now).flatMap(at)
        case "next month":
            return calendar.date(byAdding: .month, value: 1, to: now).flatMap(at)
        default:
            break
        }

        if let offset = relativeOffset(base) {
            switch offset.unit {
            case .minute, .hour:
                // An exact interval from now; a time makes no sense with it.
                let seconds = offset.value * (offset.unit == .minute ? 60 : 3600)
                return now.addingTimeInterval(TimeInterval(seconds))
            default:
                return calendar.date(byAdding: offset.unit, value: offset.value, to: now).flatMap(at)
            }
        }

        if let weekday = weekday(base) {
            // The next occurrence strictly after today.
            var components = DateComponents()
            components.weekday = weekday
            let startOfToday = calendar.startOfDay(for: now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
            return calendar.nextDate(after: tomorrow.addingTimeInterval(-1), matching: components,
                                     matchingPolicy: .nextTime).flatMap(at)
        }

        if let day = isoDay(base, calendar: calendar) {
            return at(day)
        }
        return nil
    }

    /// How long a timer should run: a length — "5 min", "1h 30m", "90 seconds",
    /// "+25m" — or, like `due:`, a time to run until: "16:30", "today at 16:15",
    /// "tomorrow 9:00". A time alone that has passed today means tomorrow's.
    public static func timerLength(_ text: String, now: Date, rules: DateRules = DateRules(),
                                   calendar: Calendar = .current) -> TimeInterval? {
        if let length = length(text) { return length }
        guard var date = resolve(text, now: now, rules: rules, calendar: calendar) else { return nil }
        if date <= now, parseClock(text.lowercased().trimmingCharacters(in: .whitespaces)) != nil,
           let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) {
            date = tomorrow
        }
        let seconds = date.timeIntervalSince(now)
        return seconds > 0 ? seconds : nil
    }

    /// "5 min", "1h 30m", "1 hour and 30 minutes", "90s", "+25m" → seconds.
    static func length(_ text: String) -> TimeInterval? {
        var rest = Substring(text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "and", with: ""))
        if rest.hasPrefix("+") { rest = rest.dropFirst() }
        var total: TimeInterval = 0
        var parts = 0
        while !rest.isEmpty {
            let digits = rest.prefix { $0.isNumber || $0 == "." }
            guard !digits.isEmpty, let value = Double(digits) else { return nil }
            rest = rest.dropFirst(digits.count)
            let unit = rest.prefix { $0.isLetter }
            rest = rest.dropFirst(unit.count)
            switch unit {
            case "s", "sec", "secs", "second", "seconds": total += value
            case "m", "min", "mins", "minute", "minutes": total += value * 60
            case "h", "hr", "hrs", "hour", "hours": total += value * 3600
            default: return nil
            }
            parts += 1
        }
        return parts > 0 && total > 0 ? total : nil
    }

    /// 300 → "5 min", 5400 → "1 h 30 min", 45 → "45 s".
    public static func describe(seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) h") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if secs > 0 || parts.isEmpty { parts.append("\(secs) s") }
        return parts.joined(separator: " ")
    }

    /// "+30m", "30 min", "1h", "2 hours", "+1d" → seconds.
    public static func duration(_ text: String) -> TimeInterval? {
        let trimmed = text.lowercased().replacingOccurrences(of: " ", with: "")
        guard let offset = relativeOffset(trimmed.hasPrefix("+") ? trimmed : "+" + trimmed) else { return nil }
        switch offset.unit {
        case .minute: return TimeInterval(offset.value * 60)
        case .hour: return TimeInterval(offset.value * 3600)
        case .day: return TimeInterval(offset.value * 86_400)
        case .weekOfYear: return TimeInterval(offset.value * 604_800)
        default: return nil
        }
    }

    /// "14:00", "9:30", "9am", "2:30pm" → hour and minute.
    public static func parseClock(_ text: String) -> (hour: Int, minute: Int)? {
        var body = text.lowercased()
        var meridiem: String?
        for suffix in ["am", "pm"] where body.hasSuffix(suffix) {
            meridiem = suffix
            body.removeLast(2)
        }

        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        // A bare number is only a time with am/pm attached; "9" alone is ambiguous.
        guard parts.count == 2 || (parts.count == 1 && meridiem != nil) else { return nil }
        guard var hour = Int(parts[0]) else { return nil }
        var minute = 0
        if parts.count == 2 {
            guard parts[1].count == 2, let value = Int(parts[1]), (0..<60).contains(value) else { return nil }
            minute = value
        }

        switch meridiem {
        case "am":
            guard (1...12).contains(hour) else { return nil }
            if hour == 12 { hour = 0 }
        case "pm":
            guard (1...12).contains(hour) else { return nil }
            if hour != 12 { hour += 12 }
        default:
            guard (0..<24).contains(hour) else { return nil }
        }
        return (hour, minute)
    }

    // MARK: - Pieces

    private static func roundUp(_ date: Date, to step: TimeInterval) -> Date {
        guard step > 0 else { return date }
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / step).rounded(.up) * step)
    }

    private static func relativeOffset(_ text: String) -> (value: Int, unit: Calendar.Component)? {
        guard text.hasPrefix("+") else { return nil }
        let body = text.dropFirst().replacingOccurrences(of: " ", with: "")
        let digits = body.prefix { $0.isNumber }
        guard let value = Int(digits), !digits.isEmpty else { return nil }
        switch body.dropFirst(digits.count) {
        case "m", "min", "mins", "minute", "minutes": return (value, .minute)
        case "h", "hr", "hrs", "hour", "hours": return (value, .hour)
        case "d", "day", "days": return (value, .day)
        case "w", "wk", "week", "weeks": return (value, .weekOfYear)
        default: return nil
        }
    }

    private static let weekdays = [
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
    ]

    /// Calendar weekday number (Sunday = 1) for "friday", "fri", "next friday".
    private static func weekday(_ text: String) -> Int? {
        var name = text
        for prefix in ["next ", "this "] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        guard name.count >= 3 else { return nil }
        guard let index = weekdays.firstIndex(where: { $0 == name || $0.hasPrefix(name) }) else { return nil }
        return index + 1
    }

    private static func isoDay(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components),
              calendar.component(.month, from: date) == month else { return nil }
        return date
    }
}
