import Foundation
import IOKit
import IOKit.hid

/// The Stream Decks this speaks to: those using Elgato's documented protocol
/// for the 15-key family (https://docs.elgato.com/streamdeck/hid/stream-deck-classic).
/// Others — the 2017 original, the Mini, the XL, the Plus — differ in their
/// key sizes or protocol, and aren't listed yet.
public struct StreamDeckModel: Hashable, Sendable {
    public let productID: Int
    public let name: String
    public let columns: Int
    public let rows: Int
    /// Each key's picture, in pixels, square.
    public let keySize: Int

    public static let vendorID = 0x0FD9

    public static let all: [StreamDeckModel] = [
        StreamDeckModel(productID: 0x006D, name: "Stream Deck (2019)", columns: 5, rows: 3, keySize: 72),
        StreamDeckModel(productID: 0x0080, name: "Stream Deck MK.2", columns: 5, rows: 3, keySize: 72),
        StreamDeckModel(productID: 0x00A5, name: "Stream Deck MK.2 Scissor Keys", columns: 5, rows: 3, keySize: 72),
        StreamDeckModel(productID: 0x00B9, name: "Stream Deck Module 15 Keys", columns: 5, rows: 3, keySize: 72),
    ]

    public static func model(productID: Int) -> StreamDeckModel? {
        all.first { $0.productID == productID }
    }

    public var keyCount: Int { columns * rows }
}

public enum StreamDeckDevices {
    /// The Stream Decks plugged in now, from the IO registry: cheap enough to
    /// call every couple of seconds, as keypads are looked for.
    public static func present() -> [KeypadDevice] {
        guard let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary? else { return [] }
        matching[kIOHIDVendorIDKey] = StreamDeckModel.vendorID
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [KeypadDevice] = []
        var seen = Set<String>()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let product = property(kIOHIDProductIDKey) as? Int, StreamDeckModel.model(productID: product) != nil,
                  let serial = property(kIOHIDSerialNumberKey) as? String, !serial.isEmpty,
                  seen.insert(serial).inserted else { continue }
            found.append(KeypadDevice(serial: serial, model: .streamDeck, dataPort: ""))
        }
        return found
    }
}

extension KeypadDevice {
    /// Every keypad plugged in: boards with their data port up, and Stream Decks.
    public static func connected() -> [KeypadDevice] {
        USBSerialPorts.keypads() + StreamDeckDevices.present()
    }
}
