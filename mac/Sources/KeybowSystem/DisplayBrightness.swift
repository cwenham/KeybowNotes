import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics
import IOKit.i2c
import KeybowKit

/// A screen, as the brightness keys know it.
public struct DisplayInfo: Equatable, Sendable {
    public let id: CGDirectDisplayID
    public let name: String
    /// In AppKit's terms, as `NSScreen` gives it.
    public let frame: CGRect
    public let isBuiltIn: Bool

    public init(id: CGDirectDisplayID, name: String, frame: CGRect, isBuiltIn: Bool) {
        self.id = id
        self.name = name
        self.frame = frame
        self.isBuiltIn = isBuiltIn
    }

    /// The screens connected, and where the pointer is.
    @MainActor
    static func current() -> (displays: [DisplayInfo], pointer: CGPoint) {
        let displays = NSScreen.screens.compactMap { screen -> DisplayInfo? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = CGDirectDisplayID(number.uint32Value)
            return DisplayInfo(id: id, name: screen.localizedName, frame: screen.frame, isBuiltIn: CGDisplayIsBuiltin(id) != 0)
        }
        return (displays, NSEvent.mouseLocation)
    }
}

/// Reads and sets screens' brightness, 0 to 1. A protocol, so tests use
/// made-up screens.
public protocol BrightnessControl: AnyObject, Sendable {
    func level(of display: DisplayInfo) throws -> Double
    func setLevel(_ level: Double, of display: DisplayInfo) throws
}

/// Apple's own screens through DisplayServices, as the brightness keys set
/// them — built in, a Studio Display, an iMac lent as a screen — and others
/// through DDC/CI, the monitor's own controls reached over its cable.
///
/// DisplayServices is private, so it's looked up when first needed, and
/// DDC is tried should it go. DDC is reached through the graphics card's I²C
/// bus, which Intel Macs offer; Apple silicon Macs don't, so there only
/// Apple's screens can be set for now.
public final class SystemBrightness: BrightnessControl, @unchecked Sendable {
    private let lock = NSLock()
    /// DDC is slow to read, so what was last read or set is kept for a while:
    /// keys pressed in a row step from it.
    private var known: [CGDirectDisplayID: (value: Int, maximum: Int, at: Date)] = [:]
    static let keepFor: TimeInterval = 15

    public init() {}

    public func level(of display: DisplayInfo) throws -> Double {
        if let services = DisplayServices.shared, services.canChange(display.id) {
            guard let level = services.level(display.id) else {
                throw ModuleError("Couldn't read \(display.name)'s brightness")
            }
            return level
        }
        let reading = try ddcReading(display)
        return Double(reading.value) / Double(reading.maximum)
    }

    public func setLevel(_ level: Double, of display: DisplayInfo) throws {
        if let services = DisplayServices.shared, services.canChange(display.id) {
            guard services.setLevel(level, display.id) else {
                throw ModuleError("\(display.name)'s brightness didn't change")
            }
            return
        }
        let maximum = try ddcReading(display).maximum
        let value = Int((level * Double(maximum)).rounded())
        try DDC.Bus(display: display).write(DDC.brightness, value: UInt16(value))
        lock.withLock { known[display.id] = (value, maximum, Date()) }
    }

    private func ddcReading(_ display: DisplayInfo) throws -> (value: Int, maximum: Int) {
        if let kept = lock.withLock({ known[display.id] }), Date().timeIntervalSince(kept.at) < Self.keepFor {
            return (kept.value, kept.maximum)
        }
        let reading = try DDC.Bus(display: display).read(DDC.brightness)
        lock.withLock { known[display.id] = (reading.value, reading.maximum, Date()) }
        return reading
    }
}

/// DisplayServices' brightness functions, from the private framework.
struct DisplayServices {
    private typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let canChangeBrightness: CanChange
    private let getBrightness: Get
    private let setBrightness: Set

    /// Nil should the framework or its functions go.
    static let shared: DisplayServices? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let canChange = dlsym(handle, "DisplayServicesCanChangeBrightness"),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return DisplayServices(canChangeBrightness: unsafeBitCast(canChange, to: CanChange.self),
                               getBrightness: unsafeBitCast(get, to: Get.self),
                               setBrightness: unsafeBitCast(set, to: Set.self))
    }()

    func canChange(_ display: CGDirectDisplayID) -> Bool { canChangeBrightness(display) }

    func level(_ display: CGDirectDisplayID) -> Double? {
        var level = Float(0)
        return getBrightness(display, &level) == 0 ? Double(level) : nil
    }

    func setLevel(_ level: Double, _ display: CGDirectDisplayID) -> Bool {
        setBrightness(display, Float(min(max(level, 0), 1))) == 0
    }
}

/// DDC/CI: a monitor's controls — brightness is VCP code 0x10 — read and set
/// over its cable.
enum DDC {
    static let brightness: UInt8 = 0x10
    /// Where messages go: the monitor's address, 0x37, shifted for writing.
    static let address: UInt8 = 0x6E

    /// Asks for a control's value.
    static func readRequest(_ code: UInt8) -> [UInt8] {
        sealed([0x51, 0x82, 0x01, code])
    }

    /// Sets a control.
    static func writeRequest(_ code: UInt8, value: UInt16) -> [UInt8] {
        sealed([0x51, 0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// A message with its checksum: every byte XORed with the address.
    private static func sealed(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [bytes.reduce(address, ^)]
    }

    /// The value and maximum in a reply to `readRequest(code)`, or nil when
    /// it isn't one: an empty reply, a garbled one, or one about another
    /// control. The reply's checksum starts from 0x50, the host's address.
    static func reading(_ reply: [UInt8], for code: UInt8) -> (value: Int, maximum: Int)? {
        guard reply.count >= 11, reply[1] == 0x88, reply[2] == 0x02, reply[3] == 0x00, reply[4] == code,
              reply[..<10].reduce(UInt8(0x50), ^) == reply[10] else { return nil }
        let maximum = Int(reply[6]) << 8 | Int(reply[7]), value = Int(reply[8]) << 8 | Int(reply[9])
        // Every bit set: a screen that answers anything with ones, not a value.
        guard maximum > 0, maximum < 0xFFFF, value <= maximum else { return nil }
        return (value, maximum)
    }

    /// The graphics card's I²C bus to one screen. Each message is retried a
    /// few times, waiting longer each time: monitors are slow, and often
    /// answer with nothing at first.
    struct Bus {
        let display: DisplayInfo

        func read(_ code: UInt8) throws -> (value: Int, maximum: Int) {
            for wait in [40, 60, 100, 150] {
                var reply = [UInt8](repeating: 0, count: 11)
                if send(DDC.readRequest(code), reply: &reply, waitMs: wait), let reading = DDC.reading(reply, for: code) {
                    return reading
                }
                usleep(50_000)
            }
            throw unreachable
        }

        func write(_ code: UInt8, value: UInt16) throws {
            var none: [UInt8] = []
            for _ in 0..<3 {
                if send(DDC.writeRequest(code, value: value), reply: &none, waitMs: 0) { return }
                usleep(50_000)
            }
            throw unreachable
        }

        private var unreachable: ModuleError {
            #if arch(arm64)
            ModuleError("\(display.name)'s brightness can't be set from here",
                        "On a Mac with Apple silicon, KeybowNotes can only set Apple's own screens for now.")
            #else
            ModuleError("\(display.name)'s brightness can't be set from here",
                        "It didn't answer over DDC/CI. Some monitors have it turned off in their own menus, "
                        + "and some adapters and docks don't pass it on.")
            #endif
        }

        /// One message, and its reply if `reply` has room for one.
        private func send(_ message: [UInt8], reply: inout [UInt8], waitMs: Int) -> Bool {
            guard let framebuffer = Self.framebuffer(for: display.id) else { return false }
            defer { IOObjectRelease(framebuffer) }
            var message = message
            let replyCount = reply.count
            return message.withUnsafeMutableBufferPointer { sending in
                reply.withUnsafeMutableBufferPointer { receiving in
                    var request = IOI2CRequest()
                    request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                    request.sendAddress = UInt32(DDC.address)
                    request.sendBuffer = vm_address_t(bitPattern: sending.baseAddress)
                    request.sendBytes = UInt32(sending.count)
                    if replyCount > 0 {
                        // Absolute time, which on Intel is nanoseconds.
                        request.minReplyDelay = UInt64(waitMs) * 1_000_000
                        request.replyTransactionType = IOOptionBits(kIOI2CDDCciReplyTransactionType)
                        request.replyAddress = UInt32(DDC.address) + 1
                        request.replySubAddress = 0x51
                        request.replyBuffer = vm_address_t(bitPattern: receiving.baseAddress)
                        request.replyBytes = UInt32(replyCount)
                    } else {
                        request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
                    }
                    return Self.send(&request, to: framebuffer)
                }
            }
        }

        private static func send(_ request: inout IOI2CRequest, to framebuffer: io_service_t) -> Bool {
            var buses: IOItemCount = 0
            guard IOFBGetI2CInterfaceCount(framebuffer, &buses) == KERN_SUCCESS else { return false }
            for bus in 0..<buses {
                var interface = io_service_t()
                guard IOFBCopyI2CInterfaceForBus(framebuffer, bus, &interface) == KERN_SUCCESS else { continue }
                defer { IOObjectRelease(interface) }
                var connection: IOI2CConnectRef?
                guard IOI2CInterfaceOpen(interface, 0, &connection) == KERN_SUCCESS, let connection else { continue }
                let sent = IOI2CSendRequest(connection, 0, &request)
                IOI2CInterfaceClose(connection, 0)
                if sent == KERN_SUCCESS, request.result == KERN_SUCCESS { return true }
            }
            return false
        }

        /// The frame buffer driving a screen, matched by the maker, model and
        /// serial number its EDID gives. Nil on Apple silicon, which has none.
        private static func framebuffer(for display: CGDirectDisplayID) -> io_service_t? {
            var services = io_iterator_t()
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFramebuffer"), &services) == KERN_SUCCESS
            else { return nil }
            defer { IOObjectRelease(services) }
            while case let service = IOIteratorNext(services), service != 0 {
                let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))
                    .takeRetainedValue() as NSDictionary
                if info[kDisplayVendorID] as? UInt32 == CGDisplayVendorNumber(display),
                   info[kDisplayProductID] as? UInt32 == CGDisplayModelNumber(display),
                   info[kDisplaySerialNumber] as? UInt32 ?? 0 == CGDisplaySerialNumber(display) {
                    return service
                }
                IOObjectRelease(service)
            }
            return nil
        }
    }
}
