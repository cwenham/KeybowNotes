import AppKit
import ApplicationServices
import KeybowKit

/// Moves the focused window of the app in front, through Accessibility.
@MainActor
enum WindowMover {
    /// The screens, as WindowGeometry takes them.
    static var screens: [WindowGeometry.Screen] {
        NSScreen.screens.map { WindowGeometry.Screen(name: $0.localizedName, frame: $0.frame, visible: $0.visibleFrame) }
    }

    /// The main screen's height: where Accessibility's rectangles start.
    static var mainHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    struct Window {
        let element: AXUIElement
        let app: AXUIElement
        let appName: String
    }

    /// The window being worked in: the app in front's focused window.
    static func front() throws -> Window {
        guard AXIsProcessTrusted() else {
            throw ModuleError("KeybowNotes needs Accessibility access to move windows",
                              "Allow it in System Settings → Privacy & Security → Accessibility.")
        }
        // On request, for testing: only that process's window, whatever's in
        // front — so trying this never moves anyone's work about. It only
        // narrows what's moved, so the app honours it too.
        let only = ProcessInfo.processInfo.environment["KEYBOW_DEBUG_WINDOW_PID"].flatMap(Int32.init)
        guard let running = only.map({ NSRunningApplication(processIdentifier: $0) }) ?? NSWorkspace.shared.frontmostApplication else {
            throw ModuleError("No app is in front to move a window of")
        }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        let name = running.localizedName ?? "The app in front"
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
                ?? first(app, kAXWindowsAttribute) else {
            throw ModuleError("\(name) has no window in front to move")
        }
        if bool(window, "AXFullScreen") == true {
            throw ModuleError("\(name)'s window is in full-screen mode", "Leave full-screen mode first, then try again.")
        }
        if bool(window, kAXMinimizedAttribute) == true {
            throw ModuleError("\(name)'s window is minimised")
        }
        return Window(element: window, app: app, appName: name)
    }

    /// Where it is, in Accessibility's terms.
    static func frame(of window: Window) -> CGRect? {
        guard let origin = point(window.element, kAXPositionAttribute), let size = size(window.element, kAXSizeAttribute) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    /// Puts it at `rect`, in Accessibility's terms. Says whether it could be
    /// resized: some windows are one size only, and are only moved.
    @discardableResult
    static func move(_ window: Window, to rect: CGRect) async -> Bool {
        // Some apps animate, and fight, a resize while this is on — the one
        // VoiceOver uses — so it's off while the window moves.
        let enhanced = bool(window.app, "AXEnhancedUserInterface")
        if enhanced == true { AXUIElementSetAttributeValue(window.app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer {
            if enhanced == true { AXUIElementSetAttributeValue(window.app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        }

        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(window.element, kAXSizeAttribute as CFString, &settable)
        let resizable = settable.boolValue
        // Sized, moved, then sized again: a window going to a smaller screen
        // can't take its new size until it's there, nor a bigger one its
        // place until it's that size.
        if resizable { set(window.element, kAXSizeAttribute, size: rect.size) }
        set(window.element, kAXPositionAttribute, point: rect.origin)
        if resizable { set(window.element, kAXSizeAttribute, size: rect.size) }

        // Moved to another screen, a window can be held to the old one's size
        // until it has settled on the new: then it's put right.
        for _ in 0..<2 {
            try? await Task.sleep(for: .milliseconds(120))
            guard let now = frame(of: window), !close(now, rect, resizable: resizable) else { break }
            set(window.element, kAXPositionAttribute, point: rect.origin)
            if resizable { set(window.element, kAXSizeAttribute, size: rect.size) }
        }
        return resizable
    }

    /// Where it is, near enough where it was put: some apps round a size —
    /// a terminal to whole lines — so a few points either way is fine.
    private static func close(_ a: CGRect, _ b: CGRect, resizable: Bool) -> Bool {
        let near: (CGFloat, CGFloat) -> Bool = { abs($0 - $1) <= 4 }
        guard near(a.minX, b.minX), near(a.minY, b.minY) else { return false }
        return !resizable || (abs(a.width - b.width) <= 24 && abs(a.height - b.height) <= 24)
    }

    // MARK: - Accessibility values

    private static func element(_ from: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(from, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// The first of a list of elements: an app's frontmost window.
    private static func first(_ from: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(from, attribute as CFString, &value) == .success,
              let list = value as? [AnyObject], let item = list.first, CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
        return (item as! AXUIElement)
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        var point = CGPoint.zero
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func set(_ element: AXUIElement, _ attribute: String, point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(element, attribute as CFString, value) }
    }

    private static func set(_ element: AXUIElement, _ attribute: String, size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, attribute as CFString, value) }
    }
}
