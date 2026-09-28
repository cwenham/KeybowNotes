import Foundation

/// Fills `{{placeholders}}` in action fields and templates.
///
///   {{leaf}}               a parameter
///   {{contact.phone|none}} with a fallback when missing or empty
///   {{project.path|}}      an empty fallback: missing is fine
///   {{date}}               built-ins: date, time, datetime, weekday, isoWeek
///   {{date:d MMM yyyy}}    a date built-in with a Unicode date format
///   {{selection}}          from outside the tree when a key is pressed: the
///   {{clipboard}}          selected text and the clipboard's text in the app
///   {{frontApp}}           in front, and that app's name
///   {{#ai}}…{{/ai}}        a block: its contents filled in, then handed to
///                          a module, whose reply takes its place (see
///                          TemplateBlocks)
///
/// Anything missing without a fallback expands to nothing and is reported, so
/// callers can refuse to act on — or at least warn about — an incomplete value.
public enum Template {
    /// Names whose values come from the Mac at the moment an action runs,
    /// not from the tree.
    public static let environmentNames: Set<String> = ["selection", "clipboard", "frontApp"]

    public struct Result: Equatable, Sendable {
        public let text: String
        /// Names that had no value and no fallback, in order of appearance.
        public let missing: [String]
        /// Blocks with no reply and no stand-in: the text is incomplete.
        public var unresolved: [TemplateBlockCall] = []
        /// Why the template can't be read as written: a block never closed.
        public var problems: [String] = []
    }

    public static func expand(
        _ template: String,
        params: [String: String],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
        encode: ((String) -> String)? = nil,
        blocks: [TemplateBlockCall: String] = [:],
        standIn: ((TemplateBlockCall) -> String)? = nil
    ) -> Result {
        let document = TemplateDocument(template)
        let rendering = document.render(
            value: { body, missing in
                value(for: body, params: params, now: now, calendar: calendar, locale: locale, missing: &missing)
            },
            replies: blocks, standIn: standIn, encode: encode)
        return Result(text: rendering.text ?? "", missing: rendering.missing, unresolved: rendering.pending,
                      problems: document.problems)
    }

    /// The names a template uses, without fallbacks or formats: "selection",
    /// "contact.phone", "date" — inside blocks too.
    public static func names(in template: String) -> Set<String> {
        Set(TemplateDocument(template).placeholderBodies.map { body in
            body.prefix { $0 != "|" && $0 != ":" }.trimmingCharacters(in: .whitespaces)
        })
    }

    /// True for text that is one placeholder and nothing else: `{{selection}}`.
    public static func isSinglePlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{{"), trimmed.hasSuffix("}}"), trimmed.count > 4 else { return false }
        return !trimmed.dropFirst(2).dropLast(2).contains("{{")
    }

    /// Makes a value safe to place inside a link: spaces, &, =, ?, # and the
    /// like are percent-encoded, while / and : stay as they are, so a value
    /// like "owner/repo" still reads as a path.
    public static func linkEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: linkSafe) ?? value
    }

    private static let linkSafe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/:@!$'()*,;")

    static func value(for body: String, params: [String: String], now: Date, calendar: Calendar,
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
            // A quoted fallback, {{x|"five minutes"}}, means the words, not the quotes.
            var text = fallback.trimmingCharacters(in: .whitespaces)
            if text.count >= 2, let first = text.first, let last = text.last,
               (first == "\"" && last == "\"") || (first == "\u{201C}" && last == "\u{201D}") {
                text = String(text.dropFirst().dropLast())
            }
            return text
        }
        if !missing.contains(name) { missing.append(name) }
        return ""
    }

    /// The names filled in from the clock, never needing a value.
    public static let builtInNames: Set<String> = ["date", "time", "datetime", "weekday", "isoWeek"]

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
