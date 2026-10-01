import AppKit
import KeybowKit

/// Moves and sizes the window you're working in — the focused window of the
/// app in front — to a part of a screen, or to another screen:
///
///   Windows [Window]
///      1. Left
///      2. Right
///      3. Top left
///      4. Full
///   Next screen [Window, screen: next]
///   Left on 2 [Window, place: left, screen: 2]
///
/// `place` is full, left, right, top, bottom, topLeft, topRight, bottomLeft
/// or bottomRight — else the label, when it names one. Halves fill the
/// height or the width; quarters are half of each. All within the screen less
/// the menu bar, and the Dock when it's always shown. `screen` is next,
/// previous, main, a number from the left, or part of a display's name; with
/// a screen but no place, the window keeps its share of the screen. "Full" is
/// filling the screen, not macOS's full-screen mode.
public final class WindowModule: KeybowModule, @unchecked Sendable {
    public static let type = "window"

    public let manifest = ModuleManifest(
        id: "window", name: "Windows",
        actionTypes: [
            ModuleActionType(
                type: type, title: "Move a window", keywords: ["Window", "Arrange"], symbol: "macwindow",
                fields: [
                    ModuleField(key: "place", title: "Place",
                                kind: .choice(WindowGeometry.Place.allCases.map(\.rawValue)),
                                hint: "else the label — else where it is now", help: """
                        Where on the screen: full, a half — left, right, top, bottom — or a quarter — topLeft, \
                        topRight, bottomLeft, bottomRight. Halves fill the height or the width. All within the \
                        screen less the menu bar and an always-shown Dock. Left out, a label like “Top left” says.
                        Example: topLeft
                        """),
                    ModuleField(key: "screen", title: "Screen", hint: "next, previous, main, 2, or a name — else its own",
                                help: """
                        Which screen to put it on: next or previous, main (the one with the menu bar), a number \
                        counting from the left, or part of a display's name. With no place, the window keeps its \
                        share of the screen.
                        Example: next
                        """),
                ]),
        ])

    public init() {}

    public func start(host: ModuleHost) {}

    /// What's asked for: a place, from the field or else the label, and a screen.
    static func request(_ request: ModuleRequest) -> (place: WindowGeometry.Place?, screen: String?, problem: String?) {
        var place: WindowGeometry.Place?
        if let field = request.field("place") {
            guard let named = WindowGeometry.Place(words: field) else {
                return (nil, nil, "“\(field)” isn't a place: full, left, right, top, bottom, topLeft, topRight, "
                            + "bottomLeft or bottomRight.")
            }
            place = named
        } else {
            place = WindowGeometry.Place(words: request.leaf)
        }
        var screen = request.field("screen")
        // A label can say "Next screen" too.
        if place == nil, screen == nil, ["next", "previous"].contains(where: { request.leaf.lowercased().hasPrefix($0) }) {
            screen = request.leaf.lowercased().hasPrefix("next") ? "next" : "previous"
        }
        if place == nil, screen == nil {
            return (nil, nil, "Say where: a place like left or topRight — or a label that says it — or a screen.")
        }
        return (place, screen, nil)
    }

    public func problem(with request: ModuleRequest) -> String? {
        Self.request(request).problem
    }

    public func summary(of request: ModuleRequest, now: Date) -> ModuleSummary {
        let (place, screen, _) = Self.request(request)
        var details: [String] = []
        if let screen { details.append(Int(screen) != nil ? "on screen \(screen)" : "on the \(screen) screen") }
        return ModuleSummary(verb: "Move window", subject: place?.title ?? "to another screen", details: details)
    }

    public func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome {
        let (place, screenSpec, problem) = Self.request(request)
        if let problem { return .failure(problem) }
        return await Self.move(place: place, screenSpec: screenSpec)
    }

    @MainActor
    private static func move(place: WindowGeometry.Place?, screenSpec: String?) async -> ActionOutcome {
        do {
            let window = try WindowMover.front()
            let mainHeight = WindowMover.mainHeight
            let screens = WindowMover.screens
            guard let axFrame = WindowMover.frame(of: window) else {
                return .failure("\(window.appName)'s window won't say where it is")
            }
            let frame = WindowGeometry.flipped(axFrame, mainHeight: mainHeight)
            guard let current = WindowGeometry.screen(holding: frame, in: screens) else {
                return .failure("No screen is connected")
            }
            let target = try WindowGeometry.screen(screenSpec, from: current, in: screens)
            let rect = place.map { WindowGeometry.rect(for: $0, in: target.visible) }
                ?? WindowGeometry.carried(frame, from: current.visible, to: target.visible)
            let resized = await WindowMover.move(window, to: WindowGeometry.flipped(rect, mainHeight: mainHeight))

            let whereTo = (place?.title ?? "Moved") + (target != current ? " on \(target.name)" : "")
            return resized ? .success(whereTo, window.appName)
                : .success(whereTo, "\(window.appName)'s window is one size, so it was only moved.")
        } catch let error as ModuleError {
            // Asked once, in the app, so it's in System Settings' list.
            if error.message.hasPrefix("KeybowNotes needs Accessibility"), Bundle.main.bundleIdentifier != nil {
                let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
            }
            return .failure(error.message, error.detail)
        } catch {
            return .failure("\(error)")
        }
    }
}
