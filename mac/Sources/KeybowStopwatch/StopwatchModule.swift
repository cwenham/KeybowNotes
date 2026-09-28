import Foundation
import KeybowKit

/// A stopwatch on the keypad. Start, stop, lap and reset it from keys marked
/// `[Stopwatch]`; while it has a time it shows on the overlay and in the menu
/// bar, and while it runs the key that leads to it breathes. Its time is
/// offered to every action as `{{stopwatch}}`, so a note can record it.
///
/// Built only on the module interface in KeybowKit. Other modules can drive it
/// with `perform(_:at:)` and read it with `reading(at:)`, finding it through
/// `ModuleRegistry.shared.module(id: StopwatchModule.id)`.
public final class StopwatchModule: KeybowModule, @unchecked Sendable {
    public static let id = "stopwatch"

    public enum Command: String, CaseIterable, Sendable {
        /// Start if stopped, stop if running: one key does both.
        case toggle, start, stop, lap, reset

        /// From a `do:` value or a leaf's label: "Start", "Pause", "Split"…
        public init?(word: String) {
            switch word.lowercased().trimmingCharacters(in: .whitespaces) {
            case "toggle", "start/stop", "startstop", "start / stop", "stopwatch": self = .toggle
            case "start", "go", "resume": self = .start
            case "stop", "pause": self = .stop
            case "lap", "split": self = .lap
            case "reset", "clear": self = .reset
            default: return nil
            }
        }
    }

    public struct Reading: Equatable, Sendable {
        public let elapsed: TimeInterval
        public let isRunning: Bool
        /// The time at each lap, from the start.
        public let laps: [TimeInterval]
    }

    public let manifest = ModuleManifest(id: id, name: "Stopwatch", actionTypes: [
        ModuleActionType(
            type: "stopwatch", title: "Stopwatch", keywords: ["Stopwatch"], symbol: "stopwatch",
            fields: [ModuleField(key: "do", title: "Do", kind: .choice(Command.allCases.map(\.rawValue)),
                                 hint: "from the label — Start, Stop, Lap, Reset — else toggle",
                                 help: """
                                     What the key does to the stopwatch. Inherit lets the label decide — \
                                     Start, Stop, Pause, Lap, Split, Reset — and anything else starts or stops it.
                                     Example: do: lap
                                     """)]
        ),
    ])

    private struct State: Codable, Equatable {
        var runningSince: Date?
        /// Time from earlier runs, before the current one.
        var banked: TimeInterval = 0
        var laps: [TimeInterval] = []

        func elapsed(at now: Date) -> TimeInterval {
            banked + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
        }
    }

    private let lock = NSLock()
    private var state = State()
    private var host: ModuleHost?

    public init() {}

    // MARK: - For other modules

    public func reading(at now: Date = Date()) -> Reading {
        let state = lock.withLock { self.state }
        return Reading(elapsed: state.elapsed(at: now), isRunning: state.runningSince != nil, laps: state.laps)
    }

    /// Does it, and says what happened.
    @discardableResult
    public func perform(_ command: Command, at now: Date = Date()) -> ActionOutcome {
        let outcome: ActionOutcome = lock.withLock {
            let elapsed = state.elapsed(at: now)
            switch command {
            case .toggle:
                return state.runningSince == nil ? start(at: now, elapsed: elapsed) : stop(at: now, elapsed: elapsed)
            case .start:
                return start(at: now, elapsed: elapsed)
            case .stop:
                return stop(at: now, elapsed: elapsed)
            case .lap:
                guard state.runningSince != nil else {
                    return .success("The stopwatch isn't running", elapsed > 0 ? "Stopped at \(Self.format(elapsed))" : nil)
                }
                let split = elapsed - (state.laps.last ?? 0)
                state.laps.append(elapsed)
                return .success("Lap \(state.laps.count): \(Self.format(split))", "\(Self.format(elapsed)) in all")
            case .reset:
                state = State()
                return .success("Stopwatch reset", elapsed > 0 ? "It had \(Self.format(elapsed))" : nil)
            }
        }
        save()
        host?.statusChanged()
        return outcome
    }

    /// Called with the lock held.
    private func start(at now: Date, elapsed: TimeInterval) -> ActionOutcome {
        guard state.runningSince == nil else {
            return .success("The stopwatch is already running", "\(Self.format(elapsed)) so far")
        }
        state.runningSince = now
        return .success("Stopwatch started", elapsed > 0 ? "Carrying on from \(Self.format(elapsed))" : nil)
    }

    /// Called with the lock held.
    private func stop(at now: Date, elapsed: TimeInterval) -> ActionOutcome {
        guard state.runningSince != nil else {
            return .success("The stopwatch isn't running", elapsed > 0 ? "Stopped at \(Self.format(elapsed))" : nil)
        }
        state.banked = elapsed
        state.runningSince = nil
        let laps = state.laps.count
        return .success("Stopwatch stopped at \(Self.format(elapsed))", laps > 0 ? "\(laps) lap\(laps == 1 ? "" : "s")" : nil)
    }

    // MARK: - KeybowModule

    public func start(host: ModuleHost) {
        self.host = host
        guard let data = host.load("state", for: Self.id),
              let saved = try? JSONDecoder().decode(State.self, from: data) else { return }
        lock.withLock { state = saved }
    }

    private func save() {
        let data = lock.withLock { try? JSONEncoder().encode(state) }
        host?.save(data, as: "state", for: Self.id)
    }

    /// The command a request means: `do:`, else the leaf's label, else toggle.
    static func command(for request: ModuleRequest) -> Command? {
        if let word = request.field("do") { return Command(word: word) }
        return Command(word: request.leaf) ?? .toggle
    }

    public func problem(with request: ModuleRequest) -> String? {
        guard Self.command(for: request) == nil, let word = request.field("do") else { return nil }
        return "“\(word)” isn't something the stopwatch does: toggle, start, stop, lap or reset."
    }

    /// Start, stop and lap happen on the press: a stopwatch that waited a
    /// second to start would be a second out. Reset keeps the time to cancel,
    /// so a stray press can't wipe a time.
    public func firesAtOnce(_ request: ModuleRequest) -> Bool {
        (Self.command(for: request) ?? .toggle) != .reset
    }

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        let reading = reading(at: now)
        let time = Self.format(reading.elapsed)
        switch Self.command(for: request) ?? .toggle {
        case .toggle where reading.isRunning, .stop:
            return ModuleSummary(verb: "Stop stopwatch", subject: "Stopwatch",
                                 details: reading.isRunning ? ["at \(time)"] : ["it isn't running"])
        case .toggle, .start:
            return ModuleSummary(verb: "Start stopwatch", subject: "Stopwatch",
                                 details: reading.isRunning ? ["already running"]
                                     : reading.elapsed > 0 ? ["carrying on from \(time)"] : [])
        case .lap:
            return ModuleSummary(verb: "Lap", subject: "Lap \(reading.laps.count + 1)",
                                 details: reading.isRunning ? [] : ["it isn't running"])
        case .reset:
            return ModuleSummary(verb: "Reset stopwatch", subject: "Stopwatch",
                                 details: reading.elapsed > 0 ? ["clears \(time)"] : [])
        }
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        guard let command = Self.command(for: request) else {
            return .failure(problem(with: request) ?? "The stopwatch didn't understand that.")
        }
        return perform(command, at: now)
    }

    /// Stop, lap and reset without a key for them: a stopwatch started from a
    /// key that only starts it can't otherwise be stopped.
    public func menuItems(now: Date) -> [ModuleMenuItem] {
        let reading = reading(at: now)
        return [
            ModuleMenuItem(id: Command.stop.rawValue, title: "Stop", isEnabled: reading.isRunning),
            ModuleMenuItem(id: Command.lap.rawValue, title: "Lap", isEnabled: reading.isRunning),
            ModuleMenuItem(id: Command.reset.rawValue, title: "Reset",
                           isEnabled: reading.isRunning || reading.elapsed > 0),
        ]
    }

    public func performMenuItem(_ id: String, now: Date) -> ActionOutcome? {
        Command(rawValue: id).map { perform($0, at: now) }
    }

    /// `{{stopwatch}}` "3:12", `{{stopwatch.seconds}}` "192", `{{stopwatch.laps}}` "1:05, 2:07".
    public func values(now: Date) -> [String: String] {
        let reading = reading(at: now)
        return [
            "stopwatch": Self.format(reading.elapsed),
            "stopwatch.seconds": String(Int(reading.elapsed)),
            "stopwatch.laps": reading.laps.map(Self.format).joined(separator: ", "),
        ]
    }

    /// Shown while there's a time to show: running, or stopped but not reset.
    public func status(now: Date) -> ModuleStatus? {
        let state = lock.withLock { self.state }
        let elapsed = state.elapsed(at: now)
        guard state.runningSince != nil || elapsed > 0 else { return nil }
        var detail: String?
        if let last = state.laps.last {
            let previous = state.laps.dropLast().last ?? 0
            detail = "Lap \(state.laps.count): \(Self.format(last - previous))"
        }
        if state.runningSince == nil { detail = [detail, "stopped"].compactMap { $0 }.joined(separator: " · ") }
        return ModuleStatus(
            moduleID: Self.id, symbol: "stopwatch", title: "Stopwatch",
            // Fixed while it runs — when it would have started, had it never paused.
            countingFrom: state.runningSince.map { $0.addingTimeInterval(-state.banked) },
            // Only when stopped: a running clock is shown live from countingFrom.
            text: state.runningSince == nil ? Self.format(elapsed) : "",
            detail: detail, lightsKeys: state.runningSince != nil)
    }

    /// 192 → "3:12"; 3723 → "1:02:03".
    public static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
