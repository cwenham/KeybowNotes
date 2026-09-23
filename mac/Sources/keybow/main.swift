import Foundation
import KeybowKit

// A small command-line harness for the serial layer, so the device can be
// exercised without a GUI. The real app will use KeybowKit the same way.

// Line-buffer stdout: when output goes to a pipe rather than a terminal it is
// otherwise fully buffered, and a long-running watch appears to print nothing.
setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
usage: keybow <command>

  ports              list the Keybow's serial ports
  watch              connect and print everything the device says (Ctrl-C to stop)
  ping               connect, ping once, print the reply
  leds <spec>        set the keys, then hold the connection for a moment
                     <spec> is 1-16 rrggbb values, separated by spaces or commas;
                     the last one fills the remaining keys
  demo               light each key in turn, top-left to bottom-right
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func parseColours(_ arguments: [String]) -> [KeyColour] {
    let tokens = arguments
        .joined(separator: " ")
        .split(whereSeparator: { $0 == " " || $0 == "," })
        .map(String.init)
    guard !tokens.isEmpty else { fail("no colours given") }

    var colours: [KeyColour] = []
    for token in tokens {
        guard let colour = KeyColour(hex: token) else { fail("not an rrggbb colour: \(token)") }
        colours.append(colour)
    }
    // Repeat the final colour across whatever is left.
    while colours.count < KeybowProtocol.keyCount, let last = colours.last {
        colours.append(last)
    }
    return colours
}

/// Runs `body` while the connection is up, then exits.
func withConnection(seconds: TimeInterval, _ body: @escaping (KeybowConnection) -> Void) -> Never {
    let connection = KeybowConnection()

    Task {
        for await event in connection.events {
            switch event {
            case .connected(let path):
                print("connected: \(path)")
                body(connection)
            case .disconnected(let reason):
                print("disconnected: \(reason)")
            case .message(let message):
                print(describe(message))
            }
        }
        // The stream finishes once stop() has run, which is our cue to leave.
        exit(0)
    }

    connection.start()
    if seconds > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            connection.stop()
        }
    }
    // Ctrl-C ends the run; the timer above handles the bounded commands.
    dispatchMain()
}

func describe(_ message: DeviceMessage) -> String {
    switch message {
    case .hello(let version):
        return "HELLO (protocol \(version))"
    case .down(let key):
        let position = KeybowProtocol.position(ofKey: key)
        return "DOWN \(key)  row \(position.row + 1), column \(position.column + 1)"
    case .up(let key):
        return "UP   \(key)"
    case .pong:
        return "PONG"
    case .deviceError(let text):
        return "ERR  \(text)"
    case .unrecognised(let text):
        return "?    \(text)"
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage) }

switch command {
case "ports":
    let ports = USBSerialPorts.ports(vendorID: KeybowProtocol.vendorID, productID: KeybowProtocol.productID)
    if ports.isEmpty {
        print("no Keybow 2040 found (looking for \(String(format: "0x%04x:0x%04x", KeybowProtocol.vendorID, KeybowProtocol.productID)))")
    }
    for port in ports {
        let interface = port.interfaceNumber.map(String.init) ?? "?"
        let role = port.path == USBSerialPorts.keybowDataPort()?.path ? "data" : "console"
        print("\(port.path)  interface \(interface)  \(role)")
    }

case "watch":
    withConnection(seconds: 0) { _ in }

case "ping":
    withConnection(seconds: 3) { connection in
        connection.send(.ping)
    }

case "leds":
    let colours = parseColours(Array(arguments.dropFirst()))
    withConnection(seconds: 3) { connection in
        connection.send(.leds(colours))
    }

case "demo":
    withConnection(seconds: 0) { connection in
        DispatchQueue.global().async {
            for key in 0..<KeybowProtocol.keyCount {
                var colours = [KeyColour](repeating: .off, count: KeybowProtocol.keyCount)
                colours[key] = KeyColour(red: 0, green: 180, blue: 255)
                connection.send(.leds(colours))
                Thread.sleep(forTimeInterval: 0.15)
            }
            connection.send(.leds([KeyColour](repeating: .off, count: KeybowProtocol.keyCount)))
            print("demo finished")
            exit(0)
        }
    }

default:
    fail(usage)
}

// `ports` is the only command that does not block.
if command == "ports" { exit(0) }
