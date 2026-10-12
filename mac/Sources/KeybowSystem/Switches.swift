import Foundation
import KeybowKit

/// On, off, or the other way from how it is: what a key does to something
/// that's either — Wi‑Fi, Night Shift, staying awake.
public enum Switch: String, CaseIterable, Sendable {
    case toggle, on, off

    /// From a `do:` value or a label's words: "On", "Wi‑Fi off", "Disable",
    /// "Toggle". Nil when they say none of them, so a plain "Wi‑Fi" toggles.
    public init?(words text: String) {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        if !words.isDisjoint(with: ["toggle", "switch", "flip"]) {
            self = .toggle
        } else if !words.isDisjoint(with: ["off", "disable", "disabled", "stop", "end"]) {
            self = .off
        } else if !words.isDisjoint(with: ["on", "enable", "enabled", "start"]) {
            self = .on
        } else {
            return nil
        }
    }

    /// What a request asks for: `do:`, else the label, else toggle; and why
    /// not, when `do:` says something else.
    static func asked(by request: ModuleRequest, thing: String) -> (Switch, problem: String?) {
        if let word = request.field("do") {
            guard let named = Switch(rawValue: word.lowercased()) ?? Switch(words: word) else {
                return (.toggle, "“\(word)” isn't something \(thing) does: toggle, on or off.")
            }
            return (named, nil)
        }
        return (Switch(words: request.leaf) ?? .toggle, nil)
    }

    /// Where it ends up, from where it is.
    public func applied(to isOn: Bool) -> Bool {
        switch self {
        case .toggle: return !isOn
        case .on: return true
        case .off: return false
        }
    }
}

/// A level that goes up and down, 0 to 1: the volume, a screen's brightness.
/// What a key does to it.
public enum Adjustment: Equatable, Sendable {
    case up(by: Double)
    case down(by: Double)
    /// To a level, 0 to 1.
    case to(Double)

    /// A step of the keyboard's own volume and brightness keys: a sixteenth.
    public static let keyStep = 1.0 / 16

    /// The level it leaves, from `level`, kept within 0 and 1.
    public func applied(to level: Double) -> Double {
        let next: Double
        switch self {
        case .up(let step): next = level + step
        case .down(let step): next = level - step
        case .to(let target): next = target
        }
        return min(max(next, 0), 1)
    }

    /// "56%"
    public static func percent(_ level: Double) -> String {
        "\(Int((level * 100).rounded()))%"
    }

    /// A percentage as written — "40", "40%", "12.5" — as a level; nil when
    /// it isn't one, or is outside 0 to 100.
    static func level(_ text: String) -> Double? {
        var number = text.trimmingCharacters(in: .whitespaces)
        if number.hasSuffix("%") { number.removeLast() }
        guard let value = Double(number.trimmingCharacters(in: .whitespaces)), (0...100).contains(value) else { return nil }
        return value / 100
    }

    /// The step, from a `step:` percentage, else the keys' own.
    static func step(_ request: ModuleRequest) -> (Double, problem: String?) {
        guard let text = request.field("step") else { return (keyStep, nil) }
        guard let step = level(text), step > 0 else {
            return (keyStep, "“\(text)” isn't a step: a percentage, more than 0 and up to 100.")
        }
        return (step, nil)
    }
}
