import AppIntents
import KeybowKit

// Shortcuts' actions for KeybowNotes: the same as AppleScript's, through
// `Automation`. Shortcuts finds them from metadata the build extracts — see
// scripts/build-app.sh — and runs them in the app, without bringing it forward.

/// A refusal, in Shortcuts' own words.
struct ShortcutsProblem: Error, CustomLocalizedStringResourceConvertible {
    let text: String

    var localizedStringResource: LocalizedStringResource { "\(text)" }
}

@MainActor
private func automation() throws -> Automation {
    guard let automation = Automation.shared else { throw ShortcutsProblem(text: "KeybowNotes is still starting.") }
    return automation
}

/// Runs `work`, turning its refusals into Shortcuts'.
@MainActor
private func refusing<T>(_ work: () async throws -> T) async throws -> T {
    do {
        return try await work()
    } catch let problem as ShortcutsProblem {
        throw problem
    } catch {
        throw ShortcutsProblem(text: "\(error)")
    }
}

/// The trees, as Shortcuts offers them.
enum TreeChoice: String, AppEnum {
    case main, row2, row3, bottom

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tree"
    static let caseDisplayRepresentations: [TreeChoice: DisplayRepresentation] = [
        .main: "Main", .row2: "Row 2", .row3: "Row 3", .bottom: "Bottom",
    ]

    var name: String {
        switch self {
        case .main: return "main"
        case .row2: return "row 2"
        case .row3: return "row 3"
        case .bottom: return "bottom"
        }
    }
}

/// An entry in a keypad's tree: what the pick list shows.
struct KeypadEntry: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Keypad Entry"
    static let defaultQuery = KeypadEntryQuery()

    /// "Default|row 2|Window Management/Left Screen".
    let id: String

    var parts: (keypad: String, tree: String, path: String) {
        let pieces = id.components(separatedBy: "|")
        return pieces.count == 3 ? (pieces[0], pieces[1], pieces[2]) : ("", "main", id)
    }

    var displayRepresentation: DisplayRepresentation {
        let (keypad, tree, path) = parts
        return DisplayRepresentation(title: "\(path)", subtitle: "\(keypad), \(tree)")
    }
}

struct KeypadEntryQuery: EntityQuery {
    func entities(for identifiers: [KeypadEntry.ID]) async throws -> [KeypadEntry] {
        identifiers.map(KeypadEntry.init(id:))
    }

    /// Every entry that runs an action, in every keypad's trees.
    @MainActor
    func suggestedEntities() async throws -> [KeypadEntry] {
        let automation = try automation()
        let document = try automation.document()
        var entries: [KeypadEntry] = []
        for (index, keypad) in TreeControl.keypadNames(document).enumerated() {
            for tree in TreeKind.allCases {
                for path in TreeControl.leaves(document, keypad: index, tree: tree) {
                    entries.append(KeypadEntry(id: "\(keypad)|\(TreeControl.treeName(tree))|\(path.joined(separator: "/"))"))
                }
            }
        }
        return entries
    }
}

struct RunKeypadEntry: AppIntent {
    static let title: LocalizedStringResource = "Run Keypad Entry"
    static let description = IntentDescription("Runs an entry's action in KeybowNotes, as though its keys were pressed.")
    static let openAppWhenRun = false

    @Parameter(title: "Entry")
    var entry: KeypadEntry

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$entry)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let (keypad, tree, path) = entry.parts
        let said = try await refusing {
            let outcome = try await automation().trigger(path, tree: tree, keypad: keypad)
            let said = outcome.message + (outcome.detail.map { " — \($0)" } ?? "")
            guard outcome.succeeded else { throw ShortcutsProblem(text: said) }
            return said.isEmpty ? "Done" : said
        }
        return .result(value: said)
    }
}

struct AddKeypadEntry: AppIntent {
    static let title: LocalizedStringResource = "Add Keypad Entry"
    static let description = IntentDescription("Adds an entry to a keypad's tree on the first free key: a line like “Desk lamp [Home, entity: light.desk_lamp]”, or outline lines, indented for keys under keys.")
    static let openAppWhenRun = false

    @Parameter(title: "Entry", description: "As the outline writes it: “Label [annotations]”.")
    var text: String

    @Parameter(title: "Under", description: "The entry to put it under, its labels separated by slashes. Empty: the tree's top row.")
    var under: String?

    @Parameter(title: "Tree", default: .main)
    var tree: TreeChoice

    @Parameter(title: "Keypad", description: "Default, or a keypad section's name. Empty: the keypad that's plugged in.")
    var keypad: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) under \(\.$under) in \(\.$tree)") {
            \.$keypad
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let said = try await refusing { try automation().add(text, under: under, tree: tree.name, keypad: keypad) }
        return .result(value: said)
    }
}

struct ChangeKeypadEntry: AppIntent {
    static let title: LocalizedStringResource = "Change Keypad Entry"
    static let description = IntentDescription("Rewrites an entry's label and what's in its brackets, keeping what's under it.")
    static let openAppWhenRun = false

    @Parameter(title: "Entry")
    var entry: KeypadEntry

    @Parameter(title: "To", description: "The new line: “Label [annotations]”.")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Change \(\.$entry) to \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let (keypad, tree, path) = entry.parts
        let said = try await refusing { try automation().change(path, to: text, tree: tree, keypad: keypad) }
        return .result(value: said)
    }
}

struct RemoveKeypadEntry: AppIntent {
    static let title: LocalizedStringResource = "Remove Keypad Entry"
    static let description = IntentDescription("Removes an entry from a keypad's tree, with everything under it.")
    static let openAppWhenRun = false

    @Parameter(title: "Entry", description: "Its labels from the top of the tree, separated by slashes.")
    var path: String

    @Parameter(title: "Tree", default: .main)
    var tree: TreeChoice

    @Parameter(title: "Keypad", description: "Default, or a keypad section's name. Empty: the keypad that's plugged in.")
    var keypad: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Remove \(\.$path) from \(\.$tree)") {
            \.$keypad
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let said = try await refusing { try automation().remove(path, tree: tree.name, keypad: keypad) }
        return .result(value: said)
    }
}

struct GetKeypadTree: AppIntent {
    static let title: LocalizedStringResource = "Get Keypad Tree"
    static let description = IntentDescription("A keypad's tree, as outline text.")
    static let openAppWhenRun = false

    @Parameter(title: "Tree", default: .main)
    var tree: TreeChoice

    @Parameter(title: "Keypad", description: "Default, or a keypad section's name. Empty: the keypad that's plugged in.")
    var keypad: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Get the \(\.$tree) tree") {
            \.$keypad
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let outline = try await refusing { try automation().outline(tree: tree.name, keypad: keypad) }
        return .result(value: outline)
    }
}

enum StopwatchChoice: String, AppEnum {
    case start, stop, lap, reset, toggle

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Stopwatch Command"
    static let caseDisplayRepresentations: [StopwatchChoice: DisplayRepresentation] = [
        .start: "Start", .stop: "Stop", .lap: "Lap", .reset: "Reset", .toggle: "Start or Stop",
    ]
}

struct ControlStopwatch: AppIntent {
    static let title: LocalizedStringResource = "Control the Stopwatch"
    static let description = IntentDescription("Starts, stops, laps or resets KeybowNotes' stopwatch, and says what it reads.")
    static let openAppWhenRun = false

    @Parameter(title: "Do", default: .start)
    var command: StopwatchChoice

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$command) the stopwatch")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let said = try await refusing {
            let automation = try automation()
            return "\(try await automation.stopwatch(command.rawValue)) — \(automation.stopwatchReading())"
        }
        return .result(value: said)
    }
}
