import Foundation
import KeybowKit

/// Night Shift and dark mode from a key:
///
///   Night Shift [Night Shift]
///   Dark [Dark Mode]
///
/// `do` is toggle, on or off — for dark mode, dark or light too; else the
/// label says — "Night Shift off", "Light" — else it toggles.
public final class AppearanceModule: KeybowModule, @unchecked Sendable {
    public static let id = "appearance"

    public let manifest = ModuleManifest(
        id: id, name: "Appearance",
        actionTypes: [
            ModuleActionType(
                type: "nightShift", title: "Night Shift", keywords: ["Night Shift"], symbol: "moon.circle",
                fields: [
                    ModuleField(key: "do", title: "Do", kind: .choice(Switch.allCases.map(\.rawValue)),
                                hint: "else the label — On, Off — else toggle", help: """
                        Turns Night Shift on or off, or toggles it, until its schedule next changes it. Left out, \
                        a label saying On or Off decides, and anything else toggles.
                        Example: on
                        """),
                ]),
            ModuleActionType(
                type: "darkMode", title: "Dark mode", keywords: ["Dark Mode"], symbol: "circle.lefthalf.filled",
                fields: [
                    ModuleField(key: "do", title: "Do", kind: .choice(["toggle", "dark", "light"]),
                                hint: "else the label — Dark, Light — else toggle", help: """
                        Dark, light, or the other one. Left out, a label saying just Dark or Light decides, and \
                        anything else toggles. macOS asks once whether KeybowNotes may control System Events, \
                        which makes the change.
                        Example: dark
                        """),
                ]),
        ])

    private let control: AppearanceControl

    public init(control: AppearanceControl = SystemAppearance()) {
        self.control = control
    }

    public func start(host: ModuleHost) {}

    /// What's asked for, with dark as on.
    static func change(_ request: ModuleRequest) -> (Switch, problem: String?) {
        guard request.type == "darkMode" else { return Switch.asked(by: request, thing: "Night Shift") }
        let word = (request.field("do") ?? request.leaf).trimmingCharacters(in: .whitespaces).lowercased()
        switch word {
        case "dark": return (.on, nil)
        case "light": return (.off, nil)
        default: return Switch.asked(by: request, thing: "dark mode")
        }
    }

    public func problem(with request: ModuleRequest) -> String? {
        Self.change(request).problem
    }

    /// On the press: it's there to see, and the same key puts it back.
    public func firesAtOnce(_ request: ModuleRequest) -> Bool { true }

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        let change = Self.change(request).0
        if request.type == "darkMode" {
            let dark = change.applied(to: control.isDark())
            return ModuleSummary(verb: "Switch to", subject: dark ? "dark mode" : "light mode")
        }
        let on = (try? control.nightShift()).map { change.applied(to: $0) }
        return ModuleSummary(verb: on.map { $0 ? "Turn on" : "Turn off" } ?? "Turn on or off", subject: "Night Shift")
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        let (change, problem) = Self.change(request)
        if let problem { return .failure(problem) }
        do {
            if request.type == "darkMode" {
                let dark = change.applied(to: control.isDark())
                try await control.setDark(dark)
                return .quiet
            }
            let isOn = try control.nightShift()
            let on = change.applied(to: isOn)
            if on != isOn { try control.setNightShift(on) }
            return .success("Night Shift \(on ? "on" : "off")", on == isOn ? "It already was" : nil)
        } catch let error as ModuleError {
            return .failure(error.message, error.detail)
        } catch {
            return .failure("That didn't change", "\(error)")
        }
    }
}

/// Night Shift and dark mode. A protocol, so tests use made-up ones.
public protocol AppearanceControl: AnyObject, Sendable {
    func nightShift() throws -> Bool
    func setNightShift(_ on: Bool) throws
    func isDark() -> Bool
    func setDark(_ dark: Bool) async throws
}

/// Night Shift through CoreBrightness's `CBBlueLightClient`, as Control
/// Centre switches it — private, so looked up when first needed. Dark mode
/// through System Events, which is how Apple lets other apps change it.
public final class SystemAppearance: AppearanceControl, @unchecked Sendable {
    private let lock = NSLock()
    private var client: NSObject?

    public init() {}

    private func blueLight() throws -> NSObject {
        try lock.withLock {
            if let client { return client }
            let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            guard dlopen(path, RTLD_LAZY) != nil, let type = NSClassFromString("CBBlueLightClient") as? NSObject.Type else {
                throw ModuleError("Night Shift can't be switched from here", "macOS no longer offers the switch KeybowNotes uses.")
            }
            typealias Supports = @convention(c) (AnyClass, Selector) -> Bool
            let supports = NSSelectorFromString("supportsBlueLightReduction")
            if let method = class_getClassMethod(type, supports),
               !unsafeBitCast(method_getImplementation(method), to: Supports.self)(type, supports) {
                throw ModuleError("This Mac has no Night Shift")
            }
            let made = type.init()
            client = made
            return made
        }
    }

    public func nightShift() throws -> Bool {
        let client = try blueLight()
        typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let selector = NSSelectorFromString("getBlueLightStatus:")
        guard client.responds(to: selector) else { throw ModuleError("Couldn't tell whether Night Shift is on") }
        let get = unsafeBitCast(client.method(for: selector), to: GetStatus.self)
        // The status: active, enabled, sun schedule permitted, mode, the
        // schedule, flags. Room to spare, should it grow.
        var status = [UInt8](repeating: 0, count: 64)
        let read = status.withUnsafeMutableBytes { get(client, selector, $0.baseAddress!) }
        guard read else { throw ModuleError("Couldn't tell whether Night Shift is on") }
        return Self.isEnabled(status)
    }

    /// Whether a status says Night Shift is on now: its second byte.
    static func isEnabled(_ status: [UInt8]) -> Bool {
        status.count > 1 && status[1] != 0
    }

    public func setNightShift(_ on: Bool) throws {
        let client = try blueLight()
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Bool
        let selector = NSSelectorFromString("setEnabled:")
        guard client.responds(to: selector),
              unsafeBitCast(client.method(for: selector), to: SetEnabled.self)(client, selector, on) else {
            throw ModuleError("Night Shift didn't turn \(on ? "on" : "off")")
        }
    }

    public func isDark() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String == "Dark"
    }

    static let setDarkScript = """
        on run argv
            tell application "System Events" to tell appearance preferences to set dark mode to (item 1 of argv is "dark")
        end run
        """

    public func setDark(_ dark: Bool) async throws {
        let result: Subprocess.Result
        do {
            result = try await Osascript.run(Self.setDarkScript, [dark ? "dark" : "light"], timeout: 30)
        } catch {
            throw ModuleError("Couldn't start \(Osascript.path)", "\(error)")
        }
        guard result.succeeded else {
            if Osascript.isNotAllowed(result.errorText) {
                throw ModuleError("KeybowNotes isn't allowed to control System Events", Osascript.allowIt)
            }
            throw ModuleError("It didn't switch to \(dark ? "dark" : "light") mode", Osascript.reason(result.errorText))
        }
    }
}
