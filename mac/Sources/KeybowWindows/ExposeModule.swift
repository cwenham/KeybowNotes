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
///
/// It asks the Dock as Mission Control's own launcher does, through
/// `CoreDockSendNotification`. Running the launcher as a child process does
/// nothing — it's gone before the Dock hears it — so the call is made here,
/// in a process that stays; failing that, the launcher is opened as an app.
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

        /// What the Dock is sent.
        var notification: String {
            switch self {
            case .all: return "com.apple.expose.awake"
            case .app: return "com.apple.expose.front.awake"
            case .desktop: return "com.apple.showdesktop.awake"
            }
        }

        /// What Mission Control's launcher is given instead: nothing for
        /// Mission Control, 1 for the desktop, 2 for the app's windows.
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
        if let send = Self.sendToDock {
            await MainActor.run { send(show.notification as CFString, nil) }
            // Nothing to say on top of what's now on screen.
            return .quiet
        }
        guard let launcher = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.exposelauncher") else {
            return .failure("Mission Control isn't on this Mac")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = show.argument.map { [$0] } ?? []
        do {
            _ = try await NSWorkspace.shared.openApplication(at: launcher, configuration: configuration)
            return .quiet
        } catch {
            return .failure("Mission Control didn't start", error.localizedDescription)
        }
    }

    /// The Dock's own way in, as the launcher uses it; nil if it's gone.
    private typealias DockNotification = @convention(c) (CFString, UnsafeMutableRawPointer?) -> Void
    private static let sendToDock: DockNotification? = {
        let services = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        guard let handle = dlopen(services, RTLD_LAZY), let symbol = dlsym(handle, "CoreDockSendNotification") else {
            return nil
        }
        return unsafeBitCast(symbol, to: DockNotification.self)
    }()
}
