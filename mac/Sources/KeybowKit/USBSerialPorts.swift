import Foundation
import IOKit
import IOKit.serial

/// A serial port belonging to a USB device, as the IO registry describes it.
public struct USBSerialPort: Equatable, Sendable {
    /// e.g. "/dev/cu.usbmodem14503"
    public let path: String
    /// USB interface this port belongs to. CircuitPython puts the REPL console on
    /// the lower number and the data port on the higher one.
    public let interfaceNumber: Int?
    public let vendorID: Int
    public let productID: Int
    /// The USB device's serial number: for CircuitPython, the board's unique ID.
    public var serial: String?
    /// The IO registry's ID for this port, new each time the board connects:
    /// a restart shows as a change, however quickly the board comes back.
    public var registryID: UInt64 = 0
}

/// A keypad KeybowNotes can talk to: a Keybow 2040, or Pimoroni's RGB
/// Keypad Base on a Raspberry Pi Pico, running the KeybowNotes firmware.
public struct KeypadDevice: Hashable, Sendable {
    public enum Model: String, CaseIterable, Sendable {
        case keybow2040
        case rgbKeypad = "rgbkeypad"

        public var title: String {
            switch self {
            case .keybow2040: return "Keybow 2040"
            case .rgbKeypad: return "RGB Keypad"
            }
        }

        /// The USB identity CircuitPython gives each board.
        var usb: (vendor: Int, product: Int) {
            switch self {
            case .keybow2040: return (0x16D0, 0x08C6)
            case .rgbKeypad: return (0x239A, 0x80F4)       // any Pico running CircuitPython
            }
        }

        /// From an outline or the firmware, any case and spacing: "Keybow
        /// 2040", "keybow", "RGB Keypad", "rgbkeypad", "Pico".
        public init?(words: String) {
            switch words.lowercased().filter({ $0.isLetter || $0.isNumber }) {
            case "keybow2040", "keybow": self = .keybow2040
            case "rgbkeypad", "rgbkeypadbase", "picorgbkeypad", "pico", "rgb": self = .rgbKeypad
            default: return nil
            }
        }
    }

    /// The board's unique ID, which is also its USB serial number.
    public let serial: String
    public let model: Model
    /// The port the protocol runs on; the console is the other.
    public let dataPort: String
    public let consolePort: String?

    public init(serial: String, model: Model, dataPort: String, consolePort: String? = nil) {
        self.serial = serial
        self.model = model
        self.dataPort = dataPort
        self.consolePort = consolePort
    }
}

public enum USBSerialPorts {
    /// Every callout device belonging to the given USB device, lowest interface first.
    public static func ports(vendorID: Int, productID: Int) -> [USBSerialPort] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) as NSMutableDictionary? else {
            return []
        }
        matching[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var found: [USBSerialPort] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = stringProperty(service, kIOCalloutDeviceKey) else { continue }
            guard let usb = usbAncestry(of: service) else { continue }
            guard usb.vendorID == vendorID, usb.productID == productID else { continue }
            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryID)
            found.append(
                USBSerialPort(
                    path: path,
                    interfaceNumber: usb.interfaceNumber,
                    vendorID: usb.vendorID,
                    productID: usb.productID,
                    serial: usb.serial,
                    registryID: registryID
                )
            )
        }
        return found.sorted { ($0.interfaceNumber ?? .max, $0.path) < ($1.interfaceNumber ?? .max, $1.path) }
    }

    /// Every keypad connected, in a steady order. A board shows two ports
    /// once its boot.py has run — the console, and the data port the protocol
    /// uses — and one with only the console is left alone: talking to it
    /// would be typing into its REPL.
    public static func keypads() -> [KeypadDevice] {
        boards().compactMap { board in
            guard board.ports.count >= 2 else { return nil }
            return KeypadDevice(serial: board.serial, model: board.model, dataPort: board.ports.last!,
                                consolePort: board.ports.first)
        }
    }

    /// A keypad's board running CircuitPython, whether or not its boot.py has
    /// run: its unique ID, and its ports, the console first.
    public struct Board: Equatable, Sendable {
        public let serial: String
        public let model: KeypadDevice.Model
        public let ports: [String]
        /// Changes when the board restarts.
        public let registryIDs: [UInt64]

        public var consolePort: String? { ports.first }
    }

    /// Every keypad board running CircuitPython, in a steady order.
    public static func boards() -> [Board] {
        var boards: [Board] = []
        for model in KeypadDevice.Model.allCases {
            let ports = ports(vendorID: model.usb.vendor, productID: model.usb.product)
            let bySerial = Dictionary(grouping: ports) { $0.serial ?? "" }
            for (serial, own) in bySerial.sorted(by: { $0.key < $1.key }) {
                let sorted = own.sorted { ($0.interfaceNumber ?? .max, $0.path) < ($1.interfaceNumber ?? .max, $1.path) }
                boards.append(Board(serial: serial, model: model, ports: sorted.map(\.path),
                                    registryIDs: sorted.map(\.registryID)))
            }
        }
        return boards
    }

    /// The port carrying the KeybowNotes protocol.
    ///
    /// CircuitPython exposes two: the REPL console and the data port enabled by
    /// boot.py. The data port is the one on the higher USB interface number.
    public static func keybowDataPort() -> USBSerialPort? {
        ports(vendorID: KeybowProtocol.vendorID, productID: KeybowProtocol.productID).last
    }

    /// The data port of the first keypad connected, of any model.
    public static func firstKeypad() -> KeypadDevice? {
        keypads().first
    }

    /// The REPL console, useful for diagnostics.
    public static func keybowConsolePort() -> USBSerialPort? {
        ports(vendorID: KeybowProtocol.vendorID, productID: KeybowProtocol.productID).first
    }

    // MARK: - IO registry plumbing

    private static func usbAncestry(
        of service: io_registry_entry_t
    ) -> (vendorID: Int, productID: Int, interfaceNumber: Int?, serial: String?)? {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        var interfaceNumber: Int?
        var vendorID: Int?
        var productID: Int?
        var serial: String?

        // Walk towards the root collecting what we find. The whole chain is
        // visited rather than stopping at the first idVendor, because the ACM
        // driver copies the device's identifiers onto itself — stopping early
        // would skip the interface entry that carries bInterfaceNumber.
        for _ in 0..<16 {
            if interfaceNumber == nil {
                interfaceNumber = intProperty(current, "bInterfaceNumber")
            }
            if vendorID == nil { vendorID = intProperty(current, "idVendor") }
            if productID == nil { productID = intProperty(current, "idProduct") }
            if serial == nil { serial = stringProperty(current, "USB Serial Number") ?? stringProperty(current, "kUSBSerialNumberString") }
            if interfaceNumber != nil, vendorID != nil, productID != nil, serial != nil { break }

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                break
            }
            IOObjectRelease(current)
            current = parent
        }

        guard let vendor = vendorID, let product = productID else { return nil }
        return (vendor, product, interfaceNumber, serial)
    }

    private static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return value.takeRetainedValue() as? String
    }

    private static func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return (value.takeRetainedValue() as? NSNumber)?.intValue
    }
}
