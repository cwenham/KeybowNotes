import AppKit
import Foundation

/// Helper shortcuts the person makes once — a Clock timer's, a Focus's — and
/// helping them make one.
extension ShortcutsApp {
    /// For a shortcut that isn't there yet: shows `page`, how to make it,
    /// with Open Shortcuts, which puts its name on the clipboard and opens a
    /// new shortcut to paste it into. Cancel does nothing more. Where nothing
    /// can be shown — no host, or the command line's — the failure says how,
    /// in `steps`.
    public static func offerToMake(_ name: String, page: String, steps: String, host: ModuleHost?,
                                   open: @Sendable () async -> Bool = { await openNewShortcut() }) async -> ActionOutcome {
        let missing = ActionOutcome.failure("Set up the “\(name)” shortcut first", steps)
        guard let host else { return missing }
        let display = ModuleDisplay(content: .markdown(page), buttons: [.cancel, .ok], okTitle: "Open Shortcuts")
        switch await host.display(display) {
        case .ok, .entered:
            host.copy(name)
            guard await open() else {
                return .failure("Shortcuts didn't open", "“\(name)” is on the clipboard, ready to paste.")
            }
            return .success("Copied “\(name)”", "Paste it as the new shortcut's name")
        case .cancel:
            return .quiet
        case .dismissed:
            return missing
        }
    }

    /// The page `offerToMake` shows: a heading, why, the steps, and what the
    /// button does.
    public static func setUpPage(_ name: String, why: String, steps: [String]) -> String {
        """
        **Set up the “\(name)” shortcut**

        \(why) Make a new shortcut called **\(name)**, with:

        \(steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

        Open Shortcuts copies its name, ready to paste. Then press the key again.
        """
    }

    /// A new, empty shortcut in the Shortcuts app; else the app, should that
    /// way in go. False when neither opens.
    @MainActor
    public static func openNewShortcut() async -> Bool {
        if let url = URL(string: "shortcuts://create-shortcut"), NSWorkspace.shared.open(url) { return true }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return (try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)) != nil
    }
}
