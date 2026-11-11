import Foundation
import IOKit.hid
import KeybowKit

/// A Stream Deck, as a keypad: its key presses become presses on the 4×4
/// keypad the trees are laid out on (through `FolderLayout`), and each key
/// shows what pressing it does.
///
/// It speaks Elgato's HID protocol (https://docs.elgato.com/streamdeck/hid/):
/// input report 1 holds a byte per key, 1 while pressed; output report 2,
/// command 7, takes a key's picture as a JPEG in chunks of up to 1016 bytes;
/// feature report 3 sets the brightness (command 8) and shows Elgato's logo
/// (command 2).
public final class StreamDeckConnection: KeypadConnection, @unchecked Sendable {
    public let serial: String?
    public let events: AsyncStream<KeybowEvent>
    public var drawsKeys: Bool { true }

    private var continuation: AsyncStream<KeybowEvent>.Continuation?
    private let iconFolder: URL?
    /// HID callbacks arrive on this thread's run loop.
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var manager: IOHIDManager?
    /// Pictures go out in order, off the driver's queue.
    private let writer = DispatchQueue(label: "StreamDeckConnection.writer")

    /// Guarded by `lock`: shared by the driver's queue, the HID thread and the writer.
    private let lock = NSLock()
    private var device: IOHIDDevice?
    private var model: StreamDeckModel?
    private var view: KeypadView?
    private var showingBottomTree = false
    private var slots: [FolderLayout.Slot] = []
    /// What each key was last sent; nil once it needs sending again.
    private var sent: [KeyFace??] = []
    private var pressed: [Bool] = []
    /// What a key held down pressed, so its release goes to the same place.
    private var held: [Int: KeyPress] = [:]
    private var brightness = 1.0
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)

    public init(serial: String?, iconFolder: URL? = nil) {
        self.serial = serial
        self.iconFolder = iconFolder
        var captured: AsyncStream<KeybowEvent>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    deinit { reportBuffer.deallocate() }

    // MARK: - KeypadConnection

    public func start() {
        guard thread == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.runLoop = CFRunLoopGetCurrent()
            self.openManager()
            ready.signal()
            // Keeps the run loop alive with nothing scheduled yet.
            CFRunLoopAddTimer(CFRunLoopGetCurrent(),
                              CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in },
                              .defaultMode)
            CFRunLoopRun()
        }
        thread.name = "StreamDeck"
        self.thread = thread
        thread.start()
        ready.wait()
    }

    public func stop() {
        let device = lock.withLock { self.device }
        writer.sync {
            // Leave it showing Elgato's logo rather than a frozen menu.
            if let device { Self.setFeature(device, [0x03, 0x02]) }
        }
        if let runLoop, let manager {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        }
        lock.withLock { self.device = nil }
        continuation?.yield(.disconnected(reason: "stopped"))
        continuation?.finish()
        continuation = nil
    }

    /// Nothing to send: there are no lights, only pictures.
    public func send(_ command: HostCommand) {}

    public func setBrightness(_ value: Double) {
        let device = lock.withLock { () -> IOHIDDevice? in
            brightness = value
            return self.device
        }
        guard let device else { return }
        writer.async { Self.setFeature(device, [0x03, 0x08, UInt8((value * 100).rounded())]) }
    }

    public func show(_ view: KeypadView) {
        lock.withLock {
            // The bottom tree's view is for choosing in it; once anything
            // else is going on, it's done with.
            if view.tree != nil || view.page != nil { showingBottomTree = false }
            self.view = view
        }
        redraw()
    }

    // MARK: - Drawing

    private func redraw() {
        let work = lock.withLock { () -> (IOHIDDevice, StreamDeckModel, [(Int, KeyFace?)])? in
            guard let device, let model, let view else { return nil }
            let layout = FolderLayout(columns: model.columns, rows: model.rows)
            slots = layout.slots(for: view, showingBottomTree: showingBottomTree)
            if sent.count != slots.count { sent = Array(repeating: nil, count: slots.count) }
            var changed: [(Int, KeyFace?)] = []
            for (key, slot) in slots.enumerated() where sent[key] != .some(slot.face) {
                sent[key] = .some(slot.face)
                changed.append((key, slot.face))
            }
            return changed.isEmpty ? nil : (device, model, changed)
        }
        guard let (device, model, changed) = work else { return }
        let renderer = KeyRenderer(size: model.keySize, iconFolder: iconFolder)
        writer.async {
            for (key, face) in changed {
                guard let jpeg = renderer.jpeg(face) else { continue }
                Self.sendImage(jpeg, key: key, to: device)
            }
        }
    }

    private static func sendImage(_ jpeg: Data, key: Int, to device: IOHIDDevice) {
        let reportLength = 1024
        let chunkLength = reportLength - 8
        let bytes = [UInt8](jpeg)
        var offset = 0
        var page = 0
        repeat {
            let count = min(chunkLength, bytes.count - offset)
            let last = offset + count >= bytes.count
            var report = [UInt8](repeating: 0, count: reportLength)
            report[0] = 0x02
            report[1] = 0x07
            report[2] = UInt8(key)
            report[3] = last ? 1 : 0
            report[4] = UInt8(count & 0xFF)
            report[5] = UInt8(count >> 8)
            report[6] = UInt8(page & 0xFF)
            report[7] = UInt8(page >> 8)
            report.replaceSubrange(8..<(8 + count), with: bytes[offset..<(offset + count)])
            guard IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x02, report, reportLength) == kIOReturnSuccess
            else { return }
            offset += count
            page += 1
        } while offset < bytes.count
    }

    private static func setFeature(_ device: IOHIDDevice, _ bytes: [UInt8]) {
        var report = [UInt8](repeating: 0, count: 32)
        report.replaceSubrange(0..<bytes.count, with: bytes)
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(bytes[0]), report, report.count)
    }

    // MARK: - HID

    private func openManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = StreamDeckModel.all.map { model -> [String: Any] in
            var match: [String: Any] = [kIOHIDVendorIDKey: StreamDeckModel.vendorID, kIOHIDProductIDKey: model.productID]
            if let serial { match[kIOHIDSerialNumberKey] = serial }
            return match
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<StreamDeckConnection>.fromOpaque(context).takeUnretainedValue().attached(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<StreamDeckConnection>.fromOpaque(context).takeUnretainedValue().detached(device)
        }, context)
        IOHIDManagerRegisterInputReportCallback(manager, { context, _, sender, _, _, report, length in
            guard let context, let sender else { return }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            Unmanaged<StreamDeckConnection>.fromOpaque(context).takeUnretainedValue()
                .received(Array(UnsafeBufferPointer(start: report, count: length)), from: device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    private func attached(_ device: IOHIDDevice) {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        guard let model = StreamDeckModel.model(productID: product) else { return }
        let brightness = lock.withLock { () -> Double in
            guard self.device == nil else { return -1 }
            self.device = device
            self.model = model
            sent = Array(repeating: nil, count: model.keyCount)
            pressed = Array(repeating: false, count: model.keyCount)
            held = [:]
            return self.brightness
        }
        guard brightness >= 0 else { return }
        continuation?.yield(.connected(path: model.name))
        continuation?.yield(.message(.hello(protocolVersion: KeybowProtocol.supportedVersion)))
        if StreamDeckDevices.elgatoAppRunning {
            continuation?.yield(.message(.deviceError("Elgato's Stream Deck app is open, and may draw over its keys")))
        }
        writer.async { Self.setFeature(device, [0x03, 0x08, UInt8((brightness * 100).rounded())]) }
        redraw()
    }

    private func detached(_ device: IOHIDDevice) {
        let was = lock.withLock { () -> Bool in
            guard let current = self.device, CFEqual(current, device) else { return false }
            self.device = nil
            return true
        }
        if was { continuation?.yield(.disconnected(reason: "unplugged")) }
    }

    private func received(_ report: [UInt8], from device: IOHIDDevice) {
        // Report 1, command 0, a 16-bit count, then a byte per key.
        guard report.count > 4, report[0] == 0x01, report[1] == 0x00 else { return }
        var out: [KeybowEvent] = []
        var needsRedraw = false
        lock.withLock {
            guard let current = self.device, CFEqual(current, device) else { return }
            let count = min(Int(report[2]) | Int(report[3]) << 8, report.count - 4, pressed.count)
            for key in 0..<count {
                let down = report[4 + key] != 0
                guard down != pressed[key] else { continue }
                pressed[key] = down
                if down {
                    guard key < slots.count, let press = slots[key].press else { continue }
                    held[key] = press
                    switch press {
                    case .key(let keypadKey): out.append(.message(.down(key: keypadKey)))
                    case .navigate(let move): out.append(.navigate(move))
                    case .showBottomTree(let shown):
                        showingBottomTree = shown
                        needsRedraw = true
                    }
                } else if let press = held.removeValue(forKey: key), case .key(let keypadKey) = press {
                    out.append(.message(.up(key: keypadKey)))
                }
            }
        }
        for event in out { continuation?.yield(event) }
        if needsRedraw { redraw() }
    }
}
