import Foundation
import IOKit

/// Where a USB device is plugged in, as macOS numbers it: a byte for the
/// bus, then a nibble for each port from the Mac outwards. 0x14500000 is
/// socket 5 on bus 0x14; 0x14420000 is port 2 of a hub in socket 4.
public struct USBLocation: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let id: UInt32

    public init(_ id: UInt32) {
        self.id = id
    }

    /// From a log line's "@14420000".
    public init?(hex: String) {
        guard hex.count == 8, let id = UInt32(hex, radix: 16) else { return nil }
        self.id = id
    }

    /// The port numbers, from the Mac out: [4, 2] for port 2 of the hub in
    /// socket 4.
    public var ports: [Int] {
        var ports: [Int] = []
        for shift in stride(from: 20, through: 0, by: -4) {
            let port = Int((id >> UInt32(shift)) & 0xF)
            if port == 0 { break }
            ports.append(port)
        }
        return ports
    }

    /// A socket on the Mac itself, not a hub's.
    public var isOnTheMac: Bool { ports.count <= 1 }

    /// The hub this port belongs to; nil for a socket on the Mac.
    public var hub: USBLocation? {
        let depth = ports.count
        guard depth > 1 else { return nil }
        return USBLocation(id & ~(UInt32(0xF) << UInt32(24 - 4 * depth)))
    }

    public var description: String { String(format: "%08x", id) }

    public static func < (a: Self, b: Self) -> Bool { a.id < b.id }
}

/// A USB device, as the IO registry has it.
public struct USBDevice: Equatable, Sendable {
    public var name: String
    public var vendorID: Int
    public var productID: Int
    public var serial: String?
    public var location: USBLocation
    public var isHub: Bool
    /// Part of the Mac: its camera, keyboard, the T2.
    public var isBuiltIn: Bool

    public init(name: String, vendorID: Int, productID: Int, serial: String? = nil, location: USBLocation,
                isHub: Bool = false, isBuiltIn: Bool = false) {
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.serial = serial
        self.location = location
        self.isHub = isHub
        self.isBuiltIn = isBuiltIn
    }

    public var identity: USBIdentity { USBIdentity(vendor: vendorID, product: productID) }
}

/// What a vendor and product ID say a device is, of the ones that matter
/// here: the keypads, and what an RP2040 shows when it isn't one.
public enum USBIdentity: Equatable, Sendable {
    /// Running CircuitPython as this keypad's board.
    case keypad(KeypadDevice.Model)
    /// An RP2040 in its bootloader, waiting for a UF2 file: RPI-RP2.
    case bootloader
    /// A Pico running MicroPython.
    case microPython
    /// A Pico running a program of its own, built with the Pico SDK.
    case picoProgram
    /// Some other board running CircuitPython.
    case otherCircuitPython
    case other

    public init(vendor: Int, product: Int) {
        if let model = KeypadDevice.Model.allCases.first(where: { $0.usb == (vendor, product) }) {
            self = .keypad(model)
            return
        }
        switch (vendor, product) {
        case (0x2E8A, 0x0003): self = .bootloader
        case (0x2E8A, 0x0005): self = .microPython
        case (0x2E8A, 0x000A): self = .picoProgram
        case (0x239A, _): self = .otherCircuitPython
        default: self = .other
        }
    }

    /// An RP2040 of some kind: possibly a keypad not running the firmware.
    public var isRP2040: Bool {
        switch self {
        case .keypad, .bootloader, .microPython, .picoProgram: return true
        case .otherCircuitPython, .other: return false
        }
    }
}

public enum USBInventory {
    /// Every USB device plugged in, in the order of where it's plugged.
    public static func devices() -> [USBDevice] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [USBDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let vendor = int(service, "idVendor"), let product = int(service, "idProduct"),
                  let location = int(service, "locationID") else { continue }
            var name = string(service, "USB Product Name") ?? string(service, "kUSBProductString")
            if name == nil {
                var buffer = [CChar](repeating: 0, count: 128)
                if IORegistryEntryGetName(service, &buffer) == KERN_SUCCESS { name = String(cString: buffer) }
            }
            found.append(USBDevice(
                name: name ?? String(format: "a device %04x:%04x", vendor, product),
                vendorID: vendor, productID: product,
                serial: string(service, "USB Serial Number") ?? string(service, "kUSBSerialNumberString"),
                location: USBLocation(UInt32(truncatingIfNeeded: location)),
                isHub: int(service, "bDeviceClass") == 9,
                isBuiltIn: bool(service, "Built-In") || bool(service, "non-removable")))
        }
        return found.sorted { $0.location < $1.location }
    }

    /// Where a location is, in words: "a USB socket on the Mac", "port 2 of
    /// the hub “USB2.0 HUB”".
    public static func place(_ location: USBLocation, devices: [USBDevice]) -> String {
        guard let hub = location.hub, let port = location.ports.last else { return "a USB socket on the Mac" }
        let name = devices.first { $0.location == hub }?.name
        let which = name.map { "the hub “\($0)”" } ?? "a hub"
        let further = hub.isOnTheMac ? "" : ", itself plugged into another hub"
        return "port \(port) of \(which)\(further)"
    }

    // MARK: - IO registry plumbing

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        property(entry, key) as? String
    }

    private static func int(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        (property(entry, key) as? NSNumber)?.intValue
    }

    private static func bool(_ entry: io_registry_entry_t, _ key: String) -> Bool {
        (property(entry, key) as? NSNumber)?.boolValue ?? false
    }
}
