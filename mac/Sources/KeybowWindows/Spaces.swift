import AppKit
import CoreGraphics
import Foundation
import KeybowKit

/// The Spaces on each screen — Mission Control's desktops, and apps' full-screen
/// spaces — as macOS lists them. Built from plain values, so it's tested
/// without a window server; `SystemSpaces` reads the real ones.
public struct SpacesLayout: Equatable, Sendable {
    /// A connected screen, as macOS describes it.
    public struct Display: Equatable, Sendable {
        /// The display's UUID, as the window server names it among Spaces.
        public let identifier: String
        public let name: String
        /// In AppKit's terms, as `NSScreen` gives it.
        public let frame: CGRect
        /// The one with the menu bar.
        public let isMain: Bool

        public init(identifier: String, name: String, frame: CGRect, isMain: Bool) {
            self.identifier = identifier.uppercased()
            self.name = name
            self.frame = frame
            self.isMain = isMain
        }
    }

    public struct Space: Equatable, Sendable {
        /// The window server's id for it, its `ManagedSpaceID`.
        public let id: Int
        /// Its number among its screen's desktops, from 1, left to right as
        /// Mission Control shows them; nil for an app's full-screen space.
        public let desktop: Int?
        /// Mission Control's number for a desktop — Desktop 7 — counted
        /// across every screen, which its keyboard shortcut goes by.
        public let missionControl: Int?
        /// The app whose full-screen space it is.
        public let app: String?
    }

    public struct Screen: Equatable, Sendable {
        /// From 1, counting from the left, as the window action's `screen: 2`.
        public let number: Int
        public let name: String
        public let frame: CGRect
        public let identifier: String
        /// In Mission Control's order. Empty when screens share the main
        /// one's Spaces.
        public let spaces: [Space]
        /// The space it shows now.
        public let showing: Int?

        public var desktops: [Space] { spaces.filter { $0.desktop != nil } }

        /// Its desktop numbered `number`, from 1.
        public func desktop(_ number: Int) -> Space? {
            spaces.first { $0.desktop == number }
        }
    }

    /// Left to right: `screens[0]` is screen 1.
    public let screens: [Screen]
    /// False when *Displays have separate Spaces* is off, and every screen
    /// shows the main one's.
    public let separate: Bool
    /// The screens' identifiers in the window server's own order, the main
    /// one's first: Mission Control may number desktops this way instead.
    public let serverOrder: [String]

    /// From the window server's list — one entry per display, each with its
    /// `Display Identifier`, `Spaces` and `Current Space` — and the screens
    /// connected. Entries for screens not connected are left out; screens
    /// with no entry have no Spaces of their own.
    public init(managed: [[String: Any]], displays: [Display], separate: Bool = true,
                appName: (Int) -> String? = { _ in nil }) {
        func identifier(_ entry: [String: Any]) -> String? {
            guard let id = (entry["Display Identifier"] as? String)?.uppercased() else { return nil }
            if id == "MAIN" { return displays.first(where: \.isMain)?.identifier }
            return displays.contains { $0.identifier == id } ? id : nil
        }
        var entries: [String: [String: Any]] = [:]
        var serverOrder: [String] = []
        for entry in managed {
            guard let id = identifier(entry), entries[id] == nil else { continue }
            entries[id] = entry
            serverOrder.append(id)
        }

        // Mission Control numbers desktops across screens from the left, as
        // Spaceman does: the first screen's, then the next one's.
        var missionControl = 0
        screens = displays.sorted { WindowGeometry.comesFirst($0.frame, $1.frame) }.enumerated().map { index, display in
            let entry = entries[display.identifier] ?? [:]
            var desktop = 0
            let spaces = (entry["Spaces"] as? [[String: Any]] ?? []).compactMap { raw -> Space? in
                guard let id = Self.spaceID(raw) else { return nil }
                if Self.isFullScreen(raw) {
                    return Space(id: id, desktop: nil, missionControl: nil, app: (raw["pid"] as? Int).flatMap(appName))
                }
                desktop += 1
                missionControl += 1
                return Space(id: id, desktop: desktop, missionControl: missionControl, app: nil)
            }
            return Screen(number: index + 1, name: display.name, frame: display.frame, identifier: display.identifier,
                          spaces: spaces, showing: (entry["Current Space"] as? [String: Any]).flatMap(Self.spaceID))
        }
        self.separate = separate
        self.serverOrder = serverOrder
    }

    public func screen(_ number: Int) -> Screen? {
        screens.indices.contains(number - 1) ? screens[number - 1] : nil
    }

    public func screen(identifier: String) -> Screen? {
        screens.first { $0.identifier == identifier.uppercased() }
    }

    /// What each screen shows, by identifier: from the same list as `init`.
    public static func showing(in managed: [[String: Any]], mainIdentifier: String?) -> [String: Int] {
        var showing: [String: Int] = [:]
        for entry in managed {
            guard var id = (entry["Display Identifier"] as? String)?.uppercased(),
                  let current = (entry["Current Space"] as? [String: Any]).flatMap(spaceID) else { continue }
            if id == "MAIN", let main = mainIdentifier { id = main.uppercased() }
            showing[id] = current
        }
        return showing
    }

    /// A desktop's number counting screens in the window server's order —
    /// what Mission Control would call it if it counted the main screen's
    /// first — for saying what went wrong.
    func serverNumber(of space: Int) -> Int? {
        var number = 0
        for identifier in serverOrder {
            for desktop in screen(identifier: identifier)?.desktops ?? [] {
                number += 1
                if desktop.id == space { return number }
            }
        }
        return nil
    }

    private static func spaceID(_ raw: [String: Any]) -> Int? {
        (raw["ManagedSpaceID"] as? Int) ?? (raw["id64"] as? Int)
    }

    /// An app's full-screen space: type 4, laid out in tiles.
    private static func isFullScreen(_ raw: [String: Any]) -> Bool {
        raw["TileLayoutManager"] != nil || (raw["type"] as? Int) == 4
    }
}

/// A *Switch to Desktop N* keyboard shortcut, as System Settings → Keyboard →
/// Keyboard Shortcuts → Mission Control keeps it.
public struct DesktopShortcut: Equatable, Sendable {
    public let key: CGKeyCode
    /// Shift, Control, Option and Command, as an event carries them.
    public let modifiers: CGEventFlags
    /// What's on the key: "1", "=".
    public let character: String

    /// Mission Control has shortcuts for this many desktops.
    public static let most = 16
    /// The symbolic hot key for Desktop 1; Desktop N's is this plus N − 1.
    static let firstHotKey = 118

    public init(key: CGKeyCode, modifiers: CGEventFlags, character: String) {
        self.key = key
        self.modifiers = modifiers
        self.character = character
    }

    /// From its entry in `com.apple.symbolichotkeys` — turned on, with
    /// parameters [character, key code, modifiers] — or nil when it's off.
    init?(entry: Any?) {
        guard let entry = entry as? [String: Any], entry["enabled"] as? Bool == true,
              let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [Int],
              parameters.count >= 3, (0..<0xFFFF).contains(parameters[1]) else { return nil }
        let kept = CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
        key = CGKeyCode(parameters[1])
        modifiers = CGEventFlags(rawValue: UInt64(max(parameters[2], 0)) & kept)
        let scalar = (33..<0xFFFF).contains(parameters[0]) ? UnicodeScalar(parameters[0]) : nil
        character = scalar.map { String($0).uppercased() } ?? "key \(parameters[1])"
    }

    /// The ones turned on, by desktop number, from the `AppleSymbolicHotKeys`
    /// in `com.apple.symbolichotkeys`.
    public static func all(in hotKeys: [String: Any]) -> [Int: DesktopShortcut] {
        var shortcuts: [Int: DesktopShortcut] = [:]
        for desktop in 1...most {
            if let shortcut = DesktopShortcut(entry: hotKeys[String(firstHotKey + desktop - 1)]) {
                shortcuts[desktop] = shortcut
            }
        }
        return shortcuts
    }

    /// As menus write it: ⌃⌥⇧⌘, then the key.
    public var title: String {
        var text = ""
        if modifiers.contains(.maskControl) { text += "⌃" }
        if modifiers.contains(.maskAlternate) { text += "⌥" }
        if modifiers.contains(.maskShift) { text += "⇧" }
        if modifiers.contains(.maskCommand) { text += "⌘" }
        return text + character
    }

    /// Where it's turned on, for saying so.
    public static func whereToTurnOn(_ desktop: Int) -> String {
        "Turn on “Switch to Desktop \(desktop)” in System Settings → Keyboard → Keyboard Shortcuts → Mission Control."
    }
}

/// What switching Spaces needs of the Mac. A protocol, so tests use a made-up
/// window server and nothing on screen changes.
public protocol SpacesControl: AnyObject, Sendable {
    /// The screens and their Spaces, and the number of the screen the
    /// pointer is on.
    func layout() async -> (layout: SpacesLayout, pointer: Int?)
    /// The space each screen shows now, by its identifier.
    func showing() -> [String: Int]
    /// The *Switch to Desktop* shortcuts turned on, by desktop number.
    func shortcuts() -> [Int: DesktopShortcut]
    /// Whether keys may be pressed for the person: Accessibility.
    var mayPress: Bool { get }
    /// Asks for Accessibility, so the app is in System Settings' list.
    func askToPress()
    func press(_ shortcut: DesktopShortcut)
}

/// The Mac's own: the window server's Spaces, System Settings' shortcuts,
/// and keys pressed as if typed.
///
/// macOS gives apps no way to list or switch Spaces. The list comes from the
/// window server's private `CGSCopyManagedDisplaySpaces`, as Spaceman and
/// yabai read it, looked up when first needed — failing that, from what the
/// Dock last saved, which may be a moment behind. Switching is done as a
/// person would: by pressing the desktop's shortcut.
public final class SystemSpaces: SpacesControl, @unchecked Sendable {
    public init() {}

    /// As things stand. On the main thread, for the screens.
    @MainActor
    public static func layout() -> SpacesLayout {
        SpacesLayout(managed: managedDisplays(), displays: displays(), separate: separate,
                     appName: { NSRunningApplication(processIdentifier: pid_t($0))?.localizedName })
    }

    /// The *Switch to Desktop* shortcuts turned on, read afresh.
    public static func shortcuts() -> [Int: DesktopShortcut] {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any] else {
            return [:]
        }
        return DesktopShortcut.all(in: hotKeys)
    }

    public func layout() async -> (layout: SpacesLayout, pointer: Int?) {
        await MainActor.run {
            let layout = Self.layout()
            let pointer = NSEvent.mouseLocation
            let screen = layout.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            return (layout, screen?.number)
        }
    }

    public func showing() -> [String: Int] {
        SpacesLayout.showing(in: Self.managedDisplays(), mainIdentifier: Self.uuid(of: CGMainDisplayID()))
    }

    public func shortcuts() -> [Int: DesktopShortcut] { Self.shortcuts() }

    public var mayPress: Bool { AXIsProcessTrusted() }

    public func askToPress() {
        // Asked once, in the app, so it's in System Settings' list.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    public func press(_ shortcut: DesktopShortcut) {
        Keystroke.press(shortcut.key, with: shortcut.modifiers)
    }

    // MARK: - The window server

    @MainActor
    private static func displays() -> [SpacesLayout.Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = uuid(of: CGDirectDisplayID(number.uint32Value)) else { return nil }
            return SpacesLayout.Display(identifier: uuid, name: screen.localizedName, frame: screen.frame,
                                        isMain: CGDirectDisplayID(number.uint32Value) == CGMainDisplayID())
        }
    }

    static func uuid(of display: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Whether *Displays have separate Spaces* is on, as it is unless it's
    /// been turned off.
    private static var separate: Bool {
        CFPreferencesCopyAppValue("spans-displays" as CFString, "com.apple.spaces" as CFString) as? Bool != true
    }

    /// One entry per display, each with its Spaces.
    static func managedDisplays() -> [[String: Any]] {
        if let server, let list = server.copy(server.connection())?.takeRetainedValue() as? [[String: Any]] {
            return list
        }
        let saved = CFPreferencesCopyAppValue("SpacesDisplayConfiguration" as CFString, "com.apple.spaces" as CFString)
        return ((saved as? [String: Any])?["Management Data"] as? [String: Any])?["Monitors"] as? [[String: Any]] ?? []
    }

    private typealias Connection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    /// The window server's own functions; nil should they go.
    private static let server: (connection: Connection, copy: CopySpaces)? = {
        let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(skyLight, RTLD_LAZY),
              let connection = dlsym(handle, "SLSMainConnectionID") ?? dlsym(handle, "CGSMainConnectionID"),
              let copy = dlsym(handle, "SLSCopyManagedDisplaySpaces") ?? dlsym(handle, "CGSCopyManagedDisplaySpaces")
        else { return nil }
        return (unsafeBitCast(connection, to: Connection.self), unsafeBitCast(copy, to: CopySpaces.self))
    }()
}
