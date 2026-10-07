import Foundation
import KeybowKit
import KeybowModules

// The same modules as the app, so their keywords compile. Nothing here needs
// their state to outlive the run.
BuiltInModules.registerAll(host: MemoryModuleHost())

// A small command-line harness for the serial layer, so the device can be
// exercised without a GUI. The real app will use KeybowKit the same way.

// Line-buffer stdout: when output goes to a pipe rather than a terminal it is
// otherwise fully buffered, and a long-running watch appears to print nothing.
setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
usage: keybow <command>

  ports              list the Keybow's serial ports
  keypads            list the keypads connected — Keybow 2040s and RGB Keypads
                     with the firmware's data port — by model and unique ID
  watch              connect and print everything the device says (Ctrl-C to stop)
  ping               connect, ping once, print the reply
  leds <spec>        set the keys, then hold the connection for a moment
                     <spec> is 1-16 rrggbb values, separated by spaces or commas;
                     the last one fills the remaining keys
  demo               light each key in turn, top-left to bottom-right
  tree [tree.md]     load a tree and print what it describes
  run [tree.md]      drive the Keybow from a tree: lights, selection, and the
                     action each completed path would run (nothing is executed yet)
  convert <outline> [-o file.json]
                     print the JSON an outline compiles to — what the app runs —
                     listing what it guessed and what still needs filling in
  setup [keybow2040|rgbkeypad] [--keep-circuitpython]
                     set a keypad up: the newest CircuitPython the firmware
                     supports, then the firmware, then a restart. Files it
                     replaces are backed up first. A board running CircuitPython
                     is found by itself; KEYBOW_DEVICE=<id> picks one of two
  troubleshoot [--since 3h] [--for <id|model>] [--keys dark|red|blue|purple|lit]
               [--console] [--watch]
                     look for the keypads this Mac has known and the tree
                     names, and say what's wrong and how to fix it: from
                     what's plugged in, the USB log, drives and ports.
                     --console starts a keypad's program again to read what it
                     says; --watch watches while you unplug one and plug it in
  upgrade-outline <outline>
                     rewrite an older outline in the current syntax: [brackets]
                     instead of (parentheses), plus # contacts and # projects
                     sections to fill in. Keeps a .bak copy.

Device commands talk to the first keypad found; KEYBOW_DEVICE=rgbkeypad (or a
model, or a unique ID from `keybow keypads`) picks another.

The tree defaults to ~/Library/Application Support/KeybowNotes/tree.md,
falling back to ./tree.demo.md. A compiled .json file works too.
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
/// The keypad KEYBOW_DEVICE names — a model, "rgbkeypad", or a unique ID —
/// else the first found.
func chosenKeypad() -> String? {
    guard let wanted = ProcessInfo.processInfo.environment["KEYBOW_DEVICE"], !wanted.isEmpty else { return nil }
    let keypads = USBSerialPorts.keypads()
    if let model = KeypadDevice.Model(words: wanted) { return keypads.first { $0.model == model }?.serial ?? wanted }
    return wanted
}

func withConnection(seconds: TimeInterval, _ body: @escaping (KeybowConnection) -> Void) -> Never {
    let connection = KeybowConnection(serial: chosenKeypad())

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
        .appendingPathComponent("Library/Application Support/KeybowNotes/tree.md")
    if FileManager.default.fileExists(atPath: installed.path) { return installed }
    return URL(fileURLWithPath: "tree.demo.md")
}

func loadConfig(_ arguments: [String]) -> (KeybowConfig, URL) {
    let url = configURL(arguments)
    do {
        let loaded = try ConfigFile.load(url)
        for mistake in loaded.errors {
            FileHandle.standardError.write(Data("\(url.lastPathComponent):\(mistake.line): \(mistake.message)\n".utf8))
        }
        for left in loaded.leftOut {
            FileHandle.standardError.write(Data("\(url.lastPathComponent): left out: \(left)\n".utf8))
        }
        return (loaded.config, url)
    } catch let error as ConfigError {
        fail("config error in \(url.lastPathComponent): \(error.description)")
    } catch {
        fail("config error: \(error)")
    }
}

func printTrees(_ config: KeybowConfig) {
    for tree in TreeKind.allCases where config.trees[tree] != nil {
        let rows = tree.rows.map { String($0 + 1) }.joined(separator: " → ")
        if config.isPaged(tree) {
            print("\(tree.rawValue) pages (on row \(tree.startRow + 1); their keys on rows \(tree.startRow + 2)–4, at once)")
        } else {
            print("\(tree.rawValue) tree (rows \(rows))")
        }
        printTree(config, tree, nodes: config.roots(tree), indent: "  ")
    }
}

func printTree(_ config: KeybowConfig, _ tree: TreeKind, nodes: [TreeNode?], path: [Int] = [], indent: String) {
    for (column, node) in nodes.enumerated() {
        guard let node else { continue }
        let here = path + [column]
        if node.isLeaf {
            let type = config.resolve(tree: tree, path: here)?.action?.type ?? "?"
            print("\(indent)\u{25CF} \(column + 1). \(node.label) -> \(type)")
        } else {
            print("\(indent)\u{25B8} \(column + 1). \(node.label)")
            printTree(config, tree, nodes: node.children, path: here, indent: indent + "    ")
        }
    }
}

let displayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE d MMM yyyy, HH:mm"
    return formatter
}()

func describe(_ event: NavigatorEvent) -> String {
    switch event {
    case .selectionChanged(let selection):
        guard let selection else { return "selection cleared" }
        return "selected: \(selection.pathDescription)"
    case .invalidPress(let key):
        return "ignored key \(key) (not an option here)"
    case .pending(let selection):
        return "about to run \(selection.action?.type ?? "?") for \(selection.pathDescription) — press any key to cancel"
    case .fire(let selection, _):
        var line = "FIRE \(selection.action?.type ?? "?") for \(selection.pathDescription)  [\(selection.tree.rawValue) tree]"
        for (key, value) in (selection.action?.fields ?? [:]).sorted(by: { $0.key < $1.key }) {
            line += "\n     \(key): \(value.stringValue ?? "\(value)")"
        }
        let interesting = selection.params.filter { !["path", "tree"].contains($0.key) && !$0.key.hasPrefix("level") }
        if !interesting.isEmpty {
            let params = interesting.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            line += "\n     params: \(params.joined(separator: ", "))"
        }
        if let when = selection.params["when"],
           let date = DateExpression.resolve(when, now: Date(), rules: currentRules) {
            line += "\n     \"\(when)\" resolves to \(displayFormatter.string(from: date))"
        }
        return line
    case .cleared(let reason):
        return "cleared (\(reason.rawValue))"
    case .page(let page):
        guard let page else { return "back to the trees" }
        return "page: \(page.node.label)  [\(page.tree.rawValue) pages]"
    }
}

nonisolated(unsafe) var currentRules = DateRules()

/// Whether the keypad says hello on its data port: it does when a host starts
/// talking to it.
func heardHello(_ serial: String) async -> Bool {
    let connection = KeybowConnection(serial: serial)
    connection.start()
    defer { connection.stop() }
    return await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await event in connection.events {
                if case .message(.hello) = event { return true }
            }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(5))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

/// Whether the app is running: it holds this lock while it is.
enum SingleInstanceCheck {
    static var isFree: Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KeybowNotes/.lock").path
        let descriptor = open(path, O_RDWR)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(descriptor, LOCK_UN)
        return true
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
    case .bye:
        return "BYE"
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

case "keypads":
    let keypads = USBSerialPorts.keypads()
    if keypads.isEmpty { print("no keypads found: a Keybow 2040 or an RGB Keypad with the firmware's boot.py run") }
    for keypad in keypads {
        print("\(keypad.model.title)  \(keypad.serial)  data \(keypad.dataPort)  console \(keypad.consolePort ?? "-")")
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
    printTrees(config)

case "convert":
    var rest = Array(arguments.dropFirst())
    var output: String?
    if let flag = rest.firstIndex(of: "-o"), flag + 1 < rest.count {
        output = rest[flag + 1]
        rest.removeSubrange(flag...(flag + 1))
    }
    guard let input = rest.first else { fail("usage: keybow convert <outline> [-o file.json]") }
    let outlineURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
    let text: String
    do {
        text = try String(contentsOf: outlineURL, encoding: .utf8)
    } catch {
        fail("cannot read \(outlineURL.path): \(error.localizedDescription)")
    }

    let result: OutlineConverter.Result
    do {
        result = try OutlineConverter.convert(text)
    } catch {
        fail("\(outlineURL.lastPathComponent): \(error)")
    }

    // The output must load; anything else is a converter bug.
    do {
        _ = try KeybowConfig.parse(Data(result.json.utf8))
    } catch {
        fail("internal error: the converted config does not load: \(error)")
    }

    if let output {
        let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try result.json.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            fail("cannot write \(url.path): \(error.localizedDescription)")
        }
    } else {
        print(result.json, terminator: "")
    }

    func report(_ title: String, _ lines: [String]) {
        guard !lines.isEmpty else { return }
        FileHandle.standardError.write(Data("\n\(title) (\(lines.count)):\n".utf8))
        for line in lines { FileHandle.standardError.write(Data("  • \(line)\n".utf8)) }
    }
    report("Guessed — check these", result.inferences)
    report("Still to fill in", result.todo)
    report("Warnings", result.warnings)
    if let output { FileHandle.standardError.write(Data("\nWrote \(output)\n".utf8)) }
    exit(0)

case "upgrade-outline":
    guard let input = arguments.dropFirst().first else { fail("usage: keybow upgrade-outline <outline>") }
    let url = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
    guard let original = try? String(contentsOf: url, encoding: .utf8) else { fail("cannot read \(url.path)") }

    let (bracketed, changed) = OutlineMigration.bracketize(original)
    var (document, diagnostics) = OutlineParser.parse(bracketed)
    if let error = diagnostics.first(where: { $0.severity == .error }) {
        fail("line \(error.line): \(error.message) — nothing was changed")
    }
    let before = (document.contacts.count, document.projects.count)
    OutlineMigration.addMissingEntries(to: &document, from: OutlineCompiler.compile(document))
    let upgraded = OutlineWriter.text(document)

    let backup = url.appendingPathExtension("bak")
    do {
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)
        try upgraded.write(to: url, atomically: true, encoding: .utf8)
    } catch {
        fail("cannot write \(url.path): \(error.localizedDescription)")
    }
    print("Rewrote \(changed) annotation\(changed == 1 ? "" : "s") in brackets.")
    print("Added \(document.contacts.count - before.0) contacts and \(document.projects.count - before.1) projects to fill in.")
    print("Kept the original as \(backup.lastPathComponent).")
    exit(0)

case "setup":
    var rest = Array(arguments.dropFirst())
    let keep = rest.contains("--keep-circuitpython")
    rest.removeAll { $0 == "--keep-circuitpython" }
    guard let package = FirmwarePackage.locate() else {
        fail("The firmware isn't here: set KEYBOW_FIRMWARE to the repository's firmware folder.")
    }
    var named: KeypadDevice.Model?
    if let word = rest.first {
        guard let model = KeypadDevice.Model(words: word) else { fail("\(word) isn't a model: keybow2040 or rgbkeypad") }
        named = model
    }
    let running = SetupCandidate.all(package: package).filter { !$0.inBootloader && (named == nil || $0.model == named) }
    var target: SetupCandidate?
    if let wanted = ProcessInfo.processInfo.environment["KEYBOW_DEVICE"], !wanted.isEmpty {
        target = running.first { $0.serial?.caseInsensitiveCompare(wanted) == .orderedSame || $0.model == KeypadDevice.Model(words: wanted) }
        if target == nil { fail("No board running CircuitPython is \(wanted).") }
    } else if running.count == 1 {
        target = running[0]
    } else if running.count > 1 {
        fail("Which one? KEYBOW_DEVICE=<id> picks:\n" + running.map { "  \($0.model?.title ?? "?")  \($0.serial ?? "")" }.joined(separator: "\n"))
    }
    guard let model = target?.model ?? named else {
        fail("Which model is it? keybow setup keybow2040, or keybow setup rgbkeypad")
    }
    let has = target?.bootOut?.version
    let mustInstall = has.map { !package.majors.contains($0.major) } ?? true

    Task {
        do {
            var version: CircuitPythonVersion?
            let downloads = CircuitPythonDownloads()
            let board = package.board(for: model)!.circuitPythonBoard
            if mustInstall || !keep {
                do {
                    version = try await downloads.newest(board: board, majors: package.majors)
                } catch {
                    guard let cached = downloads.newestCached(board: board, majors: package.majors) else { throw error }
                    print("couldn't reach the downloads; using \(cached.version), downloaded before")
                    version = cached.version
                }
                if !mustInstall, let has, let newest = version, has >= newest { version = nil }
            }
            print("\(model.title)\(target?.serial.map { " \($0)" } ?? ""): "
                  + (version.map { "CircuitPython \($0)" } ?? "keeping CircuitPython \(has?.description ?? "")")
                  + ", then the firmware from \(package.root.path)")
            // With the app running, it has the data port, and hears the hello.
            let appRunning = !SingleInstanceCheck.isFree
            let setup = KeypadSetup(package: package, downloads: downloads, stopProgram: { serial in
                // Written straight to its data port: the app may have it open too.
                guard let keypad = USBSerialPorts.keypads().first(where: { $0.serial == serial }),
                      let port = try? SerialPort(path: keypad.dataPort) else { return false }
                return (try? port.write(line: HostCommand.stop.line)) != nil
            }) { serial in
                if appRunning { return USBSerialPorts.keypads().contains { $0.serial == serial } }
                return await heardHello(serial)
            }
            let backups = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/KeybowNotes/Keypad Backups", isDirectory: true)
            let outcome = try await setup.run(KeypadSetup.Plan(model: model, serial: target?.serial, circuitPython: version,
                                                               backups: backups)) { event in
                switch event {
                case .started(let step, let text): print("… \(step.title): \(text)")
                case .waiting(let step, let text): print("‼ \(step.title): \(text)")
                case .done(let step, let text): print("✓ \(step.title): \(text)")
                case .skipped(let step, let text): print("– \(step.title): \(text)")
                }
            }
            print("set up: \(model.title) \(outcome.serial)")
            if let folder = outcome.backupFolder { print("replaced files are in \(folder.path)") }
            exit(0)
        } catch let error as ModuleError {
            fail(error.message + (error.detail.map { "\n" + $0 } ?? ""))
        } catch {
            fail("\(error)")
        }
    }
    dispatchMain()

case "troubleshoot":
    var rest = Array(arguments.dropFirst())
    func option(_ name: String) -> String? {
        guard let index = rest.firstIndex(of: name), index + 1 < rest.count else { return nil }
        defer { rest.removeSubrange(index...index + 1) }
        return rest[index + 1]
    }
    var hours = 3.0
    if let since = option("--since") {
        guard let value = Double(since.trimmingCharacters(in: CharacterSet(charactersIn: "hH"))) else {
            fail("--since takes hours: 3h")
        }
        hours = value
    }
    let wanted = option("--for")
    var keys: KeyLights?
    if let word = option("--keys") {
        let words: [String: KeyLights] = ["dark": .dark, "red": .pulsingRed, "blue": .steadyBlue,
                                          "purple": .flashingPurple, "lit": .treeColours]
        guard let lights = words[word.lowercased()] else { fail("--keys is dark, red, blue, purple or lit") }
        keys = lights
    }
    let readConsoles = rest.contains("--console")
    let watchPlugIn = rest.contains("--watch")
    let known = KnownKeypads.load(UserDefaults(suiteName: KnownKeypads.appDomain) ?? .standard)
    let config = try? ConfigFile.load(configURL([])).config
    var sought = SoughtKeypad.all(known: known, config: config)
    if let wanted {
        sought = sought.filter { Troubleshooter.same($0.serial, wanted) || $0.model == KeypadDevice.Model(words: wanted) }
        if sought.isEmpty { sought = [KeypadDevice.Model(words: wanted).map { SoughtKeypad(name: $0.title, model: $0) }
                                      ?? SoughtKeypad(name: "Keypad \(wanted)", serial: wanted)] }
    }

    Task {
        let package = FirmwarePackage.locate()
        var watched: DateInterval?
        var heard: [USBLogEvent] = []
        if watchPlugIn {
            let watcher = USBLogWatcher()
            let events = watcher.start()
            let listening = Task { for await event in events { heard.append(event); print("  … \(event.location) \(event.kind)") } }
            let start = Date()
            print("Watching for 30 seconds: unplug the keypad, then plug it back in.")
            try? await Task.sleep(for: .seconds(30))
            watcher.stop()
            await listening.value
            watched = DateInterval(start: start, end: Date())
        }
        var facts = await TroubleshootingFacts.gather(sought: sought, since: Date().addingTimeInterval(-hours * 3600),
                                                     connected: nil, package: package)
        // What the log hadn't written down yet, from watching.
        for event in heard where !facts.events.contains(event) { facts.events.append(event) }
        facts.events.sort { $0.date < $1.date }
        facts.watchedPlugIn = watched
        facts.keys = keys
        if readConsoles {
            for board in facts.boards {
                guard let console = board.consolePort, let text = try? CircuitPythonConsole.listen(port: console) else { continue }
                facts.console[board.serial.uppercased()] = ConsoleReading(text: text)
            }
        }
        print(Troubleshooter.report(facts, findings: Troubleshooter.diagnose(facts)))
        exit(0)
    }
    dispatchMain()

case "run":
    let (whole, url) = loadConfig(Array(arguments.dropFirst()))
    // The keypad's own trees, when the outline gives it some.
    let serial = chosenKeypad()
    let device = USBSerialPorts.keypads().first { serial == nil || $0.serial == serial }
    let config = device.map(whole.forDevice) ?? whole
    currentRules = config.dateRules
    print("config: \(url.path)")
    if let device, !whole.keypads.isEmpty {
        let index = whole.keypadIndex(for: device)
        print("keypad: \(device.model.title) \(device.serial), using " + (index == 0 ? "the Default trees" : "“\(whole.keypads[index - 1].name)”"))
    }
    printTrees(config)
    print("---")
    let connection = KeybowConnection(serial: device?.serial ?? serial)
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
