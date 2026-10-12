import Foundation
import IOKit.pwr_mgt
import KeybowKit

/// Keeps the Mac and its screens awake, as `caffeinate -d` does, until the key
/// is pressed again or for a while:
///
///   Stay awake [Stay Awake]
///   For an hour [Stay Awake, duration: 1h]
///
/// `do` is toggle, on or off; else the label — On, Off — else it toggles.
/// `duration` is how long, or until when — 30m, 1h 30m, 16:30 — else the
/// label, if it says one; else until it's turned off. While it holds, the
/// overlay and the menu bar say so, its key breathes, and the menu has Allow
/// Sleep. It carries on through a restart of the app.
public final class StayAwakeModule: KeybowModule, @unchecked Sendable {
    public static let id = "awake"
    public static let type = "stayAwake"

    public let manifest = ModuleManifest(
        id: id, name: "Stay Awake",
        actionTypes: [
            ModuleActionType(
                type: type, title: "Stay awake", keywords: ["Stay Awake", "Keep Awake"], symbol: "cup.and.saucer",
                fields: [
                    ModuleField(key: "do", title: "Do", kind: .choice(Switch.allCases.map(\.rawValue)),
                                hint: "else the label — On, Off — else toggle", help: """
                        Keeps the Mac and its screens from sleeping, lets them sleep again, or toggles. Left out, a \
                        label saying On or Off decides, and anything else toggles.
                        Example: on
                        """),
                    ModuleField(key: "duration", title: "For", hint: "30m, 1h, 16:30 — else until it's turned off",
                                help: """
                        How long to stay awake, or until when. Left out, a label like “1 hour” says, else until \
                        it's turned off. Pressing it again while it's on, with a duration, starts the time again.
                        Examples: 45m · 2h · 17:30
                        """),
                ]),
        ])

    private struct State: Codable, Equatable {
        var since: Date
        var until: Date?
    }

    private let blocker: SleepBlocker
    private let lock = NSLock()
    private var state: State?
    private var host: ModuleHost?
    private var timer: DispatchSourceTimer?

    public init(blocker: SleepBlocker = PowerAssertion()) {
        self.blocker = blocker
    }

    /// Picks up where it was, unless its time ran out while the app was closed.
    public func start(host: ModuleHost) {
        self.host = host
        guard let data = host.load("state", for: Self.id), let saved = try? JSONDecoder().decode(State.self, from: data) else {
            return
        }
        if let until = saved.until, until <= Date() {
            host.save(nil, as: "state", for: Self.id)
            return
        }
        hold(saved)
    }

    /// Holds the Mac awake as `state` says, ending when it says.
    private func hold(_ state: State) {
        lock.withLock {
            self.state = state
            blocker.hold()
            timer?.cancel()
            timer = nil
            guard let until = state.until else { return }
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(wallDeadline: .now() + max(0, until.timeIntervalSinceNow))
            timer.setEventHandler { [weak self] in self?.release(endingAt: until) }
            timer.resume()
            self.timer = timer
        }
        save()
        host?.statusChanged()
    }

    /// Lets it sleep again — when held until `endingAt`, only if it still is,
    /// and not since held again.
    private func release(endingAt end: Date? = nil) {
        let released: Bool = lock.withLock {
            guard let state, end == nil || state.until == end else { return false }
            self.state = nil
            blocker.release()
            timer?.cancel()
            timer = nil
            return true
        }
        guard released else { return }
        save()
        host?.statusChanged()
    }

    private func save() {
        let data = lock.withLock { state.flatMap { try? JSONEncoder().encode($0) } }
        host?.save(data, as: "state", for: Self.id)
    }

    var isHolding: Bool { lock.withLock { state != nil } }

    /// How long a request asks for: `duration`, else its label if that's a
    /// length or a time, else nil for until it's turned off.
    static func length(_ request: ModuleRequest, now: Date) -> (TimeInterval?, problem: String?) {
        if let text = request.field("duration") {
            guard let length = DateExpression.timerLength(text, now: now), length > 0 else {
                return (nil, "“\(text)” isn't a length or a time: 30m, 1h 30m, 16:30.")
            }
            return (length, nil)
        }
        return (DateExpression.timerLength(request.leaf, now: now).flatMap { $0 > 0 ? $0 : nil }, nil)
    }

    public func problem(with request: ModuleRequest) -> String? {
        Switch.asked(by: request, thing: "staying awake").problem ?? Self.length(request, now: Date()).problem
    }

    /// On the press: it's undone by the same key.
    public func firesAtOnce(_ request: ModuleRequest) -> Bool { true }

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        let holding = isHolding
        let length = Self.length(request, now: now).0
        let on = Switch.asked(by: request, thing: "staying awake").0.applied(to: holding)
        guard on else { return ModuleSummary(verb: "Let", subject: "the Mac sleep again") }
        let details = length.map { ["for \(DateExpression.describe(seconds: $0))"] } ?? ["until it's turned off"]
        return ModuleSummary(verb: "Keep", subject: "the Mac awake", details: details)
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        let (change, problem) = Switch.asked(by: request, thing: "staying awake")
        if let problem { return .failure(problem) }
        let (length, lengthProblem) = Self.length(request, now: now)
        if let lengthProblem { return .failure(lengthProblem) }
        let holding = isHolding
        // On again with a length starts the time again; toggled, it lets go.
        guard change.applied(to: holding) else {
            guard holding else { return .success("The Mac can sleep", "It wasn't being kept awake") }
            release()
            return .success("The Mac can sleep again")
        }
        if holding, length == nil, change == .on { return .success("Already staying awake", Self.untilText(lock.withLock { state?.until })) }
        let until = length.map { now.addingTimeInterval($0) }
        hold(State(since: now, until: until))
        return .success("Staying awake", Self.untilText(until))
    }

    /// "Until 16:30", or "Until it's turned off".
    static func untilText(_ until: Date?) -> String {
        until.map { "Until \(time($0))" } ?? "Until it's turned off"
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        return formatter.string(from: date)
    }

    public func menuItems(now: Date) -> [ModuleMenuItem] {
        let holding = isHolding
        return [
            ModuleMenuItem(id: "on", title: "Stay Awake", isEnabled: !holding),
            ModuleMenuItem(id: "off", title: "Allow Sleep", isEnabled: holding),
        ]
    }

    public func performMenuItem(_ id: String, now: Date) -> ActionOutcome? {
        switch id {
        case "on":
            hold(State(since: now, until: nil))
            return .success("Staying awake", Self.untilText(nil))
        case "off":
            release()
            return .success("The Mac can sleep again")
        default:
            return nil
        }
    }

    /// Shown while it's holding the Mac awake.
    public func status(now: Date) -> ModuleStatus? {
        guard let state = lock.withLock({ self.state }) else { return nil }
        return ModuleStatus(moduleID: Self.id, symbol: "cup.and.saucer.fill", title: "Stay awake",
                            text: state.until.map { "until \(Self.time($0))" } ?? "on", lightsKeys: true)
    }
}

/// Holds the Mac awake. A protocol, so tests don't.
public protocol SleepBlocker: AnyObject, Sendable {
    /// Holds it, if it isn't already.
    func hold()
    func release()
}

/// A power assertion that keeps the screens on, and so the Mac: what
/// `caffeinate -d` takes. It ends with the process, so a crash can't leave
/// the Mac awake for good. `pmset -g assertions` lists it.
public final class PowerAssertion: SleepBlocker, @unchecked Sendable {
    private let lock = NSLock()
    private var assertion: IOPMAssertionID?

    public init() {}

    public func hold() {
        lock.withLock {
            guard assertion == nil else { return }
            var id = IOPMAssertionID(0)
            let made = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                   IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                   "KeybowNotes: Stay Awake" as CFString, &id)
            if made == kIOReturnSuccess { assertion = id }
        }
    }

    public func release() {
        lock.withLock {
            if let assertion { IOPMAssertionRelease(assertion) }
            assertion = nil
        }
    }
}
