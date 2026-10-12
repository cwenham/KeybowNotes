import Foundation
import KeybowKit

/// Wi‑Fi and Bluetooth on and off from a key:
///
///   Wi‑Fi [Wi-Fi]
///   Bluetooth [Bluetooth]
///
/// `do` is toggle, on or off; else the label says — "Wi‑Fi off" — else it
/// toggles. Both keep the time to cancel: a stray press could drop a call,
/// or a Bluetooth keyboard and mouse. The keypad is on USB, so its key turns
/// Bluetooth back on.
public final class RadioModule: KeybowModule, @unchecked Sendable {
    public static let id = "radio"

    public let manifest = ModuleManifest(
        id: id, name: "Wi‑Fi and Bluetooth",
        actionTypes: [
            ModuleActionType(
                type: "wifi", title: "Wi‑Fi", keywords: ["Wi-Fi", "WiFi"], symbol: "wifi",
                fields: [RadioModule.doField("Wi‑Fi")]),
            ModuleActionType(
                type: "bluetooth", title: "Bluetooth", keywords: ["Bluetooth"], symbol: "dot.radiowaves.left.and.right",
                fields: [RadioModule.doField("Bluetooth", note: """
                    Off disconnects Bluetooth keyboards, mice and headphones until it's back on: the keypad, on \
                    USB, can turn it on again.
                    """)]),
        ])

    private static func doField(_ name: String, note: String = "") -> ModuleField {
        ModuleField(key: "do", title: "Do", kind: .choice(Switch.allCases.map(\.rawValue)),
                    hint: "else the label — On, Off — else toggle", help: """
            Turns \(name) on or off, or toggles it. Left out, a label saying On or Off decides, and anything else \
            toggles. \(note)
            Example: off
            """)
    }

    private let radios: RadioControl

    public init(radios: RadioControl = SystemRadios()) {
        self.radios = radios
    }

    public func start(host: ModuleHost) {}

    static func radio(_ type: String) -> Radio {
        type == "bluetooth" ? .bluetooth : .wifi
    }

    public func problem(with request: ModuleRequest) -> String? {
        Switch.asked(by: request, thing: Self.radio(request.type).title).problem
    }

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        let radio = Self.radio(request.type)
        let change = Switch.asked(by: request, thing: radio.title).0
        let goesOn = radios.isOn(radio).map { change.applied(to: $0) } ?? (change == .toggle ? nil : change == .on)
        let verb = goesOn.map { $0 ? "Turn on" : "Turn off" } ?? "Turn on or off"
        var details: [String] = []
        if radio == .bluetooth, goesOn != true { details.append("Bluetooth keyboards and mice disconnect") }
        return ModuleSummary(verb: verb, subject: radio.title, details: details)
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        let radio = Self.radio(request.type)
        let (change, problem) = Switch.asked(by: request, thing: radio.title)
        if let problem { return .failure(problem) }
        do {
            try await radios.allow(radio)
            guard let isOn = radios.isOn(radio) else {
                throw ModuleError(radio == .wifi ? "This Mac has no Wi‑Fi" : "Couldn't tell whether Bluetooth is on")
            }
            let on = change.applied(to: isOn)
            if on != isOn { try await radios.set(radio, on: on) }
            return Self.outcome(radio, on: on, already: on == isOn)
        } catch let error as ModuleError {
            return .failure(error.message, error.detail)
        } catch {
            return .failure("\(radio.title) didn't change", "\(error)")
        }
    }

    private static func outcome(_ radio: Radio, on: Bool, already: Bool = false) -> ActionOutcome {
        let detail = already ? "It already was"
            : radio == .bluetooth && !on ? "Its keyboards, mice and headphones are disconnected until it's back on" : nil
        return .success("\(radio.title) \(on ? "on" : "off")", detail)
    }
}
