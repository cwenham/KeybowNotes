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
        public let id: CGDirectDisplayID
        /// The display's UUID, as the window server names it among Spaces.
        public let identifier: String
        public let name: String
        /// In AppKit's terms, as `NSScreen` gives it.
        public let frame: CGRect
        /// The one with the menu bar.
        public let isMain: Bool

        public init(id: CGDirectDisplayID, identifier: String, name: String, frame: CGRect, isMain: Bool) {
            self.id = id
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
        /// The app whose full-screen space it is.
        public let app: String?
    }

    public struct Screen: Equatable, Sendable {
        /// From 1, counting from the left, as the window action's `screen: 2`.
        public let number: Int
        public let name: String
        public let frame: CGRect
        public let displayID: CGDirectDisplayID
        public let identifier: String
        /// In Mission Control's order, full-screen spaces too. Empty when
        /// screens share the main one's Spaces.
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

    /// From the window server's list — one entry per display, each with its
    /// `Display Identifier`, `Spaces` and `Current Space` — and the screens
    /// connected. Entries for screens not connected are left out; screens
    /// with no entry have no Spaces of their own.
    public init(managed: [[String: Any]], displays: [Display], separate: Bool = true,
                appName: (Int) -> String? = { _ in nil }) {
        var entries: [String: [String: Any]] = [:]
        for entry in managed {
            guard var id = (entry["Display Identifier"] as? String)?.uppercased() else { continue }
            if id == "MAIN", let main = displays.first(where: \.isMain) { id = main.identifier }
            if entries[id] == nil { entries[id] = entry }
        }
        screens = displays.sorted { WindowGeometry.comesFirst($0.frame, $1.frame) }.enumerated().map { index, display in
            let entry = entries[display.identifier] ?? [:]
            var desktop = 0
            let spaces = (entry["Spaces"] as? [[String: Any]] ?? []).compactMap { raw -> Space? in
                guard let id = Self.spaceID(raw) else { return nil }
                if Self.isFullScreen(raw) {
                    return Space(id: id, desktop: nil, app: (raw["pid"] as? Int).flatMap(appName))
                }
                desktop += 1
                return Space(id: id, desktop: desktop, app: nil)
            }
            return Screen(number: index + 1, name: display.name, frame: display.frame, displayID: display.id,
                          identifier: display.identifier, spaces: spaces,
                          showing: (entry["Current Space"] as? [String: Any]).flatMap(Self.spaceID))
        }
        self.separate = separate
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

    private static func spaceID(_ raw: [String: Any]) -> Int? {
        (raw["ManagedSpaceID"] as? Int) ?? (raw["id64"] as? Int)
    }

    /// An app's full-screen space: type 4, laid out in tiles.
    private static func isFullScreen(_ raw: [String: Any]) -> Bool {
        raw["TileLayoutManager"] != nil || (raw["type"] as? Int) == 4
    }
}

/// A space's thumbnail in Mission Control: its screen's display, and its place
/// among that screen's Spaces, from 0.
public struct SpaceThumbnail: Equatable, Sendable {
    public let display: CGDirectDisplayID
    public let index: Int
    /// How many Spaces the screen has, to check Mission Control lists the same.
    public let count: Int

    public init(display: CGDirectDisplayID, index: Int, count: Int) {
        self.display = display
        self.index = index
        self.count = count
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
    /// Whether Mission Control may be worked for the person: Accessibility.
    var mayPress: Bool { get }
    /// Asks for Accessibility, so the app is in System Settings' list.
    func askToPress()
    /// Opens Mission Control and presses the thumbnail, which closes it.
    /// Throws a `ModuleError` when it can't be pressed.
    func press(_ thumbnail: SpaceThumbnail) async throws
}

/// The Mac's own: the window server's Spaces, and Mission Control worked
/// through the Dock's Accessibility elements.
///
/// macOS gives apps no way to list or switch Spaces. The list comes from the
/// window server's private `CGSCopyManagedDisplaySpaces`, as Spaceman and
/// yabai read it, looked up when first needed — failing that, from what the
/// Dock last saved, which may be a moment behind. Mission Control's *Switch to
/// Desktop* shortcuts reach only the main screen's desktops, so switching is
/// done as Hammerspoon's `hs.spaces.gotoSpace` does it: by opening Mission
/// Control and pressing the space's thumbnail, which only exists while it's
/// showing.
public final class SystemSpaces: SpacesControl, @unchecked Sendable {
    public init() {}

    /// As things stand. On the main thread, for the screens.
    @MainActor
    public static func layout() -> SpacesLayout {
        SpacesLayout(managed: managedDisplays(), displays: displays(), separate: separate,
                     appName: { NSRunningApplication(processIdentifier: pid_t($0))?.localizedName })
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

    public var mayPress: Bool { AXIsProcessTrusted() }

    public func askToPress() {
        // Asked once, in the app, so it's in System Settings' list.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    // MARK: - Mission Control

    public func press(_ thumbnail: SpaceThumbnail) async throws {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            throw ModuleError("The Dock isn't running", "Mission Control is part of it.")
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)

        // Mission Control may still be closing from the screen before: wait
        // for it to go. If it stays, it's open, and is used as it is.
        if Self.missionControl(app) != nil {
            _ = await Self.wait(seconds: 1) { Self.missionControl(app) == nil ? true : nil }
        }
        var group = Self.missionControl(app)
        if group == nil {
            guard let send = ExposeModule.sendToDock else { throw ModuleError("Mission Control can't be opened from here") }
            await MainActor.run { send("com.apple.expose.awake" as CFString, nil) }
            group = await Self.wait(seconds: 2) { Self.missionControl(app) }
        }
        guard let group else {
            throw ModuleError("Mission Control didn't open", "KeybowNotes opens it to switch Spaces.")
        }

        // Its thumbnails are made once Mission Control is fully open.
        let list = await Self.wait(seconds: 2) {
            Self.spacesList(in: group, display: thumbnail.display).flatMap { $0.isEmpty ? nil : $0 }
        }
        var problem: ModuleError?
        if let list {
            if list.count == thumbnail.count, list.indices.contains(thumbnail.index) {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if AXUIElementPerformAction(list[thumbnail.index], kAXPressAction as CFString) == .success { return }
                problem = ModuleError("Mission Control didn't take the press")
            } else {
                problem = ModuleError("Mission Control lists \(list.count) Spaces for a screen with \(thumbnail.count)",
                                      "They may have changed a moment ago: press the key again.")
            }
        } else {
            problem = ModuleError("Mission Control doesn't show that screen's Spaces")
        }
        // Nothing closed it: don't leave it open.
        await MainActor.run { ExposeModule.sendToDock?("com.apple.expose.awake" as CFString, nil) }
        throw problem ?? ModuleError("Mission Control didn't take the press")
    }

    /// Mission Control's group in the Dock, there only while it shows.
    private static func missionControl(_ dock: AXUIElement) -> AXUIElement? {
        children(dock).first { identifier($0) == "mc" }
    }

    /// One screen's thumbnails, in order: `mc.display` for the display, then
    /// `mc.spaces`, then `mc.spaces.list`.
    private static func spacesList(in group: AXUIElement, display: CGDirectDisplayID) -> [AXUIElement]? {
        guard let screen = children(group).first(where: { identifier($0) == "mc.display" && displayID($0) == display }),
              let spaces = children(screen).first(where: { identifier($0) == "mc.spaces" }),
              let list = children(spaces).first(where: { identifier($0) == "mc.spaces.list" }) else { return nil }
        return children(list)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func identifier(_ element: AXUIElement) -> String? {
        attribute(element, kAXIdentifierAttribute) as? String
    }

    private static func displayID(_ element: AXUIElement) -> CGDirectDisplayID? {
        (attribute(element, "AXDisplayID") as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Asks every 30 ms until there's an answer, or the time's up.
    private static func wait<T>(seconds: TimeInterval, for answer: () -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let found = answer() { return found }
            try? await Task.sleep(nanoseconds: 30_000_000)
        } while Date() < deadline && !Task.isCancelled
        return answer()
    }

    // MARK: - The window server

    @MainActor
    private static func displays() -> [SpacesLayout.Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = CGDirectDisplayID(number.uint32Value)
            guard let uuid = uuid(of: id) else { return nil }
            return SpacesLayout.Display(id: id, identifier: uuid, name: screen.localizedName, frame: screen.frame,
                                        isMain: id == CGMainDisplayID())
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
