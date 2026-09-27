import Foundation

/// Outline text to config JSON in one step, for the `keybow convert` command:
/// parse, refuse on errors, compile. The editor uses the parts directly.
public enum OutlineConverter {
    public struct AppMatch: Equatable, Sendable {
        public let name: String
        public let installed: Bool
        /// Leaves under a service app (Discord, Mastodon…) are channels or
        /// targets; under anything else they are projects with a file to open.
        public let isService: Bool
        /// Lets the app be found wherever it is installed, at run time.
        public let bundleIdentifier: String?

        public init(name: String, installed: Bool, isService: Bool, bundleIdentifier: String? = nil) {
            self.name = name
            self.installed = installed
            self.isService = isService
            self.bundleIdentifier = bundleIdentifier
        }
    }

    public struct Result {
        public let json: String
        /// Things the converter decided that a person should check.
        public let inferences: [String]
        /// Values it could not know: paths, phone numbers, URLs.
        public let todo: [String]
        public let warnings: [String]
    }

    public struct ConversionError: Error, CustomStringConvertible {
        public let line: Int
        public let message: String

        public var description: String { "line \(line): \(message)" }
    }

    public static func convert(
        _ outline: String,
        locateApp: @escaping (String) -> AppMatch? = AppLocator.locate
    ) throws -> Result {
        let (document, diagnostics) = OutlineParser.parse(outline)
        if let error = diagnostics.first(where: { $0.severity == .error }) {
            throw ConversionError(line: error.line, message: error.message)
        }
        let compiled = OutlineCompiler.compile(document, locateApp: locateApp)
        if let error = compiled.diagnostics.first(where: { $0.severity == .error }) {
            throw ConversionError(line: error.line, message: error.message)
        }
        return Result(
            json: compiled.json,
            inferences: compiled.inferences,
            todo: compiled.todo,
            warnings: compiled.warnings + diagnostics.filter { $0.severity == .warning }.map { "line \($0.line): \($0.message)" }
        )
    }
}

/// Finds apps by the names people actually call them.
public enum AppLocator {
    private struct Known {
        let bundleNames: [String]
        let isService: Bool
    }

    /// Keys are lowercased with spaces removed.
    private static let known: [String: Known] = [
        "vscode": Known(bundleNames: ["Visual Studio Code"], isService: false),
        "visualstudiocode": Known(bundleNames: ["Visual Studio Code"], isService: false),
        "rider": Known(bundleNames: ["Rider"], isService: false),
        "prusaslicer": Known(bundleNames: ["PrusaSlicer", "Original Prusa Drivers/PrusaSlicer"], isService: false),
        "fusion": Known(bundleNames: ["Autodesk Fusion", "Autodesk Fusion 360"], isService: false),
        "fusion360": Known(bundleNames: ["Autodesk Fusion 360", "Autodesk Fusion"], isService: false),
        "kicad": Known(bundleNames: ["KiCad", "KiCad/KiCad"], isService: false),
        "thonny": Known(bundleNames: ["Thonny"], isService: false),
        "inkscape": Known(bundleNames: ["Inkscape"], isService: false),
        "lightburn": Known(bundleNames: ["LightBurn"], isService: false),
        "xcode": Known(bundleNames: ["Xcode"], isService: false),
        "claude": Known(bundleNames: ["Claude"], isService: true),
        "discord": Known(bundleNames: ["Discord"], isService: true),
        "mastodon": Known(bundleNames: ["Mastodon", "Ivory", "Ice Cubes"], isService: true),
        "meshtastic": Known(bundleNames: ["Meshtastic"], isService: true),
    ]

    private static var searchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
    }

    public static func locate(_ name: String) -> OutlineConverter.AppMatch? {
        let key = name.lowercased().replacingOccurrences(of: " ", with: "")
        let entry = known[key]
        let candidates = entry?.bundleNames ?? [name]

        for candidate in candidates {
            if let path = installedPath(candidate) {
                let display = candidate.split(separator: "/").last.map(String.init) ?? candidate
                return OutlineConverter.AppMatch(
                    name: display,
                    installed: true,
                    isService: entry?.isService ?? false,
                    bundleIdentifier: Bundle(url: path)?.bundleIdentifier
                )
            }
        }
        // A name we recognise, just not installed here.
        if let entry, let first = entry.bundleNames.first {
            return OutlineConverter.AppMatch(name: first, installed: false, isService: entry.isService)
        }
        return nil
    }

    /// Where an app is installed, looking in the usual places.
    public static func installedPath(_ name: String) -> URL? {
        let manager = FileManager.default
        for directory in searchDirectories {
            let direct = directory.appendingPathComponent(name + ".app")
            if manager.fileExists(atPath: direct.path) { return direct }
            // Some apps install inside a folder of their own: /Applications/KiCad/KiCad.app
            let nested = directory.appendingPathComponent(name).appendingPathComponent(name + ".app")
            if manager.fileExists(atPath: nested.path) { return nested }
        }
        return nil
    }
}

/// JSON with keys in a chosen order, printed compactly where it stays readable.
indirect enum OrderedJSON {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    func render(indent: Int = 0) -> String {
        let inline = renderInline()
        if !containsArray, inline.count + indent * 2 <= 100 { return inline }

        let pad = String(repeating: "  ", count: indent + 1)
        let closing = String(repeating: "  ", count: indent)
        switch self {
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + items.map { pad + $0.render(indent: indent + 1) }.joined(separator: ",\n") + "\n\(closing)]"
        case .object(let pairs):
            guard !pairs.isEmpty else { return "{}" }
            return "{\n" + pairs.map { pad + Self.quote($0.0) + ": " + $0.1.render(indent: indent + 1) }
                .joined(separator: ",\n") + "\n\(closing)}"
        default:
            return inline
        }
    }

    private var containsArray: Bool {
        switch self {
        case .array: return true
        case .object(let pairs): return pairs.contains { $0.1.containsArray }
        default: return false
        }
    }

    private func renderInline() -> String {
        switch self {
        case .string(let text): return Self.quote(text)
        case .number(let value):
            return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        case .array(let items): return "[" + items.map { $0.renderInline() }.joined(separator: ", ") + "]"
        case .object(let pairs):
            guard !pairs.isEmpty else { return "{}" }
            return "{ " + pairs.map { Self.quote($0.0) + ": " + $0.1.renderInline() }.joined(separator: ", ") + " }"
        }
    }

    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
