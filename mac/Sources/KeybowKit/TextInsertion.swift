import AppKit
import ApplicationServices

/// Puts text at the cursor in the app in front, by pasting it and then
/// putting the clipboard back. Pasting works in nearly every app — Chrome,
/// Electron apps, Terminal, JetBrains editors — where setting text through the
/// accessibility API often silently doesn't, and it replaces a selection just
/// as typing would. Pressing ⌘V needs Accessibility access.
public enum TextInsertion {
    public enum Failure: Error, Equatable {
        case notAllowed
    }

    /// How long the app gets to read the clipboard before it's put back. Apps
    /// read it when they handle the ⌘V, which can take a moment; too soon and
    /// they'd paste the old contents.
    public static let settleTime: Duration = .milliseconds(400)

    @MainActor
    public static func insert(_ text: String) async throws {
        guard AXIsProcessTrusted() else { throw Failure.notAllowed }
        let pasteboard = NSPasteboard.general
        let saved = PasteboardContents(pasteboard)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: PasteboardContents.transient)
        pasteboard.writeObjects([item])
        let ours = pasteboard.changeCount

        Keystroke.press(Keystroke.v, with: .maskCommand)
        try? await Task.sleep(for: settleTime)
        // Only if it's still ours: something else may have copied meanwhile.
        if pasteboard.changeCount == ours { saved.restore(to: pasteboard) }
    }
}

/// Everything on a pasteboard, to put back after borrowing it.
public struct PasteboardContents {
    /// Marks contents that clipboard managers shouldn't record — nspasteboard.org.
    public static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    public init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Puts it all back, marked transient: a clipboard manager already has it.
    public func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        restored[0].setData(Data(), forType: Self.transient)
        pasteboard.writeObjects(restored)
    }
}

/// A key press sent to the app in front.
public enum Keystroke {
    public static let c: CGKeyCode = 0x08     // kVK_ANSI_C
    public static let v: CGKeyCode = 0x09     // kVK_ANSI_V

    public static func press(_ key: CGKeyCode, with flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
