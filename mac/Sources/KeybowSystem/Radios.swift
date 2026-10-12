import AppKit
import CoreBluetooth
import CoreWLAN
import Foundation
import KeybowKit

public enum Radio: String, CaseIterable, Sendable {
    case wifi, bluetooth

    public var title: String { self == .wifi ? "Wi‑Fi" : "Bluetooth" }
}

/// Turns the Mac's radios on and off. A protocol, so tests use made-up ones.
public protocol RadioControl: AnyObject, Sendable {
    /// Nil when it can't be known: without permission, or without the radio.
    func isOn(_ radio: Radio) -> Bool?
    /// Asks permission to switch it, if it must and hasn't yet; throws when
    /// it isn't given.
    func allow(_ radio: Radio) async throws
    /// Turns it on or off, and returns once it has.
    func set(_ radio: Radio, on: Bool) async throws
}

/// Wi‑Fi through CoreWLAN; Bluetooth through IOBluetooth's own switch, as
/// `blueutil` does, since there's no public way. Bluetooth needs permission
/// (Privacy & Security → Bluetooth), asked for the first time it's used.
public final class SystemRadios: RadioControl, @unchecked Sendable {
    public init() {}

    public func isOn(_ radio: Radio) -> Bool? {
        switch radio {
        case .wifi:
            return CWWiFiClient.shared().interface()?.powerOn()
        case .bluetooth:
            guard CBManager.authorization == .allowedAlways, let switches = BluetoothSwitch.shared else { return nil }
            return switches.isOn
        }
    }

    public func allow(_ radio: Radio) async throws {
        if radio == .bluetooth { try await BluetoothPermission.ask() }
    }

    public func set(_ radio: Radio, on: Bool) async throws {
        switch radio {
        case .wifi:
            guard let interface = CWWiFiClient.shared().interface() else { throw ModuleError("This Mac has no Wi‑Fi") }
            do {
                try interface.setPower(on)
            } catch {
                throw ModuleError("Wi‑Fi didn't turn \(on ? "on" : "off")", error.localizedDescription)
            }
        case .bluetooth:
            try await BluetoothPermission.ask()
            guard let switches = BluetoothSwitch.shared else {
                throw ModuleError("Bluetooth can't be switched from here", "macOS no longer offers the switch KeybowNotes uses.")
            }
            switches.isOn = on
            // It takes a moment: wait to see it happen, up to five seconds.
            for _ in 0..<50 where switches.isOn != on {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard switches.isOn == on else {
                throw ModuleError("Bluetooth didn't turn \(on ? "on" : "off")",
                                  "Check KeybowNotes is allowed in System Settings → Privacy & Security → Bluetooth.")
            }
        }
    }
}

/// IOBluetooth's power switch: private functions, looked up when first needed.
private final class BluetoothSwitch: @unchecked Sendable {
    private typealias Get = @convention(c) () -> Int32
    private typealias Set = @convention(c) (Int32) -> Void
    private let get: Get
    private let set: Set

    static let shared: BluetoothSwitch? = {
        let path = "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth"
        guard let handle = dlopen(path, RTLD_LAZY),
              let get = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState"),
              let set = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") else { return nil }
        return BluetoothSwitch(get: unsafeBitCast(get, to: Get.self), set: unsafeBitCast(set, to: Set.self))
    }()

    private init(get: Get, set: Set) {
        self.get = get
        self.set = set
    }

    var isOn: Bool {
        get { get() != 0 }
        set { set(newValue ? 1 : 0) }
    }
}

/// Bluetooth permission, asked for through Core Bluetooth: starting a central
/// manager raises macOS's prompt the first time. The app comes forward, so
/// the prompt isn't hidden behind other windows.
@MainActor
private final class BluetoothPermission: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var waiting: CheckedContinuation<Void, Never>?

    static func ask() async throws {
        // Without this key in Info.plist, macOS stops the app on the spot.
        guard Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil else {
            throw ModuleError("This copy of KeybowNotes can't use Bluetooth",
                              "It needs the installed app's Info.plist: build it with scripts/build-app.sh.")
        }
        if CBManager.authorization == .notDetermined {
            await BluetoothPermission().prompt()
        }
        switch CBManager.authorization {
        case .allowedAlways:
            return
        case .notDetermined:
            throw ModuleError("Bluetooth wasn't switched", "macOS asked whether KeybowNotes may use Bluetooth: allow it, then press again.")
        default:
            throw ModuleError("KeybowNotes isn't allowed to use Bluetooth",
                              "Allow it in System Settings → Privacy & Security → Bluetooth.")
        }
    }

    private func prompt() async {
        NSApp?.activate()
        await withCheckedContinuation { continuation in
            waiting = continuation
            manager = CBCentralManager(delegate: self, queue: .main)
            // Two minutes to answer, as with Location.
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.finish() }
        }
    }

    private func finish() {
        waiting?.resume()
        waiting = nil
        manager = nil
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if CBManager.authorization != .notDetermined { finish() }
        }
    }
}
