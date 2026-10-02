import AppKit
import KeybowKit

/// Mission Control, App Exposé or the desktop, from a key:
///
///   Windows [Exposé]
///      1. All windows
///      2. App windows
///      3. Desktop
///   Spaces [Mission Control]
///
/// `show` is all (Mission Control: every window), app (the windows of the app
/// in front) or desktop — else the label, when it says "app" or "desktop".
/// Pressing it again puts things back, as the keyboard shortcuts do.
public final class ExposeModule: KeybowModule, @unchecked Sendable {
    public static let type = "expose"

    public enum Show: String, CaseIterable, Sendable {
        case all, app, desktop

        public var title: String {
            switch self {
            case .all: return "all windows"
            case .app: return "the app's windows"
            case .desktop: return "the desktop"
            }
        }

        /// What Mission Control's launcher is given: nothing for Mission
        /// Control, 1 for the desktop, 2 for the app's windows.
        var argument: String? {
            switch self {
            case .all: return nil
            case .desktop: return "1"
            case .app: return "2"
            }
        }

        /// From a field or a label: "app", "App windows", "Show desktop".
        init?(words text: String) {
            let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
            if !words.isDisjoint(with: ["desktop"]) {
                self = .desktop
            } else if !words.isDisjoint(with: ["app", "application", "apps"]) {
                self = .app
            } else if !words.isDisjoint(with: ["all", "every", "windows", "exposé", "expose", "mission", "control"]) {
                self = .all
            } else {
                return nil
            }
        }
    }

    public let manifest = ModuleManifest(
        id: "expose", name: "Mission Control",
        actionTypes: [
            ModuleActionType(
                type: type, title: "Show all windows", keywords: ["Exposé", "Expose", "Mission Control"],
                symbol: "rectangle.3.group",
                fields: [
                    ModuleField(key: "show", title: "Show", kind: .choice(Show.allCases.map(\.rawValue)),
                                hint: "else the label — else all", help: """
                        What to show: all — Mission Control, every window — app, the windows of the app in front, \
                        or desktop. Left out, a label like “App windows” or “Desktop” says. Pressing the key again \
                        puts things back.
                        Example: app
                        """),
                ]),
        ])

    public init() {}

    public func start(host: ModuleHost) {}

    /// What's asked for: the field, else the label, else everything.
    static func show(_ request: ModuleRequest) -> (show: Show, problem: String?) {
        if let field = request.field("show") {
            guard let named = Show(rawValue: field.lowercased()) ?? Show(words: field) else {
                return (.all, "“\(field)” isn't something to show: all, app or desktop.")
            }
            return (named, nil)
        }
        return (Show(words: request.leaf) ?? .all, nil)
    }

    public func problem(with request: ModuleRequest) -> String? {
        Self.show(request).problem
    }

    /// On the press: it's something to see, not something to take back.
    public func firesAtOnce(_ request: ModuleRequest) -> Bool { true }

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        ModuleSummary(verb: "Show", subject: Self.show(request).show.title, details: [])
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        let (show, problem) = Self.show(request)
        if let problem { return .failure(problem) }
        guard let launcher = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.exposelauncher"),
              let executable = Bundle(url: launcher)?.executableURL else {
            return .failure("Mission Control isn't on this Mac")
        }
        do {
            try Process.run(executable, arguments: show.argument.map { [$0] } ?? [])
        } catch {
            return .failure("Mission Control didn't start", error.localizedDescription)
        }
        // Nothing to say on top of what's now on screen.
        return .quiet
    }
}
