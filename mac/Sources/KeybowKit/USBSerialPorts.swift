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
            found.append(
                USBSerialPort(
                    path: path,
                    interfaceNumber: usb.interfaceNumber,
                    vendorID: usb.vendorID,
                    productID: usb.productID
                )
            )
        }
        return found.sorted { ($0.interfaceNumber ?? .max, $0.path) < ($1.interfaceNumber ?? .max, $1.path) }
    }

    /// The port carrying the KeybowNotes protocol.
    ///
    /// CircuitPython exposes two: the REPL console and the data port enabled by
    /// boot.py. The data port is the one on the higher USB interface number.
    public static func keybowDataPort() -> USBSerialPort? {
        ports(vendorID: KeybowProtocol.vendorID, productID: KeybowProtocol.productID).last
    }

    /// The REPL console, useful for diagnostics.
    public static func keybowConsolePort() -> USBSerialPort? {
        ports(vendorID: KeybowProtocol.vendorID, productID: KeybowProtocol.productID).first
    }

    // MARK: - IO registry plumbing

    private static func usbAncestry(
        of service: io_registry_entry_t
    ) -> (vendorID: Int, productID: Int, interfaceNumber: Int?)? {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        var interfaceNumber: Int?
        var vendorID: Int?
        var productID: Int?

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
            if interfaceNumber != nil, vendorID != nil, productID != nil { break }

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                break
            }
            IOObjectRelease(current)
            current = parent
        }

        guard let vendor = vendorID, let product = productID else { return nil }
        return (vendor, product, interfaceNumber)
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
