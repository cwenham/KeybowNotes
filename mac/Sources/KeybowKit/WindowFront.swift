import AppKit

extension NSWindow {
    /// Brings a menu-bar app's window to the front of everything. Since
    /// macOS 14 activating is a request, which the app in use can turn down;
    /// then a window ordered front rises only among this app's own, and opens
    /// behind the app in use. So it's ordered front regardless — above other
    /// apps' windows, active or not — made key, and the app asked to activate,
    /// which, when it's allowed, sends typing to it too.
    @MainActor
    public func bringToFront() {
        NSApp.activate()
        orderFrontRegardless()
        makeKey()
    }
}
