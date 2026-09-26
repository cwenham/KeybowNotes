import Foundation

/// Fills `{{placeholders}}` in action fields and templates.
///
///   {{leaf}}               a parameter
///   {{contact.phone|none}} with a fallback when missing or empty
///   {{project.path|}}      an empty fallback: missing is fine
///   {{date}}               built-ins: date, time, datetime, weekday, isoWeek
///   {{date:d MMM yyyy}}    a date built-in with a Unicode date format
///
/// Anything missing without a fallback expands to nothing and is reported, so
/// callers can refuse to act on — or at least warn about — an incomplete value.
public enum Template {
    public struct Result: Equatable, Sendable {
        public let text: String
        /// Names that had no value and no fallback, in order of appearance.
        public let missing: [String]
    }

    public static func expand(
        _ template: String,
        params: [String: String],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> Result {
        var output = ""
        var missing: [String] = []
        var rest = Substring(template)

        while let open = rest.range(of: "{{") {
            output += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                // An unclosed brace is left as written.
                output += rest[open.lowerBound...]
                rest = ""
                break
            }
            let body = rest[open.upperBound..<close.lowerBound]
            output += value(for: String(body), params: params, now: now, calendar: calendar,
                            locale: locale, missing: &missing)
            rest = rest[close.upperBound...]
        }
        output += rest
        return Result(text: output, missing: missing)
    }

    private static func value(for body: String, params: [String: String], now: Date, calendar: Calendar,
                              locale: Locale, missing: inout [String]) -> String {
        var name = body
        var fallback: String?
        if let bar = body.firstIndex(of: "|") {
            name = String(body[..<bar])
            fallback = String(body[body.index(after: bar)...])
        }
        name = name.trimmingCharacters(in: .whitespaces)

        if let given = params[name], !given.isEmpty {
            return given
        }
        if let builtIn = builtIn(name, now: now, calendar: calendar, locale: locale) {
            return builtIn
        }
        if let fallback {
            return fallback.trimmingCharacters(in: .whitespaces)
        }
        if !missing.contains(name) { missing.append(name) }
        return ""
    }

    private static func builtIn(_ name: String, now: Date, calendar: Calendar, locale: Locale) -> String? {
        let parts = name.split(separator: ":", maxSplits: 1)
        let key = parts.first.map(String.init) ?? name
        let format = parts.count == 2 ? String(parts[1]) : nil

        func formatted(_ pattern: String) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.dateFormat = pattern
            return formatter.string(from: now)
        }

        switch key {
        case "date": return formatted(format ?? "d MMM yyyy")
        case "time": return formatted(format ?? "HH:mm")
        case "datetime": return formatted(format ?? "d MMM yyyy, HH:mm")
        case "weekday": return formatted(format ?? "EEEE")
        case "isoWeek":
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = calendar.timeZone
            return String(iso.component(.weekOfYear, from: now))
        default:
            return nil
        }
    }
}
