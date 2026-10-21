import Foundation
import KeybowKit

/// A desktop on each screen, from a key:
///
///   Coding [Spaces, screen1: 2]
///      1. KeybowNotes [screen2: 1, screen3: 3]
///      2. Website [screen2: 4, screen3: no change]
///
/// `screen1`, `screen2` … are the screens counted from the left, as the window
/// action's `screen: 2` counts them. Each takes a desktop of that screen,
/// counted from 1 as Mission Control shows them, or `no change`. Each is
/// inherited on its own, so a branch can set one screen and the keys under it
/// the others; a screen nothing sets is left as it is.
///
/// macOS gives apps no way to switch Spaces, so it presses each desktop's
/// *Switch to Desktop N* shortcut, as Spaceman does: N counts desktops across
/// every screen. It reads which desktops each screen has from the window
/// server first, and after each press waits to see the screen change.
public final class SpacesModule: KeybowModule, @unchecked Sendable {
    public static let id = "spaces"
    public static let type = "spaces"
    /// Screens it takes a desktop for: `screen1` to `screen6`.
    public static let screenCount = 6

    /// What a screen's field says.
    public enum Choice: Equatable, Sendable {
        case unchanged
        case desktop(Int)

        /// `2`, `Desktop 2`, `no change`, `none`, `-`. Nil for anything else.
        public init?(_ text: String) {
            let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
            let words = lower.filter { $0.isLetter }
            if lower.isEmpty || ["-", "–", "—"].contains(lower)
                || ["nochange", "none", "unchanged", "leave", "leaveit", "same", "asis", "keep", "nothing"].contains(words) {
                self = .unchanged
                return
            }
            var number = Substring(lower)
            for word in ["desktop", "space"] where number.hasPrefix(word) {
                number = number.dropFirst(word.count)
            }
            guard let desktop = Int(number.trimmingCharacters(in: .whitespaces)), desktop >= 1 else { return nil }
            self = .desktop(desktop)
        }

        /// As the editor writes it.
        public var written: String {
            switch self {
            case .unchanged: return "no change"
            case .desktop(let number): return String(number)
            }
        }
    }

    /// `screen2`.
    public static func key(forScreen screen: Int) -> String { "screen\(screen)" }

    /// 2, for `screen2`.
    public static func screen(ofKey key: String) -> Int? {
        guard key.hasPrefix("screen"), let number = Int(key.dropFirst("screen".count)),
              (1...screenCount).contains(number) else { return nil }
        return number
    }

    public let manifest = ModuleManifest(
        id: id, name: "Spaces",
        actionTypes: [
            ModuleActionType(
                type: type, title: "Switch Spaces", keywords: ["Spaces", "Space"], symbol: "square.split.2x1",
                fields: (1...screenCount).map { screen in
                    ModuleField(key: key(forScreen: screen), title: "Screen \(screen)", hint: "a desktop, or no change",
                                help: """
                        The desktop to show on screen \(screen), counting screens from the left, and that screen's \
                        desktops from 1, left to right as Mission Control shows them. no change leaves it as it \
                        is, even when a branch above sets it. Left out, the branch above decides — else it's left \
                        as it is.
                        Example: 2
                        """)
                }),
        ])

    private let control: SpacesControl
    /// How long to wait for a screen to change, before pressing again.
    private let patience: TimeInterval

    public init(control: SpacesControl = SystemSpaces(), patience: TimeInterval = 1) {
        self.control = control
        self.patience = patience
    }

    public func start(host: ModuleHost) {}

    /// The desktop asked for on each screen, by screen number: those saying
    /// `no change` left out.
    static func wanted(_ request: ModuleRequest) -> (desktops: [Int: Int], problem: String?) {
        var desktops: [Int: Int] = [:]
        for screen in 1...screenCount {
            guard let text = request.field(key(forScreen: screen)) else { continue }
            guard let choice = Choice(text) else {
                return ([:], "“\(text)” isn't a desktop for screen \(screen): a number, like 2, or no change.")
            }
            if case .desktop(let number) = choice { desktops[screen] = number }
        }
        if desktops.isEmpty {
            return ([:], "Choose a desktop for a screen: screen1: 2 shows the left screen's second desktop.")
        }
        return (desktops, nil)
    }

    public func problem(with request: ModuleRequest) -> String? {
        Self.wanted(request).problem
    }

    /// On the press: it's something to see, as Mission Control is.
    public func firesAtOnce(_ request: ModuleRequest) -> Bool { true }

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        let shown = Self.wanted(request).desktops.sorted { $0.key < $1.key }
            .map { "desktop \($0.value) on screen \($0.key)" }
        guard let first = shown.first else { return ModuleSummary(verb: "Switch", subject: "Spaces") }
        return ModuleSummary(verb: "Show", subject: first, details: Array(shown.dropFirst()))
    }

    // MARK: - Switching

    /// One screen to switch: the desktop, and the shortcut that shows it.
    struct Step: Equatable {
        let screen: SpacesLayout.Screen
        let space: SpacesLayout.Space
        let shortcut: DesktopShortcut
    }

    struct Plan: Equatable {
        var steps: [Step] = []
        var failures: [ModuleError] = []
        /// Screens already showing theirs.
        var already = 0
    }

    /// What to press for each screen, and why any can't be switched. The
    /// pointer's screen goes last, so the keyboard ends up where the pointer
    /// is.
    static func plan(_ desktops: [Int: Int], layout: SpacesLayout, shortcuts: [Int: DesktopShortcut],
                     pointer: Int?) -> Plan {
        var plan = Plan()
        for (number, desktop) in desktops.sorted(by: { $0.key < $1.key }) {
            guard let screen = layout.screen(number) else {
                plan.failures.append(ModuleError("There's no screen \(number)", layout.screens.count == 1
                    ? "Only one is connected." : "Screens are numbered 1 to \(layout.screens.count), from the left."))
                continue
            }
            guard !screen.spaces.isEmpty else {
                plan.failures.append(ModuleError("\(screen.name) shows the main screen's Spaces",
                    "Turn on “Displays have separate Spaces” in System Settings → Desktop & Dock, then log out and in."))
                continue
            }
            guard let space = screen.desktop(desktop) else {
                let count = screen.desktops.count
                plan.failures.append(ModuleError("\(screen.name) has no desktop \(desktop)",
                    "It has \(count == 1 ? "one" : String(count)). Mission Control adds more."))
                continue
            }
            if screen.showing == space.id {
                plan.already += 1
                continue
            }
            guard let overall = space.missionControl, let shortcut = shortcuts[overall] else {
                let overall = space.missionControl ?? 0
                plan.failures.append(ModuleError("Desktop \(overall) has no shortcut to switch to it",
                    overall > DesktopShortcut.most
                        ? "Mission Control has shortcuts for the first \(DesktopShortcut.most) desktops only."
                        : DesktopShortcut.whereToTurnOn(overall)))
                continue
            }
            plan.steps.append(Step(screen: screen, space: space, shortcut: shortcut))
        }
        plan.steps.sort { ($0.screen.number == pointer ? 1 : 0, $0.screen.number) < ($1.screen.number == pointer ? 1 : 0, $1.screen.number) }
        return plan
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        let (desktops, problem) = Self.wanted(request)
        if let problem { return .failure(problem) }
        guard control.mayPress else {
            control.askToPress()
            return .failure("KeybowNotes needs Accessibility access to switch Spaces",
                            "Allow it in System Settings → Privacy & Security → Accessibility.")
        }
        let (layout, pointer) = await control.layout()
        var plan = Self.plan(desktops, layout: layout, shortcuts: control.shortcuts(), pointer: pointer)
        for step in plan.steps {
            if Task.isCancelled { break }
            if let failure = await show(step, layout: layout) { plan.failures.append(failure) }
        }
        guard let first = plan.failures.first else {
            // What it did is on the screens.
            return .quiet
        }
        if plan.failures.count == 1 { return .failure(first.message, first.detail) }
        return .failure("\(plan.failures.count) screens didn't switch", plan.failures.map(\.description).joined(separator: " · "))
    }

    /// Presses the step's shortcut and waits to see its screen show the
    /// desktop — pressing once more if nothing changes, in case the press
    /// came while another screen was still sliding. Nil once it's showing.
    private func show(_ step: Step, layout: SpacesLayout) async -> ModuleError? {
        let before = control.showing()
        for _ in 0..<2 {
            control.press(step.shortcut)
            let deadline = Date().addingTimeInterval(patience)
            repeat {
                let now = control.showing()
                if now[step.screen.identifier] == step.space.id { return nil }
                // Another desktop came up: Mission Control counts them otherwise.
                if let changed = now.first(where: { before[$0.key] != $0.value }) {
                    return Self.misnumbered(step, showed: changed.value, on: changed.key, layout: layout)
                }
                try? await Task.sleep(nanoseconds: 40_000_000)
            } while Date() < deadline && !Task.isCancelled
        }
        let overall = step.space.missionControl ?? 0
        return ModuleError("\(step.screen.name) didn't switch to desktop \(step.space.desktop ?? 0)",
                           "Pressing \(step.shortcut.title), the shortcut for Desktop \(overall), changed nothing.")
    }

    /// The desktop that came up wasn't the one meant: Mission Control counts
    /// desktops in another order than from the left.
    static func misnumbered(_ step: Step, showed space: Int, on identifier: String, layout: SpacesLayout) -> ModuleError {
        let overall = step.space.missionControl ?? 0
        let screen = layout.screen(identifier: identifier)
        let desktop = screen?.spaces.first { $0.id == space }?.desktop
        var detail = "Its shortcut, \(step.shortcut.title), showed \(screen?.name ?? "another screen")'s desktop "
            + "\(desktop.map(String.init) ?? "?") instead of \(step.screen.name)'s desktop \(step.space.desktop ?? 0): "
            + "macOS numbers desktops across screens in another order."
        if layout.serverNumber(of: space) == overall {
            detail += " It seems to count the main screen's first."
        }
        return ModuleError("Desktop \(overall) is on another screen", detail)
    }
}
