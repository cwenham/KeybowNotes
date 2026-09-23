import XCTest
@testable import KeybowKit

final class ProtocolTests: XCTestCase {
    func testParsesDeviceMessages() {
        XCTAssertEqual(DeviceMessage(line: "HELLO keybow 1"), .hello(protocolVersion: 1))
        XCTAssertEqual(DeviceMessage(line: "DOWN 0"), .down(key: 0))
        XCTAssertEqual(DeviceMessage(line: "UP 15"), .up(key: 15))
        XCTAssertEqual(DeviceMessage(line: "PONG"), .pong)
        XCTAssertEqual(
            DeviceMessage(line: "ERR LEDS expects 96 hex characters, got 8"),
            .deviceError("LEDS expects 96 hex characters, got 8")
        )
    }

    func testToleratesRubbish() {
        XCTAssertEqual(DeviceMessage(line: ""), .unrecognised(""))
        XCTAssertEqual(DeviceMessage(line: "DOWN"), .unrecognised("DOWN"))
        XCTAssertEqual(DeviceMessage(line: "DOWN x"), .unrecognised("DOWN x"))
        XCTAssertEqual(DeviceMessage(line: "SOMETHING ELSE"), .unrecognised("SOMETHING ELSE"))
    }

    func testStripsLineEndings() {
        XCTAssertEqual(DeviceMessage(line: "DOWN 7\r\n"), .down(key: 7))
    }

    func testColourParsing() {
        XCTAssertEqual(KeyColour(hex: "ff0000"), KeyColour(red: 255, green: 0, blue: 0))
        XCTAssertEqual(KeyColour(hex: "#00ff00"), KeyColour(red: 0, green: 255, blue: 0))
        XCTAssertNil(KeyColour(hex: "xyz"))
        XCTAssertNil(KeyColour(hex: "ff00"))
        XCTAssertEqual(KeyColour(red: 1, green: 2, blue: 3).hex, "010203")
    }

    func testLedsCommandPadsToSixteenKeys() {
        let line = HostCommand.leds([KeyColour(hex: "ff0000")!]).line
        XCTAssertTrue(line.hasPrefix("LEDS "))
        let payload = String(line.dropFirst("LEDS ".count))
        XCTAssertEqual(payload.count, KeybowProtocol.keyCount * 6)
        XCTAssertTrue(payload.hasPrefix("ff0000"))
        XCTAssertTrue(payload.hasSuffix("000000"))
    }

    func testLedsCommandIgnoresExtraColours() {
        let colours = [KeyColour](repeating: KeyColour(hex: "010101")!, count: 20)
        let payload = String(HostCommand.leds(colours).line.dropFirst("LEDS ".count))
        XCTAssertEqual(payload.count, KeybowProtocol.keyCount * 6)
    }

    func testPingCommand() {
        XCTAssertEqual(HostCommand.ping.line, "PING")
    }

    func testKeyPositions() {
        XCTAssertEqual(KeybowProtocol.key(row: 0, column: 0), 0)
        XCTAssertEqual(KeybowProtocol.key(row: 3, column: 3), 15)
        XCTAssertEqual(KeybowProtocol.position(ofKey: 4).row, 1)
        XCTAssertEqual(KeybowProtocol.position(ofKey: 4).column, 0)
    }

    func testLineAssemblerSplitsAndKeepsPartialTail() {
        var assembler = LineAssembler()
        XCTAssertEqual(assembler.append(Data("DOWN 1\nUP ".utf8)), ["DOWN 1"])
        XCTAssertEqual(assembler.append(Data("1\n".utf8)), ["UP 1"])
        XCTAssertEqual(assembler.append(Data("\n\n".utf8)), [])
    }
}
