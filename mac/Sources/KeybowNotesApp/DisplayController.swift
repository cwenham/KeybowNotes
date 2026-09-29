import AppKit
import KeybowKit
import WebKit

/// Shows what a Display action asks for: a HUD panel above everything, sized
/// to its text, on the overlay's screen. Markdown is drawn in the HUD's own
/// style; an HTML document as a web page would be, but with its scripts off.
/// Links open in the default browser. It never takes focus: Esc closes it
/// from any app, when KeybowNotes has Accessibility access, and a click lets
/// it take keys itself.
@MainActor
final class DisplayController: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// The widest a display gets: text wider than this wraps.
    static let widest: CGFloat = 620
    static let narrowest: CGFloat = 260
    static let padding: CGFloat = 20
    static let buttonBarHeight: CGFloat = 48
    /// Room on the right for the close button, when there are no others.
    static let closeRoom: CGFloat = 16

    /// Where it goes: the overlay's screen.
    var screen: () -> NSScreen = { NSScreen.main ?? NSScreen.screens[0] }
    /// Called as it appears, so the overlay can make way.
    var onShow: (() -> Void)?

    private var panel: DisplayPanel?
    private var webView: DisplayWebView?
    private var display: ModuleDisplay?
    private var continuation: CheckedContinuation<ModuleDisplay.Result, Never>?
    private var fadeTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var loaded = false

    /// Shows it, replacing any other, and waits for it to go away.
    func show(_ display: ModuleDisplay) async -> ModuleDisplay.Result {
        finish(.dismissed, quickly: true)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            present(display)
        }
    }

    // MARK: - Showing

    private func present(_ display: ModuleDisplay) {
        self.display = display
        loaded = false
        let width = min(Self.widest, screen().visibleFrame.width * 0.5)
        let textWidth = width - Self.padding * 2 - (display.buttons.isEmpty ? Self.closeRoom : 0)

        let panel = DisplayPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 120))
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        // A mask, not a layer's corner radius: the window's edge follows it.
        background.maskImage = OverlayController.roundedMask(radius: 14)
        panel.contentView = background

        let configuration = WKWebViewConfiguration()
        // Its own text, and values placed in it, could hold a script: none run.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // Laid out at its widest, and shortest, to begin with: text wraps only
        // where it must, and the page is no taller than what's on it.
        let web = DisplayWebView(frame: NSRect(x: Self.padding, y: Self.padding, width: textWidth, height: 1),
                                 configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        background.addSubview(web)
        self.webView = web
        self.panel = panel

        if display.buttons.isEmpty {
            let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!,
                                 target: self, action: #selector(closeChosen))
            close.isBordered = false
            close.contentTintColor = .secondaryLabelColor
            close.toolTip = "Close (Esc)"
            close.identifier = NSUserInterfaceItemIdentifier("close")
            background.addSubview(close)
        } else {
            for button in display.buttons {
                let control = NSButton(title: button == .ok ? "OK" : "Cancel", target: self,
                                       action: button == .ok ? #selector(okChosen) : #selector(cancelChosen))
                control.bezelStyle = .rounded
                control.controlSize = .large
                if button == .ok { control.keyEquivalent = "\r" }
                if button == .cancel { control.keyEquivalent = "\u{1b}" }
                control.identifier = NSUserInterfaceItemIdentifier(button.rawValue)
                background.addSubview(control)
            }
        }

        web.loadHTMLString(Self.page(for: display.content, width: textWidth), baseURL: nil)
        // A page that's slow to finish — a picture from far away — shows anyway.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.webView === web, !self.loaded else { return }
            self.sizeAndShow(contentSize: NSSize(width: textWidth, height: 200))
        }
    }

    /// The page: Markdown in the HUD's style; an HTML document as it is, over
    /// a dark page, in a width that fits.
    static func page(for content: ModuleDisplay.Content, width: CGFloat) -> String {
        let base = """
            <style>
            :root { color-scheme: dark; }
            /* No scroll bar while it's measured: one would take width, and wrap it again. */
            html { overflow: hidden; }
            html, body { margin: 0; background: transparent; }
            body { font: 15px/1.45 -apple-system, sans-serif; color: rgba(255,255,255,0.92); -webkit-font-smoothing: antialiased; }
            a { color: #7ab7ff; }
            h1, h2, h3 { font-weight: 600; margin: 0.2em 0 0.4em; line-height: 1.25; }
            h1 { font-size: 21px; } h2 { font-size: 18px; } h3 { font-size: 16px; }
            ul, ol { margin: 0.3em 0; padding-left: 1.4em; }
            li { margin: 0.15em 0; }
            #keybow-content { display: inline-block; max-width: \(Int(width))px; overflow-wrap: break-word; }
            #keybow-content > div:has(> br:only-child) { height: 0.6em; }
            </style>
            """
        switch content {
        case .markdown(let text):
            return "<!DOCTYPE html><html><head><meta charset=\"utf-8\">\(base)</head>"
                + "<body><div id=\"keybow-content\">\(NotesHTML.from(markdown: text, links: true))</div></body></html>"
        case .html(let document):
            // Its own styles come after these, so they win.
            if let head = document.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                return document.replacingCharacters(in: head.upperBound..<head.upperBound, with: base)
            }
            return base + document
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, !loaded else { return }
        // Measured by the app, not the page: its scripts are off, ours aren't.
        let measure = """
            (() => { const c = document.getElementById('keybow-content');
                     const w = c ? Math.ceil(c.getBoundingClientRect().width) : document.documentElement.scrollWidth;
                     return [w, Math.ceil(document.documentElement.scrollHeight)]; })()
            """
        webView.evaluateJavaScript(measure) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, webView === self.webView else { return }
                let numbers = (result as? [NSNumber])?.map { CGFloat($0.doubleValue) } ?? []
                let size = numbers.count == 2 ? NSSize(width: numbers[0], height: numbers[1]) : NSSize(width: 400, height: 200)
                self.sizeAndShow(contentSize: size)
            }
        }
    }

    private func sizeAndShow(contentSize: NSSize) {
        guard let panel, let webView, let display, let background = panel.contentView else { return }
        let firstTime = !loaded
        loaded = true
        let area = screen().visibleFrame
        let buttons = display.buttons.isEmpty ? 0 : Self.buttonBarHeight
        let closeRoom = display.buttons.isEmpty ? Self.closeRoom : 0
        let isDocument: Bool
        if case .html = display.content { isDocument = true } else { isDocument = false }
        let textWidth = isDocument ? min(Self.widest, area.width * 0.5) - Self.padding * 2 - closeRoom : contentSize.width
        let tallest = area.height * 0.7 - buttons
        let scrolls = contentSize.height > tallest
        // Taller than there's room for: it scrolls, and the scroll bar may take width.
        let scroller = scrolls && NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let pageWidth = textWidth + 1 + scroller
        let width = max(Self.narrowest, pageWidth + Self.padding * 2 + closeRoom)
        let pageHeight = min(contentSize.height + 1, tallest)
        let height = pageHeight + Self.padding * 2 + buttons
        if scrolls { webView.evaluateJavaScript("document.documentElement.style.overflow = 'auto'") }

        // Centred, a little above the middle: clear of the overlay below.
        let origin = NSPoint(x: (area.midX - width / 2).rounded(), y: (area.minY + area.height * 0.55 - height / 2).rounded())
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        webView.frame = NSRect(x: Self.padding, y: Self.padding + buttons, width: width - Self.padding * 2 - closeRoom,
                               height: pageHeight)

        var right = width - 16
        for case let button as NSButton in background.subviews.reversed() {
            if button.identifier?.rawValue == "close" {
                button.frame = NSRect(x: width - 26, y: height - 26, width: 18, height: 18)
            } else {
                button.sizeToFit()
                let buttonWidth = max(84, button.frame.width)
                right -= buttonWidth
                button.frame = NSRect(x: right, y: 12, width: buttonWidth, height: button.frame.height)
                right -= 8
            }
        }

        guard firstTime else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        onShow?()
        watchKeys()
        if display.buttons.isEmpty { fade(after: display.fadeAfter) }
        // Development builds only: choose OK or Cancel by itself, for testing
        // what follows without a click.
        if Bundle.main.bundleIdentifier == nil, !display.buttons.isEmpty,
           let answer = ProcessInfo.processInfo.environment["KEYBOW_DEBUG_DISPLAY_ANSWER"] {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, self.display == display else { return }
                self.finish(answer == "cancel" ? .cancel : .ok, quickly: true)
            }
        }
    }

    // MARK: - Going away

    private func fade(after seconds: TimeInterval) {
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.finish(.dismissed)
        }
    }

    @objc private func okChosen() { finish(.ok, quickly: true) }
    @objc private func cancelChosen() { finish(.cancel, quickly: true) }
    @objc private func closeChosen() { finish(.dismissed, quickly: true) }

    private func escape() {
        let hasCancel = display?.buttons.contains(.cancel) ?? false
        finish(hasCancel ? .cancel : .dismissed, quickly: true)
    }

    private func finish(_ result: ModuleDisplay.Result, quickly: Bool = false) {
        fadeTask?.cancel()
        fadeTask = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        if let panel {
            let web = webView
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = quickly ? 0.15 : 0.6
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    web?.navigationDelegate = nil
                }
            })
        }
        panel = nil
        webView = nil
        display = nil
        continuation?.resume(returning: result)
        continuation = nil
    }

    /// Esc from anywhere — seen, not taken, and only with Accessibility
    /// access — and Esc or Return once it has keys itself.
    private func watchKeys() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.escape() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let (isEscape, window) = (event.keyCode == 53, event.windowNumber)
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard isEscape, let self, window == self.panel?.windowNumber else { return false }
                self.escape()
                return true
            }
            return taken ? nil : event
        }) {
            monitors.append(local)
        }
    }

    // MARK: - Links

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // A link chosen opens in the browser; nothing else leaves the page.
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
            return
        }
        let first = !loaded && navigationAction.targetFrame?.isMainFrame == true
        let frame = navigationAction.targetFrame?.isMainFrame == false
        decisionHandler(first || frame ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target="_blank": the browser too, and only when chosen.
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}

/// Floats above everything, on every Space, and takes keys only when clicked:
/// it never activates the app.
final class DisplayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        // Never shown — it has no title bar — but it names the window to tools.
        title = "KeybowNotes Display"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A link or button works on the first click, though the panel isn't key.
final class DisplayWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
