import Foundation

/// The action types built in — notes, events, messages, links… — described
/// the way a module describes its own: keywords, fields with their kinds,
/// hints and help, and a symbol, with the defaults each starts from. The
/// compiler, the tree editor, the overlay and the agents' catalog read them
/// here. What each does is ActionPlanner's and ActionRunner's.
public enum BuiltInActions {
    public struct Entry: Sendable {
        public let manifest: ModuleActionType
        /// Its fields before a node sets them — an event starts at {{when}} —
        /// under what the config's `defaults.types` lays over them.
        public let defaults: [String: JSONValue]

        init(_ manifest: ModuleActionType, defaults: [String: JSONValue] = [:]) {
            self.manifest = manifest
            self.defaults = defaults
        }
    }

    public static let all: [Entry] = [
        notesCreate, notesAppend, calendarEvent, reminder, message, email,
        call, openApp, openLink, copy, insert, directInsert,
        timer, maps, music, shortcut,
    ]

    public static var types: [ModuleActionType] { all.map(\.manifest) }

    private static let byType = Dictionary(uniqueKeysWithValues: all.map { ($0.manifest.type, $0) })

    public static func type(_ name: String) -> ModuleActionType? { byType[name]?.manifest }

    /// Lowercased keyword → type: `copy` → clipboard.copy.
    public static let keywords: [String: String] = {
        var result: [String: String] = [:]
        for type in types {
            for word in type.keywords { result[word.lowercased()] = type.type }
        }
        return result
    }()

    /// Every field a built-in action takes, and `type` and `instant`, which
    /// every action does.
    public static let fields: Set<String> = Set(types.flatMap { $0.fields.map(\.key) }).union(["type", "instant"])

    /// Each type's defaults, by type.
    public static let defaults: [String: [String: JSONValue]] = byType.compactMapValues {
        $0.defaults.isEmpty ? nil : $0.defaults
    }

    /// A template's help, where a type says nothing more particular.
    public static let templateHelp = """
        A file in the templates folder, or a full path. {{placeholders}} in it are filled in \
        when the key is pressed.
        Example: standup.md
        """

    public static let notesHelp = """
        Notes added to it. Placeholders work.
        Example: From {{frontApp}}: {{selection}}
        """

    static let notesCreate = Entry(
        ModuleActionType(
            type: "notes.create", title: "New note", keywords: ["Notes", "New", "Create"], symbol: "note.text.badge.plus",
            fields: [
                ModuleField(key: "title", title: "Title", help: """
                    The note's title. A template whose first line is a # heading names the note instead.
                    Example: {{leaf}} — {{date:d MMM yyyy}}
                    """),
                ModuleField(key: "folder", title: "Folder", hint: "Levels separated by /", help: """
                    The Notes folder, levels separated by /. Missing folders are made. Empty: the account's default folder.
                    Example: Work/Meetings/{{parent}}
                    """),
                ModuleField(key: "template", title: "Template", help: """
                    A file whose text starts the note. Markdown headings, lists and bold become Notes formatting.
                    Example: standup.md
                    """),
                ModuleField(key: "account", title: "Account", help: """
                    The Notes account, by name, if you have more than one. Empty: the default account.
                    Example: iCloud
                    """),
            ]),
        defaults: [
            "folder": .string("{{folderPath}}"),
            "title": .string("{{leaf}} — {{date:d MMM yyyy}}"),
        ])

    static let notesAppend = Entry(
        ModuleActionType(
            type: "notes.append", title: "Add to a note", keywords: ["append"], symbol: "text.append",
            fields: [
                ModuleField(key: "find.byName", title: "Note", help: """
                    The note to add to, by its title. It's made the first time if Create if missing is on.
                    Examples: {{leaf}} · Journal
                    """),
                ModuleField(key: "folder", title: "Folder", help: """
                    The folder the note is in, levels separated by /.
                    Example: Projects/{{parent}}
                    """),
                ModuleField(key: "template", title: "Template", help: """
                    A file whose text is the entry added each time.
                    Example: worklog.md
                    """),
                ModuleField(key: "entry", title: "Entry", help: """
                    What's added to the note, if there's no template. Markdown works; ⌥Return for a new line.
                    Example: **{{datetime}}** — {{selection}}
                    """),
                ModuleField(key: "createIfMissing", title: "Create if missing", kind: .flag, help: """
                    Make the note if there's none by that name. Off: stop and say so instead.
                    """),
                ModuleField(key: "guards.maxBodyBytes", title: "Largest note", kind: .number, hint: "characters", help: """
                    Won't add to a note longer than this many characters: adding rewrites the whole note.
                    Example: 500000
                    """),
                ModuleField(key: "guards.refuseInlineImages", title: "Refuse inline images", kind: .flag, help: """
                    Won't add to a note with an image in its text, which adding would turn into an attachment.
                    """),
            ]),
        defaults: [
            "folder": .string("{{parentPath}}"),
            "find": .object(["byName": .string("{{leaf}}")]),
            "createIfMissing": .bool(true),
        ])

    static let calendarEvent = Entry(
        ModuleActionType(
            type: "calendar.createEvent", title: "Calendar event", keywords: ["Calendar"], symbol: "calendar.badge.plus",
            fields: [
                ModuleField(key: "title", title: "Title", help: """
                    The event's title.
                    Example: {{parent}} with {{leaf}}
                    """),
                ModuleField(key: "start", title: "Starts", hint: "tomorrow 14:00, friday…", help: """
                    When it starts: a day, a time, or both. "today" is half an hour from now; other days start at 9:00.
                    Examples: tomorrow 14:00 · friday · +2h · 2026-10-01 · {{when}}
                    """),
                ModuleField(key: "duration", title: "Duration", hint: "30m, 1h", help: """
                    How long it lasts, in minutes or hours.
                    Examples: 30m · 1h · 90 min
                    """),
                ModuleField(key: "alertMinutes", title: "Alert", kind: .number, hint: "minutes before", help: """
                    An alert this many minutes before it starts. Can also be a word in the brackets: [10 min alert].
                    Example: 10
                    """),
                ModuleField(key: "calendar", title: "Calendar", help: """
                    The calendar, by name. Empty: the one chosen in Settings, else Calendar's default.
                    Example: Work
                    """),
                ModuleField(key: "calendarId", title: "Calendar ID", help: """
                    The calendar by its identifier, which survives renaming. Usually left empty; name it in Calendar instead.
                    """),
                ModuleField(key: "notes", title: "Notes", help: notesHelp),
                ModuleField(key: "show", title: "Open for editing", kind: .flag, help: """
                    Open the new event in Calendar, ready to edit.
                    """),
            ]),
        defaults: [
            "title": .string("{{parent}}"),
            "start": .string("{{when}}"),
            "duration": .string("+30m"),
            "show": .bool(true),
        ])

    static let reminder = Entry(
        ModuleActionType(
            type: "reminders.create", title: "Reminder", keywords: ["Reminders"], symbol: "checklist",
            fields: [
                ModuleField(key: "title", title: "Title", help: """
                    The reminder.
                    Example: Call {{leaf}}
                    """),
                ModuleField(key: "due", title: "Due", hint: "+25m, tomorrow…", help: """
                    When it's due, and when it alerts: a length from now, or a day and time.
                    Examples: +25m · tomorrow 9:00 · friday · {{when}}
                    """),
                ModuleField(key: "list", title: "List", help: """
                    The Reminders list, by name. Empty: the one chosen in Settings, else the default list.
                    Example: Errands
                    """),
                ModuleField(key: "notes", title: "Notes", help: notesHelp),
            ]),
        defaults: ["title": .string("{{leaf}}")])

    static let message = Entry(
        ModuleActionType(
            type: "messages.compose", title: "Message", keywords: ["Messages"], symbol: "message",
            fields: [
                ModuleField(key: "to", title: "To", help: """
                    The phone number or email address to message. Usually the contact's, which is the default.
                    Examples: {{contact.phone}} · +44 7700 900123
                    """),
                ModuleField(key: "body", title: "Message", help: """
                    The message, ready in Messages — nothing is sent until you press Return there. ⌥Return for a new line.
                    Example: Running late, there by {{time}}
                    """),
                ModuleField(key: "template", title: "Template", help: """
                    A file whose text is the message instead.
                    Example: late.md
                    """),
            ]),
        defaults: ["to": .string("{{contact.phone}}")])

    static let email = Entry(
        ModuleActionType(
            type: "mail.compose", title: "Email", keywords: ["Mail"], symbol: "envelope",
            fields: [
                ModuleField(key: "to", title: "To", help: """
                    The address to write to. Usually the contact's, which is the default. Empty: a draft with no one to send to.
                    Examples: {{contact.email}} · alex@example.com
                    """),
                ModuleField(key: "subject", title: "Subject", help: """
                    The email's subject.
                    Example: Notes from {{date}}
                    """),
                ModuleField(key: "body", title: "Body", help: """
                    The email's text, in a draft you send yourself. ⌥Return for a new line.
                    Example: Hi {{leaf}},
                    """),
                ModuleField(key: "template", title: "Template", help: """
                    A file whose text is the email instead.
                    Example: weekly-report.md
                    """),
            ]),
        defaults: ["to": .string("{{contact.email}}")])

    static let call = Entry(
        ModuleActionType(
            type: "phone.call", title: "Phone call", keywords: ["Call", "FaceTime"], symbol: "phone",
            fields: [
                ModuleField(key: "to", title: "Number", help: """
                    The number to call. Usually the contact's, which is the default. Only digits, + and dialling marks are used.
                    Examples: {{contact.phone}} · +44 7700 900123
                    """),
                ModuleField(key: "via", title: "Via", hint: "empty for iPhone, or facetime", help: """
                    Empty: a phone call through your iPhone. facetime: a FaceTime audio call. macOS asks before dialling.
                    Example: facetime
                    """),
            ]),
        defaults: ["to": .string("{{contact.phone}}")])

    static let openApp = Entry(
        ModuleActionType(
            type: "app.open", title: "Open an app", keywords: [], symbol: "arrow.up.forward.app",
            fields: [
                ModuleField(key: "app", title: "App", help: """
                    The app to open. Pick one from the list, type its name, or Choose… it in the Finder.
                    Example: Visual Studio Code
                    """),
                ModuleField(key: "bundleId", title: "Bundle ID", help: """
                    The app's identifier, so it's found wherever it's installed. Filled in for you; needed only when the name doesn't find the app.
                    Example: com.microsoft.VSCode
                    """),
                ModuleField(key: "open", title: "Open", hint: "a path or a link", help: """
                    A file, folder or link for the app to open; ~ for your home folder. Empty: just open the app.
                    Examples: ~/Projects/{{leaf}} · {{project.path}} · https://github.com
                    """),
                ModuleField(key: "target", title: "Target", help: """
                    A channel or place inside the app, noted until it has a link. Add Open with the link to go there.
                    Example: general
                    """),
            ]),
        defaults: ["open": .string("{{project.path|}}")])

    static let openLink = Entry(
        ModuleActionType(
            type: "url.open", title: "Open a link", keywords: ["Link", "Browser"], symbol: "link",
            fields: [
                ModuleField(key: "url", title: "Link", hint: "https://…?q={{selection}}, or a path", help: """
                    A link to open — web links in your browser, others in their own app — or a file's path. \
                    Values placed into a link are encoded; a field that's only a placeholder is the link itself.
                    Examples: https://duckduckgo.com/?q={{selection}} · {{selection}} · ~/Downloads
                    """),
            ]))

    static let copy = Entry(
        ModuleActionType(
            type: "clipboard.copy", title: "Copy to clipboard", keywords: ["Copy", "Clipboard"], symbol: "doc.on.clipboard",
            fields: [
                ModuleField(key: "text", title: "Text", hint: "empty copies the label", help: """
                    The text to put on the clipboard, kept exactly. Empty: the node's label. ⌥Return for a new line.
                    Example: {{contact.phone}}
                    """),
                ModuleField(key: "template", title: "Template", help: """
                    A file whose text is copied instead.
                    Example: signature.md
                    """),
                ModuleField(key: "format", title: "Format", kind: .choice(["auto", "rich", "plain"]), hint: "Inherit: formatted when it's Markdown", help: """
                    auto: formatted too when the text is Markdown — headings, lists, **bold**, *italic*, links — so Mail, \
                    Notes and Pages paste it formatted; plain fields get the Markdown. rich: formatted always. plain: the text alone.
                    Example: plain
                    """),
            ], takesText: true))

    static let insert = Entry(
        ModuleActionType(
            type: "text.insert", title: "Insert text", keywords: ["Insert", "Paste"], symbol: "character.cursor.ibeam",
            fields: [
                ModuleField(key: "text", title: "Text", hint: "empty inserts the label — {{date}}, {{selection}}…", help: """
                    The text to type at the cursor in the app in front, replacing any selection. Empty: the node's label.
                    Examples: {{date:d MMMM yyyy}} · "{{selection}}"
                    """),
                ModuleField(key: "template", title: "Template", help: """
                    A file whose text is inserted instead.
                    Example: signature.md
                    """),
                ModuleField(key: "format", title: "Format", kind: .choice(["auto", "rich", "plain"]), hint: "Inherit: formatted when it's Markdown", help: """
                    auto: pasted formatted when the text is Markdown — headings, lists, **bold**, *italic*, links — where \
                    the app takes formatting; elsewhere, the Markdown. rich: formatted always. plain: the text alone.
                    Example: plain
                    """),
            ], takesText: true))

    static let directInsert = Entry(
        ModuleActionType(
            type: "text.insertDirect", title: "Direct insert", keywords: ["Direct Insert", "Type"], symbol: "keyboard",
            fields: [
                ModuleField(key: "text", title: "Text", hint: "empty inserts the label — {{date}}, {{selection}}…", help: """
                    The text to put at the cursor in the app in front, replacing any selection — without using \
                    the clipboard, so a clipboard manager doesn't record it. Empty: the node's label. \
                    ⌥Return for a new line.
                    Examples: {{date:d MMMM yyyy}} · Kind regards
                    """),
                ModuleField(key: "template", title: "Template", help: """
                    A file whose text is inserted instead.
                    Example: signature.md
                    """),
                ModuleField(key: "via", title: "Via", kind: .choice(["accessibility", "typing"]), hint: "Inherit: accessibility where the app takes it, else typing", help: """
                    How it goes in. Accessibility: the app replaces its selection with the text, exactly — standard \
                    Mac text views take this. Typing: a key press for each character; works nearly everywhere, \
                    but new lines press Return, which sends in some chat apps. Inherit: accessibility where the app \
                    takes it, else typing.
                    Example: via: typing
                    """),
            ], takesText: true))

    static let timer = Entry(
        ModuleActionType(
            type: "clock.timer", title: "Clock timer", keywords: ["Timer"], symbol: "timer",
            fields: [
                ModuleField(key: "duration", title: "Length", hint: "5 min, 1h 30m, 16:30 — else the label", help: """
                    How long the timer runs, or until when. Empty: a Due value, else the node's label.
                    Examples: 5 min · 1h 30m · 90s · 16:30 · tomorrow 9:00
                    """),
                ModuleField(key: "shortcut", title: "Shortcut", hint: ActionPlanner.timerShortcut, help: """
                    The shortcut that starts Clock's timers. Empty: KeybowNotes Timer.
                    Example: My Timer
                    """),
            ]))

    static let maps = Entry(
        ModuleActionType(
            type: "maps.search", title: "Search Maps", keywords: ["Maps"], symbol: "map",
            fields: [
                ModuleField(key: "query", title: "Search for", hint: "the label, if empty — {{selection}} works", help: """
                    What to search for in Maps. Empty: the node's label.
                    Examples: coffee · {{selection}} · {{leaf}} near me
                    """),
            ]))

    static let music = Entry(
        ModuleActionType(
            type: "music.play", title: "Play music", keywords: ["Music"], symbol: "music.note",
            fields: [
                ModuleField(key: "playlist", title: "Playlist", hint: "the label, if empty", help: """
                    A playlist, by name. Empty: the node's label.
                    Example: Focus
                    """),
                ModuleField(key: "album", title: "Album", hint: "plays this instead of a playlist", help: """
                    An album in your library, played in track order. Wins over Playlist.
                    Example: Kind of Blue
                    """),
                ModuleField(key: "artist", title: "Artist", hint: "when two albums share a name", help: """
                    Picks the album when two share a name. Matches the artist or album artist.
                    Example: Miles Davis
                    """),
                ModuleField(key: "shuffle", title: "Shuffle", kind: .flag, help: """
                    Shuffle a playlist, or play it in order. Inherit leaves Music's setting as it is.
                    """),
            ]))

    static let shortcut = Entry(
        ModuleActionType(
            type: "shortcut", title: "Run a shortcut", keywords: [], symbol: "bolt.fill",
            fields: [
                ModuleField(key: "name", title: "Shortcut", help: """
                    The shortcut to run, by its name in the Shortcuts app.
                    Example: Log Water
                    """),
                ModuleField(key: "input", title: "Input", hint: "text passed to it — {{selection}}, {{clipboard}}…", help: """
                    Text handed to the shortcut as its input.
                    Examples: {{selection}} · {{clipboard}}
                    """),
            ]))
}

/// Any action type: built in, or a module's.
public enum ActionTypes {
    /// Those built in, then each module's.
    public static var all: [ModuleActionType] { BuiltInActions.types + ModuleRegistry.shared.actionTypes }

    public static func describe(_ type: String) -> ModuleActionType? {
        BuiltInActions.type(type) ?? ModuleRegistry.shared.actionType(type)
    }

    /// Every field any action takes.
    public static var fields: [ModuleField] { all.flatMap(\.fields) }
}
