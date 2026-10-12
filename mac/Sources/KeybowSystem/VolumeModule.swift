import Foundation
import KeybowKit

/// The volume from a key, like the keyboard's own volume keys:
///
///   Sound
///      1. Louder [Volume]
///      2. Quieter [Volume]
///      3. Mute [Volume]
///      4. Quiet [Volume, level: 20]
///
/// `do` is up, down, mute, unmute or toggle; else the label says — Up,
/// Louder, Down, Quieter, Mute, Unmute, 40% — and anything else mutes and
/// unmutes, as the Mute key does. `level` sets it, 0 to 100; `step` is how
/// far up or down, in percent: a sixteenth, as the keys go, unless it says.
/// Going up or down unmutes, as the keys do.
///
/// Core Audio's default output: the speakers, headphones, or whatever's
/// chosen in the menu bar. It needs no permission.
public final class VolumeModule: KeybowModule, @unchecked Sendable {
    public static let id = "volume"
    public static let type = "volume"

    enum Command: Equatable {
        case adjust(Adjustment)
        case mute(Switch)
    }

    public let manifest = ModuleManifest(
        id: id, name: "Volume",
        actionTypes: [
            ModuleActionType(
                type: type, title: "Volume", keywords: ["Volume"], symbol: "speaker.wave.2",
                fields: [
                    ModuleField(key: "do", title: "Do", kind: .choice(["up", "down", "mute", "unmute", "toggle"]),
                                hint: "else the label — Louder, Quieter, Mute — else toggle mute", help: """
                        What the key does: up, down, mute, unmute, or toggle — mute, or unmute if it's muted. \
                        Left out, the label says: Up, Louder, Down, Quieter, Mute (which toggles, as the key on \
                        the keyboard does), Unmute, or a level like 40%.
                        Example: up
                        """),
                    ModuleField(key: "level", title: "Level", kind: .number, hint: "0–100", help: """
                        Sets the volume to this, in percent, and unmutes.
                        Example: 30
                        """),
                    ModuleField(key: "step", title: "Step", kind: .number, hint: "percent — 6.25, as the keys go",
                                help: """
                        How far up or down one press goes, in percent. Left out, a sixteenth, as the volume keys go.
                        Example: 10
                        """),
                ]),
        ])

    private let sound: SoundControl

    public init(sound: SoundControl = CoreAudioSound()) {
        self.sound = sound
    }

    public func start(host: ModuleHost) {}

    /// What's asked for, and why it can't be, if it can't.
    static func command(_ request: ModuleRequest) -> (Command, problem: String?) {
        let (step, stepProblem) = Adjustment.step(request)
        if let text = request.field("level") {
            guard let level = Adjustment.level(text) else { return (.mute(.toggle), "“\(text)” isn't a volume: 0 to 100.") }
            return (.adjust(.to(level)), nil)
        }
        if let word = request.field("do") {
            switch word.lowercased() {
            case "up": return (.adjust(.up(by: step)), stepProblem)
            case "down": return (.adjust(.down(by: step)), stepProblem)
            case "mute": return (.mute(.on), nil)
            case "unmute": return (.mute(.off), nil)
            case "toggle": return (.mute(.toggle), nil)
            default: return (.mute(.toggle), "“\(word)” isn't something the volume does: up, down, mute, unmute or toggle.")
            }
        }
        let command = labelled(request.leaf, step: step) ?? .mute(.toggle)
        if case .adjust = command { return (command, stepProblem) }
        return (command, nil)
    }

    /// From a label: "Louder", "Volume up", "+", "Unmute", "40%".
    static func labelled(_ label: String, step: Double) -> Command? {
        let text = label.trimmingCharacters(in: .whitespaces)
        if let level = Self.percentage(in: text) { return .adjust(.to(level)) }
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        if text == "+" || !words.isDisjoint(with: ["up", "louder", "raise", "increase"]) { return .adjust(.up(by: step)) }
        if ["-", "−"].contains(text) || !words.isDisjoint(with: ["down", "quieter", "softer", "lower", "decrease"]) {
            return .adjust(.down(by: step))
        }
        if words.contains("unmute") { return .mute(.off) }
        if !words.isDisjoint(with: ["mute", "silence"]) { return .mute(.toggle) }
        return nil
    }

    /// "40", "40%", "Half — 50%" → the level; nil without one.
    static func percentage(in text: String) -> Double? {
        if let level = Adjustment.level(text) { return level }
        guard let range = text.range(of: #"\d+(\.\d+)?\s*%"#, options: .regularExpression) else { return nil }
        return Adjustment.level(String(text[range]).replacingOccurrences(of: " ", with: ""))
    }

    public func problem(with request: ModuleRequest) -> String? {
        Self.command(request).problem
    }

    /// On the press: a volume key that waited would feel broken.
    public func firesAtOnce(_ request: ModuleRequest) -> Bool { true }

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        let now = sound.volume(.output).map { "now \(Adjustment.percent($0))" }
        switch Self.command(request).0 {
        case .adjust(.up(let step)):
            return ModuleSummary(verb: "Turn up", subject: "the volume", details: ["by \(Adjustment.percent(step))"] + [now].compactMap { $0 })
        case .adjust(.down(let step)):
            return ModuleSummary(verb: "Turn down", subject: "the volume", details: ["by \(Adjustment.percent(step))"] + [now].compactMap { $0 })
        case .adjust(.to(let level)):
            return ModuleSummary(verb: "Set", subject: "the volume", details: ["to \(Adjustment.percent(level))"] + [now].compactMap { $0 })
        case .mute(let change):
            let verb = change == .on ? "Mute" : change == .off ? "Unmute" : sound.isMuted(.output) == true ? "Unmute" : "Mute"
            return ModuleSummary(verb: verb, subject: "the sound", details: sound.deviceName(.output).map { [$0] } ?? [])
        }
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        let (command, problem) = Self.command(request)
        if let problem { return .failure(problem) }
        let device = sound.deviceName(.output)
        do {
            switch command {
            case .adjust(let adjustment):
                guard let level = sound.volume(.output) else {
                    throw ModuleError("\(device ?? "This device") has no volume to set",
                                      "Its own controls set it — a monitor or TV over HDMI, say.")
                }
                let next = adjustment.applied(to: level)
                try sound.setVolume(next, .output)
                if sound.isMuted(.output) == true { try sound.setMuted(false, .output) }
                return .success("Volume \(Adjustment.percent(next))", device)
            case .mute(let change):
                guard let muted = sound.isMuted(.output) else {
                    throw ModuleError("\(device ?? "This device") can't be muted", "Turn it down instead: do: down, or level: 0.")
                }
                let mute = change.applied(to: muted)
                if mute != muted { try sound.setMuted(mute, .output) }
                let level = sound.volume(.output).map { "Volume \(Adjustment.percent($0))" }
                return .success(mute ? "Sound muted" : "Sound on", mute ? device : [level, device].compactMap { $0 }.joined(separator: " · "))
            }
        } catch let error as ModuleError {
            return .failure(error.message, error.detail)
        } catch {
            return .failure("The volume didn't change", "\(error)")
        }
    }
}
