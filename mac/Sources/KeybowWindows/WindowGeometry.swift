import CoreGraphics
import Foundation
import KeybowKit

/// Where a window goes, worked out from screens' areas alone — no windows,
/// no Accessibility — so it can be tested.
///
/// Rectangles are in AppKit's terms, as `NSScreen` gives them: from the
/// bottom-left of the main screen, upwards. Accessibility's are from its
/// top-left, downwards; `flipped(_:mainHeight:)` turns one into the other.
public enum WindowGeometry {
    /// Where on a screen.
    public enum Place: String, CaseIterable, Sendable {
        case full, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight

        public var title: String {
            switch self {
            case .full: return "Full screen"
            case .left: return "Left half"
            case .right: return "Right half"
            case .top: return "Top half"
            case .bottom: return "Bottom half"
            case .topLeft: return "Top left"
            case .topRight: return "Top right"
            case .bottomLeft: return "Bottom left"
            case .bottomRight: return "Bottom right"
            }
        }

        /// From a field or a label, any case and spacing: `topLeft`, `Top
        /// left`, `top-left quarter`, `Left half`, `Upper right`, `Full screen`,
        /// `Maximise`. Nil when it names no place.
        public init?(words text: String) {
            var key = text.lowercased().filter { $0.isLetter }
            for filler in ["quarter", "half", "corner", "side", "screen", "window"] where key.hasSuffix(filler) && key != filler {
                key.removeLast(filler.count)
            }
            key = key.replacingOccurrences(of: "upper", with: "top").replacingOccurrences(of: "lower", with: "bottom")
            switch key {
            case "full", "fill", "whole", "all", "maximise", "maximize", "max", "fullscreen": self = .full
            case "left", "west": self = .left
            case "right", "east": self = .right
            case "top", "north": self = .top
            case "bottom", "south": self = .bottom
            case "topleft", "lefttop": self = .topLeft
            case "topright", "righttop": self = .topRight
            case "bottomleft", "leftbottom": self = .bottomLeft
            case "bottomright", "rightbottom": self = .bottomRight
            default: return nil
            }
        }
    }

    /// A screen, as macOS describes it.
    public struct Screen: Equatable, Sendable {
        public let name: String
        public let frame: CGRect
        /// Less the menu bar, and the Dock when it's always shown.
        public let visible: CGRect

        public init(name: String, frame: CGRect, visible: CGRect) {
            self.name = name
            self.frame = frame
            self.visible = visible
        }
    }

    /// The part of `area` a place takes, in whole points. An odd width or
    /// height goes to the right or upper part, so halves always meet.
    public static func rect(for place: Place, in area: CGRect) -> CGRect {
        let area = area.integral
        let leftWidth = (area.width / 2).rounded(.down)
        let lowerHeight = (area.height / 2).rounded(.down)
        let left = CGRect(x: area.minX, y: area.minY, width: leftWidth, height: area.height)
        let right = CGRect(x: area.minX + leftWidth, y: area.minY, width: area.width - leftWidth, height: area.height)
        let lower = CGRect(x: area.minX, y: area.minY, width: area.width, height: lowerHeight)
        let upper = CGRect(x: area.minX, y: area.minY + lowerHeight, width: area.width, height: area.height - lowerHeight)
        switch place {
        case .full: return area
        case .left: return left
        case .right: return right
        case .top: return upper
        case .bottom: return lower
        case .topLeft: return left.intersection(upper)
        case .topRight: return right.intersection(upper)
        case .bottomLeft: return left.intersection(lower)
        case .bottomRight: return right.intersection(lower)
        }
    }

    /// The screens in order, left to right — top to bottom where they're
    /// stacked — which is how they're numbered: `screen: 1` is the leftmost.
    public static func ordered(_ screens: [Screen]) -> [Screen] {
        screens.sorted { a, b in
            a.frame.minX != b.frame.minX ? a.frame.minX < b.frame.minX : a.frame.maxY > b.frame.maxY
        }
    }

    /// The screen a window is on: the one holding most of it, else the nearest.
    public static func screen(holding window: CGRect, in screens: [Screen]) -> Screen? {
        let covering = screens.max { a, b in area(a.frame.intersection(window)) < area(b.frame.intersection(window)) }
        if let covering, area(covering.frame.intersection(window)) > 0 { return covering }
        return screens.min { distance(window, $0.frame) < distance(window, $1.frame) }
    }

    /// The screen `spec` names, from the window's own: `next` and `previous`
    /// (round the ends), `main` (the one with the menu bar), a number from
    /// the left, or part of a display's name. Nil or empty is its own.
    public static func screen(_ spec: String?, from current: Screen, in screens: [Screen]) throws -> Screen {
        let ordered = ordered(screens)
        let text = (spec ?? "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !["this", "same", "current"].contains(text.lowercased()) else { return current }
        let here = ordered.firstIndex(of: current) ?? 0
        switch text.lowercased().filter({ $0.isLetter }) {
        case "next", "nextscreen", "nextdisplay", "nextmonitor":
            return ordered[(here + 1) % ordered.count]
        case "previous", "prev", "previousscreen", "previousdisplay", "previousmonitor":
            return ordered[(here + ordered.count - 1) % ordered.count]
        case "main", "primary", "menubar":
            return screens.first { $0.frame.origin == .zero } ?? ordered[0]
        default:
            break
        }
        if let number = Int(text) {
            guard (1...ordered.count).contains(number) else {
                throw ModuleError("There's no screen \(number)", ordered.count == 1
                    ? "Only one is connected." : "Screens are numbered 1 to \(ordered.count), from the left.")
            }
            return ordered[number - 1]
        }
        if let named = ordered.first(where: { $0.name.localizedCaseInsensitiveCompare(text) == .orderedSame })
            ?? ordered.first(where: { $0.name.localizedCaseInsensitiveContains(text) }) {
            return named
        }
        throw ModuleError("No screen is called “\(text)”",
                          "Connected: " + ordered.map { "“\($0.name)”" }.joined(separator: ", ") + ".")
    }

    /// The window's place on one screen's area, kept on another's: the same
    /// share of the width and height, at the same share across and down.
    public static func carried(_ window: CGRect, from: CGRect, to: CGRect) -> CGRect {
        guard from.width > 0, from.height > 0 else { return window }
        let across = to.width / from.width, up = to.height / from.height
        let moved = CGRect(x: to.minX + (window.minX - from.minX) * across, y: to.minY + (window.minY - from.minY) * up,
                           width: window.width * across, height: window.height * up).integral
        return moved.intersection(to).isNull ? to : moved.intersection(to)
    }

    /// Between AppKit's rectangles and Accessibility's: the same rectangle,
    /// measured from the other end of the main screen. Its own inverse.
    public static func flipped(_ rect: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }
}
