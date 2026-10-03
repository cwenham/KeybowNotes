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
    public static func insert(_ text: String, format: TextFormat = .plain) async throws {
        guard AXIsProcessTrusted() else { throw Failure.notAllowed }
        let pasteboard = NSPasteboard.general
        let saved = PasteboardContents(pasteboard)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        PasteboardText(text, format: format).write(to: item)
        item.setData(Data(), forType: PasteboardContents.transient)
        pasteboard.writeObjects([item])
        let ours = pasteboard.changeCount

        Keystroke.press(Keystroke.v, with: .maskCommand)
        try? await Task.sleep(for: settleTime)
        // Only if it's still ours: something else may have copied meanwhile.
        if pasteboard.changeCount == ours { saved.restore(to: pasteboard) }
    }
}

/// How text goes on the clipboard: as itself, or formatted too.
public enum TextFormat: String, CaseIterable, Sendable {
    /// Formatted when it's written in Markdown: a heading, a list, bold or
    /// italic, a link.
    case auto
    /// Formatted, from Markdown, always.
    case rich
    /// The text alone.
    case plain
}

/// Text for the clipboard. Always there as plain text — Markdown as written,
/// for a plain field or a Markdown editor — and, formatted, as HTML and RTF
/// too, which Mail, Notes and Pages paste as headings, lists and bold.
public struct PasteboardText {
    public let plain: String
    public let html: String?
    public let rtf: Data?

    @MainActor
    public init(_ text: String, format: TextFormat) {
        plain = text
        let body = NotesHTML.from(markdown: text, links: true)
        guard format == .rich || (format == .auto && Self.isFormatted(body)) else {
            html = nil
            rtf = nil
            return
        }
        // The system font rather than a browser's Times, at the size the
        // pasted-into app gives text.
        let page = "<html><head><meta charset=\"utf-8\"></head>"
            + "<body style=\"font-family: -apple-system, 'Helvetica Neue', sans-serif\">\(body)</body></html>"
        html = page
        let attributed = try? NSAttributedString(
            data: Data(page.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
        rtf = attributed.flatMap {
            try? $0.data(from: NSRange(location: 0, length: $0.length),
                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        }
    }

    /// Markdown that came out formatted: more than plain lines of text.
    static func isFormatted(_ html: String) -> Bool {
        ["<h1>", "<h2>", "<h3>", "<ul>", "<ol>", "<b>", "<i>", "<a href"].contains { html.contains($0) }
    }

    public func write(to item: NSPasteboardItem) {
        item.setString(plain, forType: .string)
        if let html { item.setString(html, forType: .html) }
        if let rtf { item.setData(rtf, forType: .rtf) }
    }
}

/// Puts text at the cursor in the app in front without going near the
/// clipboard, so a clipboard manager's history stays clean. First by asking
/// the app, through accessibility, to replace its selection with the text —
/// exact and instant where it works, as in standard Mac text views. Apps that
/// don't take it that way get it typed, a character at a time, which works
/// nearly everywhere and doesn't depend on the keyboard layout. Both need
/// Accessibility access.
public enum DirectInsertion {
    public enum Method: String, CaseIterable, Sendable {
        /// Accessibility where the app takes it, else typing.
        case automatic = ""
        case accessibility
        case typing
    }

    public enum Failure: Error, Equatable {
        case notAllowed
        /// `via: accessibility`, and the app didn't take it.
        case refused
    }

    /// Gaps between typed characters, so a busy app doesn't drop any.
    static let keystrokeGap: Duration = .milliseconds(2)

    /// Inserts it, and says which way it went.
    @MainActor
    @discardableResult
    public static func insert(_ text: String, via method: Method) async throws -> Method {
        guard AXIsProcessTrusted() else { throw Failure.notAllowed }
        if method != .typing {
            if replaceSelection(with: text) { return .accessibility }
            if method == .accessibility { throw Failure.refused }
        }
        await type(text)
        return .typing
    }

    // MARK: - Accessibility

    /// Sets the focused element's selected text, then checks it really
    /// changed: some apps — Chrome, Electron — report success and do nothing.
    /// Declines, touching nothing, when it can't tell, so typing can't insert
    /// the text a second time.
    @MainActor
    static func replaceSelection(with text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue,
              let countBefore = characterCount(element),
              let selection = selectedRange(element) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success,
              let countAfter = characterCount(element) else { return false }

        if countAfter != countBefore { return true }
        // The same length in and out: see whether the cursor moved past it.
        let length = (text as NSString).length
        guard length == selection.length, length > 0, let after = selectedRange(element) else { return false }
        return after.location == selection.location + length && after.length == 0
    }

    private static func characterCount(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success,
           let number = value as? Int {
            return number
        }
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let string = value as? String else { return nil }
        return (string as NSString).length
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    // MARK: - Typing

    enum Keystroke: Equatable {
        case characters(String)
        case newLine
    }

    /// One key press per character — some apps take only the first of several
    /// — and Return for a new line, which a text field needs as a key.
    static func keystrokes(for text: String) -> [Keystroke] {
        text.map { character in
            character == "\n" || character == "\r\n" || character == "\r" ? .newLine : .characters(String(character))
        }
    }

    @MainActor
    static func type(_ text: String) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keystroke in keystrokes(for: text) {
            switch keystroke {
            case .newLine:
                KeybowKit.Keystroke.press(0x24, with: [])        // kVK_Return
            case .characters(let characters):
                let units = Array(characters.utf16)
                for isDown in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
                    event?.flags = []
                    event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    event?.post(tap: .cghidEventTap)
                }
            }
            try? await Task.sleep(for: keystrokeGap)
        }
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
