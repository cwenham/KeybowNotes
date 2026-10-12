import AppKit
import Foundation
import KeybowKit
import KeybowWindows

/// Screens brighter and dimmer from a key:
///
///   Screen
///      1. Brighter [Brightness]
///      2. Dimmer [Brightness]
///      3. Evening [Brightness, level: 30, screen: all]
///
/// `do` is up or down, else the label says — Brighter, Up, Dimmer, Darker,
/// Down, 40% — and `level` sets it, 0 to 100. `step` is how far, in percent:
/// a sixteenth, as the keys go, unless it says. `screen` is which: the one
/// under the pointer unless it says all, built-in, main, a number from the
/// left, or part of a screen's name.
public final class BrightnessModule: KeybowModule, @unchecked Sendable {
    public static let id = "brightness"
    public static let type = "brightness"

    public let manifest = ModuleManifest(
        id: id, name: "Brightness",
        actionTypes: [
            ModuleActionType(
                type: type, title: "Screen brightness", keywords: ["Brightness"], symbol: "sun.max",
                fields: [
                    ModuleField(key: "do", title: "Do", kind: .choice(["up", "down"]),
                                hint: "else the label — Brighter, Dimmer", help: """
                        Brighter or dimmer: up or down. Left out, the label says — Brighter, Up, Dimmer, Darker, \
                        Down, or a level like 40%.
                        Example: up
                        """),
                    ModuleField(key: "level", title: "Level", kind: .number, hint: "0–100", help: """
                        Sets the brightness to this, in percent.
                        Example: 30
                        """),
                    ModuleField(key: "step", title: "Step", kind: .number, hint: "percent — 6.25, as the keys go",
                                help: """
                        How far one press goes, in percent. Left out, a sixteenth, as the brightness keys go.
                        Example: 10
                        """),
                    ModuleField(key: "screen", title: "Screen", hint: "all, built-in, main, 2, or a name — else the pointer's",
                                help: """
                        Which screen: all of them, built-in, main (the one with the menu bar), a number counting \
                        from the left, or part of a screen's name. Left out, the one the pointer is on. Apple's \
                        screens are set as the brightness keys set them; others over their cable (DDC/CI), on an \
                        Intel Mac, when the monitor allows it.
                        Example: all
                        """, offersChoices: true),
                ]),
        ])

    private let control: BrightnessControl
    /// The screens and the pointer: `DisplayInfo.current` unless a test says.
    private let screens: @Sendable () async -> (displays: [DisplayInfo], pointer: CGPoint)

    public init(control: BrightnessControl = SystemBrightness(),
                screens: (@Sendable () async -> (displays: [DisplayInfo], pointer: CGPoint))? = nil) {
        self.control = control
        self.screens = screens ?? { await MainActor.run { DisplayInfo.current() } }
    }

    public func start(host: ModuleHost) {}

    static func adjustment(_ request: ModuleRequest) -> (Adjustment?, problem: String?) {
        let (step, stepProblem) = Adjustment.step(request)
        if let text = request.field("level") {
            guard let level = Adjustment.level(text) else { return (nil, "“\(text)” isn't a brightness: 0 to 100.") }
            return (.to(level), nil)
        }
        if let word = request.field("do") {
            switch word.lowercased() {
            case "up", "brighter": return (.up(by: step), stepProblem)
            case "down", "dimmer", "darker": return (.down(by: step), stepProblem)
            default: return (nil, "“\(word)” isn't something brightness does: up or down.")
            }
        }
        let label = request.leaf.trimmingCharacters(in: .whitespaces)
        if let level = VolumeModule.percentage(in: label) { return (.to(level), nil) }
        let words = Set(label.lowercased().split { !$0.isLetter }.map(String.init))
        if label == "+" || !words.isDisjoint(with: ["up", "brighter", "brighten", "raise", "increase", "more"]) {
            return (.up(by: step), stepProblem)
        }
        if ["-", "−"].contains(label) || !words.isDisjoint(with: ["down", "dimmer", "dim", "darker", "darken", "lower", "decrease", "less"]) {
            return (.down(by: step), stepProblem)
        }
        return (nil, "Say which way: do: up or down, a level — or a label like Brighter or Dimmer.")
    }

    /// The screens `spec` names, the pointer's when it names none: all,
    /// built-in, and what the window action's `screen` takes — main, next,
    /// previous, a number from the left, part of a name.
    static func chosen(_ spec: String?, among displays: [DisplayInfo], pointer: CGPoint) throws -> [DisplayInfo] {
        let screens = displays.map { WindowGeometry.Screen(name: $0.name, frame: $0.frame, visible: $0.frame) }
        guard !screens.isEmpty else { throw ModuleError("No screen is connected") }
        let atPointer = WindowGeometry.screen(holding: CGRect(origin: pointer, size: CGSize(width: 1, height: 1)), in: screens)
            ?? screens[0]
        let text = (spec ?? "").trimmingCharacters(in: .whitespaces)
        switch text.isEmpty ? "" : text.lowercased().filter({ $0.isLetter || $0.isNumber }) {
        case "", "pointer", "mouse", "cursor", "this", "current", "same":
            return [displays[screens.firstIndex(of: atPointer) ?? 0]]
        case "all", "every", "each", "allscreens", "everyscreen":
            return WindowGeometry.ordered(screens).compactMap { screen in screens.firstIndex(of: screen).map { displays[$0] } }
        case "builtin", "internal":
            let builtIn = displays.filter(\.isBuiltIn)
            guard !builtIn.isEmpty else { throw ModuleError("This Mac has no built-in screen") }
            return builtIn
        default:
            let screen = try WindowGeometry.screen(text, from: atPointer, in: screens)
            return [displays[screens.firstIndex(of: screen) ?? 0]]
        }
    }

    public func problem(with request: ModuleRequest) -> String? {
        Self.adjustment(request).problem
    }

    /// On the press, like the brightness keys.
    public func firesAtOnce(_ request: ModuleRequest) -> Bool { true }

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        let screen = request.field("screen").map { Int($0) != nil ? "screen \($0)" : "\($0) screen" }
            ?? "the screen under the pointer"
        switch Self.adjustment(request).0 {
        case .up(let step)?: return ModuleSummary(verb: "Brighten", subject: screen, details: ["by \(Adjustment.percent(step))"])
        case .down(let step)?: return ModuleSummary(verb: "Dim", subject: screen, details: ["by \(Adjustment.percent(step))"])
        case .to(let level)?: return ModuleSummary(verb: "Set the brightness of", subject: screen, details: ["to \(Adjustment.percent(level))"])
        case nil: return ModuleSummary(verb: "Set the brightness of", subject: screen)
        }
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        let (adjustment, problem) = Self.adjustment(request)
        guard let adjustment else { return .failure(problem ?? "Say which way: up or down.") }
        if let problem { return .failure(problem) }
        let (displays, pointer) = await screens()
        let chosen: [DisplayInfo]
        do {
            chosen = try Self.chosen(request.field("screen"), among: displays, pointer: pointer)
        } catch let error as ModuleError {
            return .failure(error.message, error.detail)
        } catch {
            return .failure("Couldn't find the screen", "\(error)")
        }
        var done: [(DisplayInfo, Double)] = []
        var failures: [ModuleError] = []
        for display in chosen {
            do {
                let level = adjustment.applied(to: try control.level(of: display))
                try control.setLevel(level, of: display)
                done.append((display, level))
            } catch let error as ModuleError {
                failures.append(error)
            } catch {
                failures.append(ModuleError("\(display.name)'s brightness didn't change", "\(error)"))
            }
        }
        if done.isEmpty, let first = failures.first { return .failure(first.message, first.detail) }
        if done.count == 1, failures.isEmpty { return .success("Brightness \(Adjustment.percent(done[0].1))", done[0].0.name) }
        let set = done.map { "\($0.0.name) \(Adjustment.percent($0.1))" }.joined(separator: " · ")
        let missed = failures.map(\.message).joined(separator: "; ")
        return .success("Brightness \(adjustment.word)", missed.isEmpty ? set : "\(set) — \(missed)")
    }

    public func choices(for field: String, type: String, fields: [String: String]) async throws -> [FieldChoice] {
        guard field == "screen" else { return [] }
        let (displays, _) = await screens()
        let screens = displays.map { WindowGeometry.Screen(name: $0.name, frame: $0.frame, visible: $0.frame) }
        let numbered = WindowGeometry.ordered(screens).enumerated().map { index, screen in
            FieldChoice(String(index + 1), title: "\(index + 1) — \(screen.name)")
        }
        return [FieldChoice("pointer", title: "The one under the pointer"), FieldChoice("all", title: "All screens"),
                FieldChoice("built-in", title: "Built-in"), FieldChoice("main", title: "Main — with the menu bar")]
            + numbered
    }
}

extension Adjustment {
    /// "up", "down", "set": for saying what was done to several screens.
    var word: String {
        switch self {
        case .up: return "up"
        case .down: return "down"
        case .to(let level): return "set to \(Adjustment.percent(level))"
        }
    }
}
