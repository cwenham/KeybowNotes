import Foundation

/// One key's colour. The firmware takes 16 of these per `LEDS` command.
public struct KeyColour: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Accepts "rrggbb", with or without a leading '#'.
    public init?(hex: String) {
        var text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        text = text.trimmingCharacters(in: .whitespaces)
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8(value & 0xFF)
        )
    }

    public var hex: String {
        String(format: "%02x%02x%02x", red, green, blue)
    }

    public static let off = KeyColour(red: 0, green: 0, blue: 0)
}

/// Something the Keybow said to us.
public enum DeviceMessage: Equatable, Sendable {
    case hello(protocolVersion: Int)
    case down(key: Int)
    case up(key: Int)
    case pong
    case deviceError(String)
    /// A line we did not recognise, kept verbatim rather than dropped.
    case unrecognised(String)

    public init(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard let verb = parts.first else {
            self = .unrecognised(trimmed)
            return
        }

        switch verb {
        case "HELLO" where parts.count >= 3 && parts[1] == "keybow":
            self = .hello(protocolVersion: Int(parts[2]) ?? 0)
        case "DOWN" where parts.count == 2:
            self = Int(parts[1]).map { .down(key: $0) } ?? .unrecognised(trimmed)
        case "UP" where parts.count == 2:
            self = Int(parts[1]).map { .up(key: $0) } ?? .unrecognised(trimmed)
        case "PONG":
            self = .pong
        case "ERR":
            self = .deviceError(String(trimmed.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces))
        default:
            self = .unrecognised(trimmed)
        }
    }
}

/// Something we say to the Keybow.
public enum HostCommand: Equatable, Sendable {
    case ping
    /// Exactly `KeybowProtocol.keyCount` colours, in logical key order.
    case leds([KeyColour])

    /// The wire form, without its trailing newline.
    public var line: String {
        switch self {
        case .ping:
            return "PING"
        case .leds(let colours):
            var padded = colours.prefix(KeybowProtocol.keyCount).map(\.hex)
            while padded.count < KeybowProtocol.keyCount { padded.append(KeyColour.off.hex) }
            return "LEDS " + padded.joined()
        }
    }
}

public enum KeybowProtocol {
    public static let keyCount = 16
    public static let rows = 4
    public static let columns = 4
    public static let supportedVersion = 1

    /// USB identifiers of the Keybow 2040, used to find its serial ports.
    public static let vendorID = 0x16D0
    public static let productID = 0x08C6

    /// Logical key number for a position in the grid the user sees.
    public static func key(row: Int, column: Int) -> Int {
        row * columns + column
    }

    public static func position(ofKey key: Int) -> (row: Int, column: Int) {
        (key / columns, key % columns)
    }
}
