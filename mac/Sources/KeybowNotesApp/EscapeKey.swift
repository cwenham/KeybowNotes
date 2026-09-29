import Carbon.HIToolbox

/// Esc, taken from whatever app is in front for as long as this is kept: a
/// hot key, which needs no permission — unlike watching keys typed into
/// other apps, which needs Accessibility or Input Monitoring access. While
/// it's held, the app in front doesn't get Esc; release it as soon as it's
/// no longer wanted.
@MainActor
final class EscapeKey {
    private static let signature: OSType = 0x4B42_4573      // "KBEs"
    private static var nextID: UInt32 = 1

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id: UInt32
    private let action: () -> Void

    /// Nil if Esc couldn't be taken — another app holds it.
    init?(action: @escaping () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1

        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            // Carbon calls on the main thread, where the key was registered.
            return MainActor.assumeIsolated {
                let key = Unmanaged<EscapeKey>.fromOpaque(userData).takeUnretainedValue()
                guard hotKeyID.signature == EscapeKey.signature, hotKeyID.id == key.id else {
                    return OSStatus(eventNotHandledErr)
                }
                key.action()
                return noErr
            }
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return nil }

        let registered = RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else {
            release()
            return nil
        }
    }

    /// Gives Esc back to the app in front.
    func release() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
