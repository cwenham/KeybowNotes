import AppKit
import KeybowKit
import SwiftUI

/// What the overlay is showing. Drawn by `OverlayView`; driven by `OverlayController`.
@MainActor @Observable
final class OverlayModel {
    enum Outcome: Equatable {
        /// A dry run: what would have happened.
        case previewed(ActionSummary, path: String)
        case running(ActionSummary, path: String)
        case finished(ActionOutcome, summary: ActionSummary, warnings: [String])
        /// The action couldn't even be attempted: a value missing from the config.
        case refused(String, summary: ActionSummary)
        case cleared(NavigatorEvent.ClearReason)
    }

    struct Notice: Equatable {
        let text: String
        let symbol: String
    }

    var snapshot = SelectionSnapshot.idle
    /// The action waiting in the commit window, described.
    var pendingSummary: ActionSummary?
    /// How the last selection ended; shown briefly before fading.
    var outcome: Outcome?
    var notice: Notice?
}

/// Where the overlay appears.
enum OverlayPlacement {
    case screenWithCursor
    case mainScreen
}

/// A HUD panel in the style of the volume overlay: it floats above everything,
/// on every Space and over full-screen apps, and never takes focus or clicks.
final class OverlayPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    let model = OverlayModel()
    var placement: OverlayPlacement

    /// When set, each state the overlay shows is also written here as a PNG,
    /// with the window's frame logged — a check that needs no screen recording.
    var debugDirectory: URL?

    private let config: KeybowConfig
    private let panel = OverlayPanel()
    private let hosting: NSHostingView<OverlayView>
    private var hideTask: Task<Void, Never>?
    private var debugCount = 0
    /// True once the device has answered on the current connection. An open
    /// port alone proves nothing: a board stuck at its REPL opens fine and
    /// then says nothing, and announcing every retry would flash the overlay.
    private var deviceAnswering = false

    private static let cornerRadius: CGFloat = 18

    init(config: KeybowConfig, placement: OverlayPlacement) {
        self.config = config
        self.placement = placement

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = Self.roundedMask(radius: Self.cornerRadius)

        hosting = NSHostingView(rootView: OverlayView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: blur.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        panel.contentView = blur
        panel.appearance = NSAppearance(named: .vibrantDark)
    }

    // MARK: - Inputs

    func handle(_ snapshot: SelectionSnapshot) {
        model.snapshot = snapshot
        if let selection = snapshot.selection, snapshot.pending != nil, selection.action != nil {
            model.pendingSummary = ActionSummary(selection: selection, config: config)
        } else {
            model.pendingSummary = nil
        }

        if !snapshot.isIdle {
            model.outcome = nil
            model.notice = nil
            show()
        } else if model.outcome == nil && model.notice == nil {
            // An outcome usually follows within a moment; don't blink out before it.
            hide(after: 0.3)
        }
    }

    func handle(_ event: NavigatorEvent) {
        switch event {
        case .cleared(let reason) where reason != .completed:
            model.outcome = .cleared(reason)
            show()
            hide(after: 1.0)
        default:
            break
        }
    }

    func handle(_ event: KeybowEvent) {
        switch event {
        case .connected:
            deviceAnswering = false
        case .message:
            if !deviceAnswering {
                deviceAnswering = true
                flashNotice("Keybow ready", symbol: "cable.connector")
            }
        case .disconnected(let reason):
            if deviceAnswering && reason != "stopped" {
                flashNotice("Keybow disconnected — \(reason)", symbol: "cable.connector.slash")
            }
            deviceAnswering = false
        }
    }

    // MARK: - Actions

    func showPreview(_ summary: ActionSummary, path: String) {
        present(.previewed(summary, path: path), for: 2.6)
    }

    func showRunning(_ summary: ActionSummary, path: String) {
        // Stays until the result arrives; the long timeout is only a backstop.
        present(.running(summary, path: path), for: 30)
    }

    func showFinished(_ outcome: ActionOutcome, summary: ActionSummary, warnings: [String]) {
        // A new selection may have started while the action ran; don't cover it.
        guard model.snapshot.isIdle else { return }
        present(.finished(outcome, summary: summary, warnings: warnings),
                for: outcome.succeeded && warnings.isEmpty ? 2.6 : 6)
    }

    func showRefused(_ reason: String, summary: ActionSummary) {
        present(.refused(reason, summary: summary), for: 6)
    }

    private func present(_ outcome: OverlayModel.Outcome, for duration: TimeInterval) {
        model.outcome = outcome
        model.notice = nil
        show()
        hide(after: duration)
    }

    /// Something to show without a selection, e.g. from the menu.
    func flashNotice(_ text: String, symbol: String) {
        guard model.snapshot.isIdle else { return }
        if debugDirectory != nil { print("notice: \(text)") }
        model.outcome = nil
        model.notice = .init(text: text, symbol: symbol)
        show()
        hide(after: 1.6)
    }

    // MARK: - Showing and hiding

    private func show() {
        hideTask?.cancel()
        hideTask = nil
        fitAndPlace()
        // SwiftUI settles its size on the next pass; fit again once it has.
        DispatchQueue.main.async { [weak self] in self?.fitAndPlace() }

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        if debugDirectory != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.writeDebugSnapshot() }
        }
    }

    private func writeDebugSnapshot() {
        guard let directory = debugDirectory, panel.isVisible else { return }
        debugCount += 1
        let frame = panel.frame
        let screen = panel.screen?.localizedName ?? "no screen"
        print(String(format: "overlay #%d: frame x=%.0f y=%.0f w=%.0f h=%.0f on %@, alpha %.2f, level %d",
                     debugCount, frame.minX, frame.minY, frame.width, frame.height, screen,
                     panel.alphaValue, panel.level.rawValue))

        // Behind-window blur only exists on screen, so paint a stand-in backdrop.
        let bounds = hosting.bounds
        guard let content = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        hosting.cacheDisplay(in: bounds, to: content)
        let image = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor(white: 0.16, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
            content.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: nil)
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let url = directory.appendingPathComponent(String(format: "overlay-%02d.png", debugCount))
        try? png.write(to: url)
    }

    private func hide(after delay: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.fadeOut()
        }
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideTask != nil, self.model.snapshot.isIdle else { return }
                self.panel.orderOut(nil)
                self.model.outcome = nil
                self.model.notice = nil
            }
        })
    }

    private func fitAndPlace() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }

        let screen = targetScreen()
        let area = screen.visibleFrame
        // Centred, a little up from the bottom — where the volume HUD used to live.
        let origin = NSPoint(
            x: (area.midX - size.width / 2).rounded(),
            y: (area.minY + area.height * 0.14).rounded()
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func targetScreen() -> NSScreen {
        switch placement {
        case .mainScreen:
            // NSScreen.main is the screen of the focused window; the first
            // screen is the one with the menu bar, which is what "main" means here.
            return NSScreen.screens.first ?? NSScreen.main!
        case .screenWithCursor:
            let cursor = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) }
                ?? NSScreen.main ?? NSScreen.screens[0]
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
