import Foundation
import KeybowKit

/// A Focus — Sleep, unless it says — switched from a key:
///
///   Bedtime [Focus]
///   Work [Focus, name: Work]
///
/// macOS gives apps no way to switch a Focus, but Shortcuts can: the key runs
/// a shortcut, “KeybowNotes Sleep Focus” — the Focus's name in the middle —
/// made once in the Shortcuts app, which turns it on if it's off and off if
/// it's on. Until it's made, the key says how to make it. `shortcut` names
/// another.
public final class FocusModule: KeybowModule, @unchecked Sendable {
    public static let id = "focus"
    public static let type = "focus"

    public let manifest = ModuleManifest(
        id: id, name: "Focus",
        actionTypes: [
            ModuleActionType(
                type: type, title: "Focus", keywords: ["Focus"], symbol: "moon.fill",
                fields: [
                    ModuleField(key: "name", title: "Focus", hint: "Sleep", help: """
                        Which Focus: Sleep unless this says another, by its name in System Settings → Focus.
                        Example: Do Not Disturb
                        """),
                    ModuleField(key: "shortcut", title: "Shortcut", hint: "KeybowNotes Sleep Focus", help: """
                        The shortcut that switches it, made once in the Shortcuts app. Left out, “KeybowNotes \
                        <Focus> Focus”: Get Current Focus; If it's the Focus, Set Focus to turn it off; Otherwise, \
                        Set Focus to turn it on until turned off.
                        Example: Toggle Sleep
                        """),
                ]),
        ])

    /// The shortcuts there are, and running one: the Shortcuts app's, unless a test says.
    private let shortcuts: @Sendable () async -> [String]
    private let runShortcut: @Sendable (String) async throws -> Void

    public init(shortcuts: (@Sendable () async -> [String])? = nil,
                run: (@Sendable (String) async throws -> Void)? = nil) {
        self.shortcuts = shortcuts ?? { await ShortcutsApp.names() }
        self.runShortcut = run ?? { try await ShortcutsApp.run($0, timeout: 45) }
    }

    public func start(host: ModuleHost) {}

    static func focus(_ request: ModuleRequest) -> String {
        request.field("name") ?? "Sleep"
    }

    static func shortcut(_ request: ModuleRequest) -> String {
        request.field("shortcut") ?? "KeybowNotes \(focus(request)) Focus"
    }

    /// How to make the shortcut, step by step.
    static func howToMake(_ shortcut: String, focus: String) -> String {
        "In Shortcuts, make a shortcut called “\(shortcut)”: Get Current Focus; then If Current Focus is \(focus), "
            + "Set Focus to turn \(focus) off; Otherwise, Set Focus to turn \(focus) on until turned off."
    }

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        ModuleSummary(verb: "Switch", subject: "the \(Self.focus(request)) Focus",
                      details: ["with the “\(Self.shortcut(request))” shortcut"])
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        let focus = Self.focus(request), shortcut = Self.shortcut(request)
        guard await shortcuts().contains(shortcut) else {
            return .failure("Set up the “\(shortcut)” shortcut first", Self.howToMake(shortcut, focus: focus))
        }
        do {
            try await runShortcut(shortcut)
        } catch let error as ModuleError {
            return .failure(error.message, error.detail)
        } catch {
            return .failure("Shortcut “\(shortcut)” didn't run", "\(error)")
        }
        return .success("\(focus) Focus switched", "By “\(shortcut)”")
    }
}
