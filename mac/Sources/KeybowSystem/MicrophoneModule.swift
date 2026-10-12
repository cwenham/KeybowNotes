import Foundation
import KeybowKit

/// The microphone muted and unmuted from a key — for calls:
///
///   Mic [Microphone]
///
/// `do` is toggle, mute or unmute; else the label — Mute, Unmute — else it
/// toggles. While it's muted the overlay and the menu bar say so, and the key
/// that leads to it breathes, whichever way it was muted.
///
/// It mutes the Mac's default input, so every app hears nothing. A device
/// that can't be muted is turned down to nothing instead, and back up to
/// where it was.
public final class MicrophoneModule: KeybowModule, @unchecked Sendable {
    public static let id = "microphone"
    public static let type = "microphone"

    public let manifest = ModuleManifest(
        id: id, name: "Microphone",
        actionTypes: [
            ModuleActionType(
                type: type, title: "Microphone", keywords: ["Microphone", "Mic"], symbol: "mic.slash",
                fields: [
                    ModuleField(key: "do", title: "Do", kind: .choice(["toggle", "mute", "unmute"]),
                                hint: "else the label — Unmute — else toggle", help: """
                        What the key does to the microphone: toggle, mute or unmute. Left out, a label saying \
                        Unmute unmutes, and anything else — Mute included — toggles.
                        Example: mute
                        """),
                ]),
        ])

    /// The level a device that can't be muted was at, to go back to.
    private struct State: Codable, Equatable {
        var levelBeforeMuting: Double?
    }

    private let sound: SoundControl
    private let lock = NSLock()
    private var state = State()
    private var host: ModuleHost?
    /// As last shown, so a status is only redrawn when it changes.
    private var shownMuted: Bool?

    public init(sound: SoundControl = CoreAudioSound()) {
        self.sound = sound
    }

    public func start(host: ModuleHost) {
        self.host = host
        if let data = host.load("state", for: Self.id), let saved = try? JSONDecoder().decode(State.self, from: data) {
            lock.withLock { state = saved }
        }
        sound.watch(.input) { [weak self] in self?.refreshStatus() }
    }

    /// Redraws the status if muting changed: by a key, the menu, the
    /// device's own button, or another app.
    private func refreshStatus() {
        let muted = isMuted()
        let changed = lock.withLock { () -> Bool in
            defer { shownMuted = muted }
            return shownMuted != muted
        }
        if changed { host?.statusChanged() }
    }

    private func save() {
        let data = lock.withLock { try? JSONEncoder().encode(state) }
        host?.save(data, as: "state", for: Self.id)
    }

    /// Muted: by its mute, or turned down to nothing. Nil without a microphone.
    func isMuted() -> Bool? {
        guard sound.deviceName(.input) != nil else { return nil }
        if let muted = sound.isMuted(.input) { return muted }
        return sound.volume(.input).map { $0 == 0 }
    }

    /// From `do:` — mute is on — else the label, else toggle.
    static func change(_ request: ModuleRequest) -> (Switch, problem: String?) {
        if let word = request.field("do") {
            switch word.lowercased() {
            case "mute", "on": return (.on, nil)
            case "unmute", "off": return (.off, nil)
            case "toggle": return (.toggle, nil)
            default: return (.toggle, "“\(word)” isn't something the microphone does: toggle, mute or unmute.")
            }
        }
        let words = Set(request.leaf.lowercased().split { !$0.isLetter }.map(String.init))
        return (words.contains("unmute") ? .off : .toggle, nil)
    }

    public func problem(with request: ModuleRequest) -> String? {
        Self.change(request).problem
    }

    /// On the press: someone's waiting to speak, or to stop being heard.
    public func firesAtOnce(_ request: ModuleRequest) -> Bool { true }

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        let mute = Self.change(request).0.applied(to: isMuted() ?? false)
        return ModuleSummary(verb: mute ? "Mute" : "Unmute", subject: "the microphone",
                             details: sound.deviceName(.input).map { [$0] } ?? [])
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        let (change, problem) = Self.change(request)
        if let problem { return .failure(problem) }
        guard let device = sound.deviceName(.input), let muted = isMuted() else {
            return .failure("There's no microphone", "Connect one, or choose one in System Settings → Sound.")
        }
        let mute = change.applied(to: muted)
        do {
            if mute != muted { try set(muted: mute) }
        } catch let error as ModuleError {
            return .failure(error.message, error.detail)
        } catch {
            return .failure("The microphone didn't \(mute ? "mute" : "unmute")", "\(error)")
        }
        refreshStatus()
        return .success(mute ? "Microphone muted" : "Microphone on", device)
    }

    private func set(muted: Bool) throws {
        if sound.isMuted(.input) != nil {
            try sound.setMuted(muted, .input)
            return
        }
        // No mute of its own: down to nothing, and back to where it was.
        if muted {
            let level = sound.volume(.input)
            try sound.setVolume(0, .input)
            lock.withLock { state.levelBeforeMuting = level }
        } else {
            let level = lock.withLock { state.levelBeforeMuting } ?? 0.75
            try sound.setVolume(level > 0 ? level : 0.75, .input)
            lock.withLock { state.levelBeforeMuting = nil }
        }
        save()
    }

    public func menuItems(now: Date) -> [ModuleMenuItem] {
        guard let muted = isMuted() else { return [] }
        return [ModuleMenuItem(id: muted ? "unmute" : "mute", title: muted ? "Unmute" : "Mute", isEnabled: true)]
    }

    public func performMenuItem(_ id: String, now: Date) -> ActionOutcome? {
        guard ["mute", "unmute"].contains(id) else { return nil }
        do {
            try set(muted: id == "mute")
        } catch let error as ModuleError {
            return .failure(error.message, error.detail)
        } catch {
            return .failure("The microphone didn't change", "\(error)")
        }
        refreshStatus()
        return .success(id == "mute" ? "Microphone muted" : "Microphone on")
    }

    /// Shown while it's muted.
    public func status(now: Date) -> ModuleStatus? {
        guard isMuted() == true else { return nil }
        return ModuleStatus(moduleID: Self.id, symbol: "mic.slash.fill", title: "Microphone", text: "muted",
                            detail: sound.deviceName(.input), lightsKeys: true)
    }
}
