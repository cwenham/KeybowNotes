import AppKit
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
/// it's on. Until it's made, the key shows how to make it, with a button,
/// Open Shortcuts, that puts its name on the clipboard and opens the app.
/// `shortcut` names another.
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

    /// The shortcuts there are, running one, and opening the app: the
    /// Shortcuts app's, unless a test says.
    private let shortcuts: @Sendable () async -> [String]
    private let runShortcut: @Sendable (String) async throws -> Void
    private let openShortcuts: @Sendable () async -> Bool
    private var host: ModuleHost?

    public init(shortcuts: (@Sendable () async -> [String])? = nil,
                run: (@Sendable (String) async throws -> Void)? = nil,
                open: (@Sendable () async -> Bool)? = nil) {
        self.shortcuts = shortcuts ?? { await ShortcutsApp.names() }
        self.runShortcut = run ?? { try await ShortcutsApp.run($0, timeout: 45) }
        self.openShortcuts = open ?? { await Self.openShortcutsApp() }
    }

    public func start(host: ModuleHost) {
        self.host = host
    }

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

    /// The same, to show until it's dismissed, above Open Shortcuts.
    static func setUpPage(_ shortcut: String, focus: String) -> String {
        """
        **Set up the “\(shortcut)” shortcut**

        macOS lets apps switch a Focus only through Shortcuts. Make a new shortcut called \
        **\(shortcut)**, with:

        1. **Get Current Focus**
        2. **If** Current Focus is \(focus): **Set Focus**, turning \(focus) off
        3. **Otherwise**: **Set Focus**, turning \(focus) on until turned off

        Open Shortcuts copies its name, ready to paste. Then press the key again.
        """
    }

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        ModuleSummary(verb: "Switch", subject: "the \(Self.focus(request)) Focus",
                      details: ["with the “\(Self.shortcut(request))” shortcut"])
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        let focus = Self.focus(request), shortcut = Self.shortcut(request)
        guard await shortcuts().contains(shortcut) else {
            return await setUp(shortcut, focus: focus)
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

    /// Shows how to make the shortcut; Open Shortcuts copies its name and opens
    /// the app. Where nothing can be shown — the command line — says how instead.
    private func setUp(_ shortcut: String, focus: String) async -> ActionOutcome {
        let missing = ActionOutcome.failure("Set up the “\(shortcut)” shortcut first", Self.howToMake(shortcut, focus: focus))
        guard let host else { return missing }
        let page = ModuleDisplay(content: .markdown(Self.setUpPage(shortcut, focus: focus)), buttons: [.cancel, .ok],
                                 okTitle: "Open Shortcuts")
        switch await host.display(page) {
        case .ok, .entered:
            host.copy(shortcut)
            guard await openShortcuts() else {
                return .failure("Shortcuts didn't open", "“\(shortcut)” is on the clipboard, ready to paste.")
            }
            return .success("Copied “\(shortcut)”", "In Shortcuts, choose File → New Shortcut, and paste it as its name")
        case .cancel:
            return .quiet
        case .dismissed:
            return missing
        }
    }

    @MainActor
    private static func openShortcutsApp() async -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return (try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)) != nil
    }
}
