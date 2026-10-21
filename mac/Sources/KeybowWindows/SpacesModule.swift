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
/// macOS gives apps no way to switch Spaces, and Mission Control's *Switch to
/// Desktop* shortcuts reach only the main screen's desktops. So it opens
/// Mission Control and presses each desktop's thumbnail, as Hammerspoon does,
/// after reading which desktops each screen has from the window server; then
/// watches each screen change, and goes again for any that didn't.
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
    /// How long to wait for the screens to change, before going again.
    private let patience: TimeInterval

    public init(control: SpacesControl = SystemSpaces(), patience: TimeInterval = 1.5) {
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

    /// One screen to switch, and the desktop to show.
    struct Step: Equatable {
        let screen: SpacesLayout.Screen
        let space: SpacesLayout.Space

        var thumbnail: SpaceThumbnail {
            SpaceThumbnail(display: screen.displayID, index: screen.spaces.firstIndex(of: space) ?? 0,
                           count: screen.spaces.count)
        }
    }

    struct Plan: Equatable {
        var steps: [Step] = []
        var failures: [ModuleError] = []
        /// Screens already showing theirs.
        var already = 0
    }

    /// Which screens to switch, and why any can't be. The pointer's screen
    /// goes last, so the keyboard ends up where the pointer is.
    static func plan(_ desktops: [Int: Int], layout: SpacesLayout, pointer: Int?) -> Plan {
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
            } else {
                plan.steps.append(Step(screen: screen, space: space))
            }
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
        var plan = Self.plan(desktops, layout: layout, pointer: pointer)
        var waiting = plan.steps
        var trouble: ModuleError?
        // Every screen in one go: Mission Control closes on the first press,
        // and the others may take or not. Then each left, on its own.
        for round in [[waiting]] + [waiting.map { [$0] }] {
            for steps in round {
                let left = steps.filter { step in waiting.contains(step) }
                guard !left.isEmpty, !Task.isCancelled else { continue }
                do {
                    try await control.press(left.map(\.thumbnail))
                } catch let error as ModuleError {
                    trouble = error
                    continue
                } catch {
                    trouble = ModuleError("Mission Control didn't switch Spaces", "\(error)")
                    continue
                }
                await settle(left)
                let showing = control.showing()
                waiting.removeAll { showing[$0.screen.identifier] == $0.space.id }
            }
            if waiting.isEmpty { break }
        }
        for step in waiting {
            plan.failures.append(trouble.map { ModuleError("\(step.screen.name) didn't switch: \($0.message)", $0.detail) }
                ?? ModuleError("\(step.screen.name) didn't switch to desktop \(step.space.desktop ?? 0)",
                               "Its thumbnail in Mission Control was pressed, and the screen stayed as it was."))
        }
        guard let first = plan.failures.first else {
            // What it did is on the screens.
            return .quiet
        }
        if plan.failures.count == 1 { return .failure(first.message, first.detail) }
        return .failure("\(plan.failures.count) screens didn't switch", plan.failures.map(\.description).joined(separator: " · "))
    }

    /// Waits for the screens to show their desktops as Mission Control
    /// closes: for the first pressed, which closes it, then a moment for the
    /// rest, which may not take.
    private func settle(_ steps: [Step]) async {
        func shown(_ steps: ArraySlice<Step>) -> Bool {
            let showing = control.showing()
            return steps.allSatisfy { showing[$0.screen.identifier] == $0.space.id }
        }
        var deadline = Date().addingTimeInterval(patience)
        while !shown(steps.prefix(1)), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        deadline = Date().addingTimeInterval(min(patience, 0.5))
        while !shown(steps[...]), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}
