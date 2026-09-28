import AppKit
import ApplicationServices
import KeybowKit

/// The text selected in the app in front, for `{{selection}}`. Asked of the
/// app through the accessibility API; apps that don't answer (Chrome, Electron
/// apps, some Java ones) can be sent ⌘C instead, with the clipboard put back
/// afterwards. Both need Accessibility access in Privacy & Security.
@MainActor
enum SelectedText {
    enum Outcome: Equatable {
        case text(String)
        case nothingSelected
        case notAllowed
    }

    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// macOS's own prompt, which offers to open System Settings. It only
    /// appears once; after that, this just opens the Accessibility pane.
    static func requestAccess() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) {
            openSettings()
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func read(copyIfNeeded: Bool) async -> Outcome {
        guard isAllowed else { return .notAllowed }
        switch askFocusedElement() {
        case .some(let text):
            // The app answered. Empty means nothing is selected — no need to copy,
            // which would only beep.
            return text.isEmpty ? .nothingSelected : .text(text)
        case .none:
            guard copyIfNeeded, let text = await copySelection(), !text.isEmpty else { return .nothingSelected }
            return .text(text)
        }
    }

    // MARK: - Asking

    /// The focused element's selected text; nil when the app doesn't say.
    private static func askFocusedElement() -> String? {
        let system = AXUIElementCreateSystemWide()
        // A hung app mustn't hang the key press.
        AXUIElementSetMessagingTimeout(system, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    // MARK: - Copying

    /// Sends ⌘C, waits for the clipboard to change, reads it, then puts back
    /// what was there before. Nil if the app copied nothing.
    private static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = PasteboardContents(pasteboard)
        let before = pasteboard.changeCount

        Keystroke.press(Keystroke.c, with: .maskCommand)
        var waited = 0
        while pasteboard.changeCount == before, waited < 400 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        guard pasteboard.changeCount != before else { return nil }
        // The count moves when the app clears the clipboard; give it a moment
        // to finish writing.
        try? await Task.sleep(for: .milliseconds(30))
        let text = pasteboard.string(forType: .string)
        saved.restore(to: pasteboard)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
