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
  tree [config]      load a config file and print the tree it describes
  run [config]       drive the Keybow from a config: lights, selection, and the
                     action each completed path would run (nothing is executed yet)

The config defaults to ~/Library/Application Support/KeybowNotes/config.json,
falling back to ./config.example.json.
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

func configURL(_ arguments: [String]) -> URL {
    if let given = arguments.first {
        return URL(fileURLWithPath: (given as NSString).expandingTildeInPath)
    }
    let installed = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/KeybowNotes/config.json")
    if FileManager.default.fileExists(atPath: installed.path) { return installed }
    return URL(fileURLWithPath: "config.example.json")
}

func loadConfig(_ arguments: [String]) -> (KeybowConfig, URL) {
    let url = configURL(arguments)
    do {
        return (try KeybowConfig.load(from: url), url)
    } catch let error as ConfigError {
        fail("config error in \(url.lastPathComponent): \(error.description)")
    } catch {
        fail("config error: \(error)")
    }
}

func printTree(_ nodes: [TreeNode?], indent: String = "") {
    for (column, node) in nodes.enumerated() {
        guard let node else { continue }
        let marker = node.isLeaf ? "\u{25CF}" : "\u{25B8}"
        let detail = node.action.map { " -> \($0.type)" } ?? ""
        print("\(indent)\(marker) key \(column): \(node.label)\(detail)")
        if !node.isLeaf { printTree(node.children, indent: indent + "    ") }
    }
}

func describe(_ event: NavigatorEvent) -> String {
    switch event {
    case .selectionChanged(let selection):
        guard let selection else { return "selection cleared" }
        return "selected: \(selection.pathDescription)"
    case .invalidPress(let key):
        return "ignored key \(key) (not an option here)"
    case .pending(let selection):
        return "about to run \(selection.action?.type ?? "?") for \(selection.pathDescription) — press any key to cancel"
    case .fire(let selection):
        var line = "FIRE \(selection.action?.type ?? "?") for \(selection.pathDescription)"
        if !selection.params.isEmpty {
            let params = selection.params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            line += "\n     params: \(params.joined(separator: ", "))"
        }
        for (key, value) in (selection.action?.fields ?? [:]).sorted(by: { $0.key < $1.key }) {
            line += "\n     \(key): \(value.stringValue ?? "\(value)")"
        }
        return line
    case .cleared(let reason):
        return "cleared (\(reason.rawValue))"
    }
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

case "tree":
    let (config, url) = loadConfig(Array(arguments.dropFirst()))
    print("\(url.path)  (version \(config.version), commit delay \(config.commitDelay)s)")
    printTree(config.tree)

case "run":
    let (config, url) = loadConfig(Array(arguments.dropFirst()))
    print("config: \(url.path)")
    printTree(config.tree)
    print("---")
    let connection = KeybowConnection()
    let driver = SelectionDriver(config: config, connection: connection)
    Task {
        for await event in driver.connectionEvents {
            if case .connected(let path) = event { print("connected: \(path)") }
            if case .disconnected(let reason) = event { print("disconnected: \(reason)") }
        }
    }
    Task {
        for await event in driver.events { print(describe(event)) }
    }
    driver.start()
    dispatchMain()

default:
    fail(usage)
}

// These commands do not block.
if command == "ports" || command == "tree" { exit(0) }
