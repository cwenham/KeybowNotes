import AppKit
import KeybowKit

extension StreamDeckDevices {
    /// Elgato's own app, which draws on the keys too when it's running.
    public static var elgatoAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.elgato.StreamDeck").isEmpty
    }
}
