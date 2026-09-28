import Foundation

/// What each field in the inspector is for, shown when the pointer rests on
/// it: what it does, what can go in it, and an example. Some keys mean
/// different things in different actions — a note's title, an event's — so a
/// description is looked up for the action type first, then for the key alone.
enum FieldHelp {
    // MARK: - Every node

    static let label = """
        The node's name, shown on the overlay and in the keypad. Many actions use it too: \
        a note's title, a contact's name, a timer's length, a snippet's text.
        Example: Standup
        """

    static let colour = """
        The key's light, on the Keybow and the overlay. Set here, it colours this node \
        and everything under it that doesn't set its own. Click a swatch, or the well for any colour.
        Example: colour: ff8c00
        """

    static let type = """
        What pressing a leaf here does. Inherit takes the type from above; choosing one \
        writes its keyword into the node's brackets.
        Example: Calendar event writes [Calendar]
        """

    static let instant = """
        Run the moment the key is pressed, skipping the second to cancel — there's no taking it back. \
        Off keeps the wait where something would skip it. Inherit says what the key does now.
        Example: instant: true
        """

    // MARK: - Action fields

    /// For a field of an action type, or nil if there's nothing to say.
    static func field(_ key: String, type: String?) -> String? {
        if let type, let text = byType[type]?[key] { return text }
        return byKey[key]
    }

    private static let byKey: [String: String] = [
        "template": """
            A file in the templates folder, or a full path. {{placeholders}} in it are filled in \
            when the key is pressed.
            Example: standup.md
            """,
        "notes": """
            Notes added to it. Placeholders work.
            Example: From {{frontApp}}: {{selection}}
            """,
        "instant": instant,
    ]

    private static let byType: [String: [String: String]] = [
        "notes.create": [
            "title": """
                The note's title. A template whose first line is a # heading names the note instead.
                Example: {{leaf}} — {{date:d MMM yyyy}}
                """,
            "folder": """
                The Notes folder, levels separated by /. Missing folders are made. Empty: the account's default folder.
                Example: Work/Meetings/{{parent}}
                """,
            "template": """
                A file whose text starts the note. Markdown headings, lists and bold become Notes formatting.
                Example: standup.md
                """,
            "account": """
                The Notes account, by name, if you have more than one. Empty: the default account.
                Example: iCloud
                """,
        ],
        "notes.append": [
            "find.byName": """
                The note to add to, by its title. It's made the first time if Create if missing is on.
                Examples: {{leaf}} · Journal
                """,
            "folder": """
                The folder the note is in, levels separated by /.
                Example: Projects/{{parent}}
                """,
            "template": """
                A file whose text is the entry added each time.
                Example: worklog.md
                """,
            "entry": """
                What's added to the note, if there's no template. Markdown works; ⌥Return for a new line.
                Example: **{{datetime}}** — {{selection}}
                """,
            "createIfMissing": """
                Make the note if there's none by that name. Off: stop and say so instead.
                """,
            "guards.maxBodyBytes": """
                Won't add to a note longer than this many characters: adding rewrites the whole note.
                Example: 500000
                """,
            "guards.refuseInlineImages": """
                Won't add to a note with an image in its text, which adding would turn into an attachment.
                """,
        ],
        "calendar.createEvent": [
            "title": """
                The event's title.
                Example: {{parent}} with {{leaf}}
                """,
            "start": """
                When it starts: a day, a time, or both. "today" is half an hour from now; other days start at 9:00.
                Examples: tomorrow 14:00 · friday · +2h · 2026-10-01 · {{when}}
                """,
            "duration": """
                How long it lasts, in minutes or hours.
                Examples: 30m · 1h · 90 min
                """,
            "alertMinutes": """
                An alert this many minutes before it starts. Can also be a word in the brackets: [10 min alert].
                Example: 10
                """,
            "calendar": """
                The calendar, by name. Empty: the one chosen in Settings, else Calendar's default.
                Example: Work
                """,
            "calendarId": """
                The calendar by its identifier, which survives renaming. Usually left empty; name it in Calendar instead.
                """,
            "show": """
                Open the new event in Calendar, ready to edit.
                """,
        ],
        "reminders.create": [
            "title": """
                The reminder.
                Example: Call {{leaf}}
                """,
            "due": """
                When it's due, and when it alerts: a length from now, or a day and time.
                Examples: +25m · tomorrow 9:00 · friday · {{when}}
                """,
            "list": """
                The Reminders list, by name. Empty: the one chosen in Settings, else the default list.
                Example: Errands
                """,
        ],
        "messages.compose": [
            "to": """
                The phone number or email address to message. Usually the contact's, which is the default.
                Examples: {{contact.phone}} · +44 7700 900123
                """,
            "body": """
                The message, ready in Messages — nothing is sent until you press Return there. ⌥Return for a new line.
                Example: Running late, there by {{time}}
                """,
            "template": """
                A file whose text is the message instead.
                Example: late.md
                """,
        ],
        "mail.compose": [
            "to": """
                The address to write to. Usually the contact's, which is the default. Empty: a draft with no one to send to.
                Examples: {{contact.email}} · alex@example.com
                """,
            "subject": """
                The email's subject.
                Example: Notes from {{date}}
                """,
            "body": """
                The email's text, in a draft you send yourself. ⌥Return for a new line.
                Example: Hi {{leaf}},
                """,
            "template": """
                A file whose text is the email instead.
                Example: weekly-report.md
                """,
        ],
        "phone.call": [
            "to": """
                The number to call. Usually the contact's, which is the default. Only digits, + and dialling marks are used.
                Examples: {{contact.phone}} · +44 7700 900123
                """,
            "via": """
                Empty: a phone call through your iPhone. facetime: a FaceTime audio call. macOS asks before dialling.
                Example: facetime
                """,
        ],
        "app.open": [
            "app": """
                The app to open. Pick one from the list, type its name, or Choose… it in the Finder.
                Example: Visual Studio Code
                """,
            "bundleId": """
                The app's identifier, so it's found wherever it's installed. Filled in for you; needed only when the name doesn't find the app.
                Example: com.microsoft.VSCode
                """,
            "open": """
                A file, folder or link for the app to open; ~ for your home folder. Empty: just open the app.
                Examples: ~/Projects/{{leaf}} · {{project.path}} · https://github.com
                """,
            "target": """
                A channel or place inside the app, noted until it has a link. Add Open with the link to go there.
                Example: general
                """,
        ],
        "shortcut": [
            "name": """
                The shortcut to run, by its name in the Shortcuts app.
                Example: Log Water
                """,
            "input": """
                Text handed to the shortcut as its input.
                Examples: {{selection}} · {{clipboard}}
                """,
        ],
        "url.open": [
            "url": """
                A link to open — web links in your browser, others in their own app — or a file's path. \
                Values placed into a link are encoded; a field that's only a placeholder is the link itself.
                Examples: https://duckduckgo.com/?q={{selection}} · {{selection}} · ~/Downloads
                """,
        ],
        "clipboard.copy": [
            "text": """
                The text to put on the clipboard, kept exactly. Empty: the node's label. ⌥Return for a new line.
                Example: {{contact.phone}}
                """,
            "template": """
                A file whose text is copied instead.
                Example: signature.md
                """,
        ],
        "text.insert": [
            "text": """
                The text to type at the cursor in the app in front, replacing any selection. Empty: the node's label.
                Examples: {{date:d MMMM yyyy}} · "{{selection}}"
                """,
            "template": """
                A file whose text is inserted instead.
                Example: signature.md
                """,
        ],
        "clock.timer": [
            "duration": """
                How long the timer runs, or until when. Empty: a Due value, else the node's label.
                Examples: 5 min · 1h 30m · 90s · 16:30 · tomorrow 9:00
                """,
            "shortcut": """
                The shortcut that starts Clock's timers. Empty: KeybowNotes Timer.
                Example: My Timer
                """,
        ],
        "maps.search": [
            "query": """
                What to search for in Maps. Empty: the node's label.
                Examples: coffee · {{selection}} · {{leaf}} near me
                """,
        ],
        "music.play": [
            "playlist": """
                A playlist, by name. Empty: the node's label.
                Example: Focus
                """,
            "album": """
                An album in your library, played in track order. Wins over Playlist.
                Example: Kind of Blue
                """,
            "artist": """
                Picks the album when two share a name. Matches the artist or album artist.
                Example: Miles Davis
                """,
            "shuffle": """
                Shuffle a playlist, or play it in order. Inherit leaves Music's setting as it is.
                """,
        ],
    ]

    // MARK: - Values, contacts and projects

    static func parameter(_ key: String) -> String {
        """
        A value for {{\(key)}} in any field, here and on every node below. A node below can set its own.
        """
    }

    static func inheritedParameter(_ key: String, from node: String) -> String {
        """
        Set on \(node), for {{\(key)}} in any field. Add one here with the same name to change it for this node and those below.
        """
    }

    static let newParameterName = """
        A name for a value that any field here and below can use as {{name}}.
        Examples: when · area · contact
        """

    static let newParameterValue = """
        The value itself. Placeholders work.
        Examples: friday 10:00 · work · Alex Example
        """

    static func entry(_ key: String, contact: Bool) -> String {
        let whose = contact ? "this person" : "this project"
        switch (contact, key) {
        case (true, "phone"):
            return """
                Their phone number, shared by every node for \(whose). Used as {{contact.phone}}.
                Example: +44 7700 900123
                """
        case (true, "email"):
            return """
                Their email address, shared by every node for \(whose). Used as {{contact.email}}.
                Example: alex@example.com
                """
        case (false, "path"):
            return """
                The project's folder, shared by every node for \(whose). Used as {{project.path}}.
                Example: ~/Projects/ProjectA
                """
        default:
            return "Shared by every node for \(whose). Used as {{\(contact ? "contact" : "project").\(key)}}."
        }
    }
}
