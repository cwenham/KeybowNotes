import Foundation
import KeybowKit

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
        writes the word beside it into the node's brackets, and writing that word in the outline does the same.
        Example: Reminder done writes [Done]
        """

    static let instant = """
        Run the moment the key is pressed, skipping the second to cancel — there's no taking it back. \
        Off keeps the wait where something would skip it. Inherit says what the key does now.
        Example: instant: true
        """

    // MARK: - Action fields

    /// For a field of an action type, or nil if there's nothing to say. A
    /// built-in type's fields say for themselves, in BuiltInActions; a
    /// module's, in its manifest, when there's nothing here.
    static func field(_ key: String, type: String?) -> String? {
        let own = type.flatMap(BuiltInActions.type)?.fields.first { $0.key == key }?.help
        guard let text = own.flatMap({ $0.isEmpty ? nil : $0 }) ?? byKey[key] else { return nil }
        var lines = [text]
        if blockKeys.contains(key) || dataKeys.contains(key) { lines.append(dataLine) }
        if blockKeys.contains(key) { lines.append(blockLine) }
        return lines.joined(separator: "\n")
    }

    /// Text fields where a block's reply may go — not links, numbers or apps.
    private static let blockKeys: Set<String> = ["template", "entry", "text", "body", "title", "subject", "notes"]
    private static let blockLine = "An {{#ai}}…{{/ai}} block asks Claude, and its reply takes the block's place."
    /// Fields that steer the action but may still take a fetched value.
    private static let dataKeys: Set<String> = ["url", "to", "query", "input"]
    private static let dataLine = """
        {{api.weather}} is the value from the “weather” data source: Edit Data Sources… in the menu bar. \
        {{location}} is where this Mac is. {{quote file='quotes.md'}} picks a paragraph or list item from a file.
        """

    /// For a module's field of the same name, when it says nothing itself.
    private static let byKey: [String: String] = [
        "template": BuiltInActions.templateHelp,
        "notes": BuiltInActions.notesHelp,
        "instant": instant,
    ]

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
