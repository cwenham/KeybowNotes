import AudioToolbox
import CoreAudio
import Foundation
import KeybowKit

/// The speakers or the microphone: whichever is the Mac's default.
public enum SoundSide: Sendable {
    case output, input

    var scope: AudioObjectPropertyScope {
        self == .output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
    }

    var defaultDevice: AudioObjectPropertySelector {
        self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }
}

/// The Mac's default sound devices, as the volume and microphone keys use
/// them. A protocol, so tests use made-up ones.
public protocol SoundControl: AnyObject, Sendable {
    /// The default device's name; nil when there's none.
    func deviceName(_ side: SoundSide) -> String?
    /// 0 to 1; nil when the device has no volume of its own.
    func volume(_ side: SoundSide) -> Double?
    func setVolume(_ level: Double, _ side: SoundSide) throws
    /// Nil when the device can't be muted.
    func isMuted(_ side: SoundSide) -> Bool?
    func setMuted(_ muted: Bool, _ side: SoundSide) throws
    /// Calls `changed` when the default device changes, or it's muted or
    /// unmuted — from here, its own controls or another app.
    func watch(_ side: SoundSide, _ changed: @escaping @Sendable () -> Void)
}

/// Core Audio's default devices. Setting a device's volume or mute needs no
/// permission: only recording does.
public final class CoreAudioSound: SoundControl, @unchecked Sendable {
    private let lock = NSLock()
    private var watchers: [Watcher] = []
    private let queue = DispatchQueue(label: "KeybowSystem.sound")

    public init() {}

    public func deviceName(_ side: SoundSide) -> String? {
        guard let device = Self.device(side) else { return nil }
        var address = Self.address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    public func volume(_ side: SoundSide) -> Double? {
        guard let device = Self.device(side), var address = Self.volumeAddress(device, side) else { return nil }
        var level = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level) == noErr else { return nil }
        return Double(level)
    }

    public func setVolume(_ level: Double, _ side: SoundSide) throws {
        guard let device = Self.device(side) else { throw Self.noDevice(side) }
        guard var address = Self.volumeAddress(device, side), Self.isSettable(device, &address) else {
            throw ModuleError("\(deviceName(side) ?? "This device") has no volume to set",
                              "Its own controls set it — a monitor or TV over HDMI, say.")
        }
        var value = Float32(min(max(level, 0), 1))
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        guard status == noErr else { throw ModuleError("The volume didn't change", "Core Audio said \(status).") }
    }

    public func isMuted(_ side: SoundSide) -> Bool? {
        guard let device = Self.device(side) else { return nil }
        var address = Self.address(kAudioDevicePropertyMute, side.scope)
        guard AudioObjectHasProperty(device, &address), Self.isSettable(device, &address) else { return nil }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return nil }
        return muted != 0
    }

    public func setMuted(_ muted: Bool, _ side: SoundSide) throws {
        guard let device = Self.device(side) else { throw Self.noDevice(side) }
        var address = Self.address(kAudioDevicePropertyMute, side.scope)
        guard AudioObjectHasProperty(device, &address), Self.isSettable(device, &address) else {
            throw ModuleError("\(deviceName(side) ?? "This device") can't be muted")
        }
        var value = UInt32(muted ? 1 : 0)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else { throw ModuleError("It didn't \(muted ? "mute" : "unmute")", "Core Audio said \(status).") }
    }

    public func watch(_ side: SoundSide, _ changed: @escaping @Sendable () -> Void) {
        let watcher = Watcher(side: side, queue: queue, changed: changed)
        lock.withLock { watchers.append(watcher) }
        watcher.begin()
    }

    // MARK: - Core Audio

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func device(_ side: SoundSide) -> AudioObjectID? {
        var address = address(side.defaultDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// The device's volume as a whole — what the menu bar's slider moves —
    /// else its main channel's.
    private static func volumeAddress(_ device: AudioObjectID, _ side: SoundSide) -> AudioObjectPropertyAddress? {
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            var address = address(selector, side.scope)
            if AudioObjectHasProperty(device, &address) { return address }
        }
        return nil
    }

    private static func isSettable(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func noDevice(_ side: SoundSide) -> ModuleError {
        side == .output ? ModuleError("There's nothing to play sound through")
            : ModuleError("There's no microphone", "Connect one, or choose one in System Settings → Sound.")
    }

    /// Listens to the default device, and moves to the next one when it
    /// changes.
    private final class Watcher: @unchecked Sendable {
        let side: SoundSide
        let queue: DispatchQueue
        let changed: @Sendable () -> Void
        private var device = AudioObjectID(kAudioObjectUnknown)
        private lazy var deviceChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.follow() }
        private lazy var propertyChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }

        init(side: SoundSide, queue: DispatchQueue, changed: @escaping @Sendable () -> Void) {
            self.side = side
            self.queue = queue
            self.changed = changed
        }

        func begin() {
            queue.async {
                var address = CoreAudioSound.address(self.side.defaultDevice)
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, self.queue,
                                                    self.deviceChanged)
                self.follow()
            }
        }

        /// On the queue: listen to whichever device is the default now.
        private func follow() {
            // Not the volume: apps that level a microphone move it many times a second.
            var mute = CoreAudioSound.address(kAudioDevicePropertyMute, side.scope)
            if device != kAudioObjectUnknown {
                AudioObjectRemovePropertyListenerBlock(device, &mute, queue, propertyChanged)
            }
            device = CoreAudioSound.device(side) ?? AudioObjectID(kAudioObjectUnknown)
            if device != kAudioObjectUnknown, AudioObjectHasProperty(device, &mute) {
                AudioObjectAddPropertyListenerBlock(device, &mute, queue, propertyChanged)
            }
            changed()
        }
    }
}
