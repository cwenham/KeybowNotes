@testable import KeybowKit
import XCTest

/// Finding a keypad that's gone missing: macOS's USB log read, and each way
/// a keypad goes wrong turned into what to do about it.
final class TroubleshooterTests: XCTestCase {
    // Made-up board IDs.
    private let keybowID = "E6600000000000AA"
    private let picoID = "E6600000000000BB"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let hub = USBDevice(name: "USB2.0 HUB", vendorID: 0x1A40, productID: 0x0101, location: USBLocation(0x1440_0000),
                                isHub: true)

    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    /// The kernel's own words, as the log has them.
    private func event(_ message: String, _ seconds: TimeInterval) -> USBLogEvent {
        USBLog.event(message: message, date: at(seconds))!
    }

    /// Eight goes at setting up whatever's on a hub's port, then giving up:
    /// what the log showed when a hub stopped working.
    private func failures(port: String, from seconds: TimeInterval) -> [USBLogEvent] {
        (0..<8).flatMap { attempt -> [USBLogEvent] in
            let time = seconds + Double(attempt) * 2
            return [USBLog.event(message: "AppleUSB20HubPort@\(port): AppleUSBHostPort::createDevice: failed to create device (0xe00002bc)",
                                 date: at(time)),
                    USBLog.event(message: "AppleUSB20HubPort@\(port): AppleUSB20HubPort::resetAndCreateDevice: failed to address device, disabling port",
                                 date: at(time))].compactMap { $0 }
        } + [event("AppleUSB20HubPort@\(port): AppleUSBHostPort::disconnect: persistent enumeration failures", seconds + 15)]
    }

    private var keybowArrives: USBLogEvent {
        event("HS06@14500000: AppleUSBHostPort::enumerateDeviceComplete_block_invoke: enumerated 0x16d0/08c6/0100 (Keybow 2040 / 58) at 12 Mbps", 0)
    }

    private var sought: SoughtKeypad {
        SoughtKeypad(name: "Keybow 2040", model: .keybow2040, serial: keybowID, lastSeen: at(-7200),
                     lastLocation: USBLocation(0x1441_0000), lastPlace: "port 1 of the hub “USB2.0 HUB”")
    }

    private func keybowBoard(ports: Int = 2) -> USBSerialPorts.Board {
        USBSerialPorts.Board(serial: keybowID, model: .keybow2040,
                             ports: Array(["/dev/cu.usbmodem14501", "/dev/cu.usbmodem14503"].prefix(ports)),
                             registryIDs: Array([1, 2].prefix(ports)))
    }

    private var keybowDevice: USBDevice {
        USBDevice(name: "Keybow 2040", vendorID: 0x16D0, productID: 0x08C6, serial: keybowID, location: USBLocation(0x1450_0000))
    }

    // MARK: Places

    func testALocationSaysWhereItIs() {
        let port = USBLocation(0x1442_0000)
        XCTAssertEqual(port.ports, [4, 2])
        XCTAssertEqual(port.hub, USBLocation(0x1440_0000))
        XCTAssertFalse(port.isOnTheMac)
        XCTAssertTrue(USBLocation(0x1450_0000).isOnTheMac)
        XCTAssertNil(USBLocation(0x1450_0000).hub)
        XCTAssertEqual(USBLocation(0x1442_3000).hub, USBLocation(0x1442_0000))
        XCTAssertEqual(USBLocation(hex: "14420000"), port)

        XCTAssertEqual(USBInventory.place(port, devices: [hub]), "port 2 of the hub “USB2.0 HUB”")
        XCTAssertEqual(USBInventory.place(USBLocation(0x1450_0000), devices: [hub]), "a USB socket on the Mac")
        XCTAssertEqual(USBInventory.place(port, devices: []), "port 2 of a hub")
    }

    func testIdentitiesSayWhatAnRP2040IsRunning() {
        XCTAssertEqual(USBIdentity(vendor: 0x16D0, product: 0x08C6), .keypad(.keybow2040))
        XCTAssertEqual(USBIdentity(vendor: 0x239A, product: 0x80F4), .keypad(.rgbKeypad))
        XCTAssertEqual(USBIdentity(vendor: 0x2E8A, product: 0x0003), .bootloader)
        XCTAssertEqual(USBIdentity(vendor: 0x2E8A, product: 0x0005), .microPython)
        XCTAssertEqual(USBIdentity(vendor: 0x239A, product: 0x8120), .otherCircuitPython)
        XCTAssertEqual(USBIdentity(vendor: 0x303A, product: 0x4001), .other)
    }

    // MARK: The log

    func testTheKernelsWordsAreRead() {
        XCTAssertEqual(keybowArrives.kind, .arrived(vendor: 0x16D0, product: 0x08C6, name: "Keybow 2040", speed: "12 Mbps"))
        XCTAssertEqual(keybowArrives.location, USBLocation(0x1450_0000))
        XCTAssertEqual(event("HS06@14500000: AppleUSBHostPort::terminateDevice: destroying 0x303a/4001/0100 (Espressif Device): hardware connection lost", 0).kind,
                       .left(vendor: 0x303A, product: 0x4001, name: "Espressif Device", reason: "hardware connection lost"))
        XCTAssertEqual(event("AppleUSB20HubPort@14420000: AppleUSB20HubPort::resetAndCreateDevice: failed to address device, disabling port", 0).kind,
                       .couldNotAddress)
        XCTAssertEqual(event("AppleUSB20HubPort@14420000: AppleUSBHostPort::disconnect: persistent enumeration failures", 0).kind,
                       .gaveUp)
        XCTAssertNil(USBLog.event(message: "AppleUSB20HubPort@14420000: AppleUSBHostPort::createDevice: failed to create device (0xe00002bc)",
                                  date: now), "counted with the line after it")
        XCTAssertNil(USBLog.event(message: "Stream Deck@(null): AppleUSBHostUserClient::openGated: failed to open Keybow 2040@14500000",
                                  date: now))

        let json = #"{"timestamp":"2026-10-07 18:12:59.978123+0100","eventMessage":"AppleUSB20HubPort@14420000: AppleUSBHostPort::disconnect: persistent enumeration failures"}"#
        let read = USBLog.event(json: json)
        XCTAssertEqual(read?.kind, .gaveUp)
        XCTAssertEqual(read?.date.timeIntervalSince1970 ?? 0, 1_791_393_179.978, accuracy: 0.01)
    }

    func testEachPlugInIsOneRunHoweverManyTries() {
        let runs = Troubleshooter.incidents(in: failures(port: "14410000", from: 0) + failures(port: "14410000", from: 100))
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].attempts, 8)
        XCTAssertTrue(runs[0].gaveUp)
    }

    // MARK: A hub that's stopped working

    func testAFailingHubIsBlamedAndTheWayRoundItSaid() {
        let events = failures(port: "14410000", from: -1800) + failures(port: "14420000", from: -60)
        let facts = TroubleshootingFacts(now: now, sought: [sought], devices: [hub], events: events,
                                         eventsSince: at(-3600), connected: [])
        let findings = Troubleshooter.diagnose(facts)
        let hubTrouble = findings.first { $0.title.contains("couldn’t talk to something") }
        XCTAssertEqual(hubTrouble?.severity, .problem)
        XCTAssertEqual(hubTrouble?.title, "The Mac couldn’t talk to something plugged into ports 1 and 2 of the hub “USB2.0 HUB”")
        XCTAssertTrue(hubTrouble?.detail.contains("tried 8 times") == true)
        XCTAssertTrue(hubTrouble?.detail.contains("switched the port off") == true)
        XCTAssertTrue(hubTrouble?.detail.contains("the hub is the likeliest cause") == true)
        XCTAssertEqual(hubTrouble?.fixes.first, "Plug the keypad straight into a socket on the Mac.")
        XCTAssertTrue(hubTrouble?.fixes.contains { $0.contains("unplug the hub from the Mac") } == true)

        let missing = findings.first { $0.id.hasPrefix("missing") }
        XCTAssertEqual(missing?.title, "The Keybow 2040 isn’t plugged in, or the Mac can’t see it")
        XCTAssertTrue(missing?.detail.contains("trouble with a USB port") == true)
    }

    func testOnceItWorksElsewhereTheHubTroubleIsHistory() {
        let events = failures(port: "14420000", from: -120) + [keybowArrives]
        let facts = TroubleshootingFacts(now: now, sought: [sought], devices: [hub, keybowDevice],
                                         boards: [keybowBoard()], events: events, eventsSince: at(-3600),
                                         connected: [keybowID])
        let findings = Troubleshooter.diagnose(facts)
        XCTAssertEqual(findings.first { $0.id.hasPrefix("board") }?.title, "The Keybow 2040 is connected")
        let earlier = findings.first { $0.id.hasPrefix("incident") }
        XCTAssertEqual(earlier?.severity, .note, "found now: the hub's a note")
        XCTAssertTrue(earlier?.detail.contains("worked when it was plugged into a USB socket on the Mac") == true)
    }

    func testFailuresOnASocketBlameTheCable() {
        let events = (0..<3).map { event("HS06@14500000: AppleUSBHostPort::resetAndCreateDevice: failed to address device, disabling port", Double($0)) }
        let findings = Troubleshooter.diagnose(TroubleshootingFacts(now: now, sought: [sought], events: events,
                                                                    eventsSince: at(-3600), connected: []))
        let trouble = findings.first { $0.id.hasPrefix("incident") }
        XCTAssertEqual(trouble?.title, "The Mac couldn’t talk to something plugged into a USB socket on the Mac")
        XCTAssertEqual(trouble?.fixes.first, "Try another cable — one you know carries data.")
    }

    // MARK: Nothing at all

    func testNothingReachingTheMacAsksWhatTheKeysAreDoing() {
        let watched = DateInterval(start: at(-30), end: now)
        var facts = TroubleshootingFacts(now: now, sought: [sought], eventsSince: at(-3600), connected: [], watchedPlugIn: watched)
        var finding = Troubleshooter.diagnose(facts).first { $0.id.hasPrefix("missing") }
        XCTAssertEqual(finding?.title, "Nothing reached the Mac when the Keybow 2040 was plugged in")
        XCTAssertTrue(finding?.actions.contains(.askKeys) == true)

        facts.keys = .pulsingRed
        finding = Troubleshooter.diagnose(facts).first { $0.id.hasPrefix("missing") }
        XCTAssertEqual(finding?.title, "The Keybow 2040 has power, but no data reaches the Mac")
        XCTAssertTrue(finding?.detail.contains("a cable that only charges") == true)
        XCTAssertFalse(finding?.fixes.contains { $0.contains("Allow accessories") } == true)

        facts.isAppleSilicon = true
        finding = Troubleshooter.diagnose(facts).first { $0.id.hasPrefix("missing") }
        XCTAssertTrue(finding?.fixes.contains { $0.contains("Allow accessories to connect") } == true)

        facts.keys = .dark
        finding = Troubleshooter.diagnose(facts).first { $0.id.hasPrefix("missing") }
        XCTAssertEqual(finding?.title, "No power is reaching the Keybow 2040")
        XCTAssertTrue(finding?.fixes.contains { $0.contains("USB-C to USB-C") } == true)
    }

    func testAPicosMicroUSBCableIsMentioned() {
        let pico = SoughtKeypad(name: "RGB Keypad", model: .rgbKeypad, serial: picoID)
        let facts = TroubleshootingFacts(now: now, sought: [pico], connected: [], keys: .pulsingRed,
                                         watchedPlugIn: DateInterval(start: at(-30), end: now))
        let finding = Troubleshooter.diagnose(facts).first { $0.id.hasPrefix("missing") }
        XCTAssertTrue(finding?.fixes.contains { $0.contains("micro-USB") } == true)
    }

    func testSomethingElseArrivingIsSaid() {
        let watched = DateInterval(start: at(-30), end: now)
        let other = event("HS06@14500000: AppleUSBHostPort::enumerateDeviceComplete_block_invoke: enumerated 0x303a/4001/0100 (Espressif Device / 23) at 12 Mbps", -10)
        let facts = TroubleshootingFacts(now: now, sought: [sought], events: [other], connected: [], watchedPlugIn: watched)
        let finding = Troubleshooter.diagnose(facts).first { $0.id.hasPrefix("missing") }
        XCTAssertEqual(finding?.title, "Something else arrived, but not the Keybow 2040")
        XCTAssertTrue(finding?.detail.contains("“Espressif Device” on a USB socket on the Mac") == true)
    }

    func testSomethingElseWhereItWasIsPointedOut() {
        var keypad = sought
        keypad.lastLocation = USBLocation(0x1450_0000)
        let other = USBDevice(name: "Espressif Device", vendorID: 0x303A, productID: 0x4001, location: USBLocation(0x1450_0000))
        let findings = Troubleshooter.diagnose(TroubleshootingFacts(now: now, sought: [keypad], devices: [other], connected: []))
        XCTAssertEqual(findings.first { $0.id.hasPrefix("taken") }?.title,
                       "“Espressif Device” is where the Keybow 2040 was last plugged in")
    }

    // MARK: On USB, but not working

    func testAPortSomeoneElseHasIsNamed() {
        var facts = TroubleshootingFacts(now: now, sought: [sought], devices: [keybowDevice], boards: [keybowBoard()],
                                         connected: [], portUsers: ["/dev/cu.usbmodem14503": [PortUser(pid: 42, name: "screen")]])
        XCTAssertEqual(Troubleshooter.diagnose(facts).first?.title, "Another program has the Keybow 2040’s data port open")
        XCTAssertEqual(Troubleshooter.diagnose(facts).first?.fixes, ["Quit screen. KeybowNotes connects within a few seconds."])

        // From the command line, the app having it is all's well.
        facts.connected = nil
        facts.portUsers = ["/dev/cu.usbmodem14503": [PortUser(pid: 43, name: "KeybowNotes")]]
        XCTAssertEqual(Troubleshooter.diagnose(facts).first?.title, "The Keybow 2040 is connected")
    }

    func testAKeypadThatWontAnswerOffersToListen() {
        let facts = TroubleshootingFacts(now: now, sought: [sought], devices: [keybowDevice], boards: [keybowBoard()], connected: [])
        let finding = Troubleshooter.diagnose(facts).first
        XCTAssertEqual(finding?.title, "The Keybow 2040 is plugged in, but isn’t answering")
        XCTAssertEqual(finding?.actions.first, .readConsole(serial: keybowID))
    }

    func testFirmwareWithoutItsDataPortNeedsARestart() {
        let drive = CircuitPythonDrive(drive: URL(fileURLWithPath: "/Volumes/CIRCUITPY"),
                                       bootOut: BootOut(text: "Adafruit CircuitPython 10.3.1 on 2026-09-14; Pimoroni Keybow 2040 with rp2040\nBoard ID:pimoroni_keybow2040\nUID:\(keybowID)"),
                                       firmware: .current, model: .keybow2040)
        var facts = TroubleshootingFacts(now: now, sought: [sought], devices: [keybowDevice], boards: [keybowBoard(ports: 1)],
                                         drives: [drive], connected: [], keys: .steadyBlue, supportedMajors: 8...10)
        var finding = Troubleshooter.diagnose(facts).first
        XCTAssertEqual(finding?.title, "The Keybow 2040’s data port is off")
        XCTAssertTrue(finding?.detail.contains("That’s why its keys are blue") == true)
        XCTAssertEqual(finding?.actions.first, .restart(serial: keybowID))

        facts.drives[0].firmware = .other
        finding = Troubleshooter.diagnose(facts).first
        XCTAssertEqual(finding?.title, "The Keybow 2040 is running CircuitPython, but not the KeybowNotes firmware")
        XCTAssertEqual(finding?.actions, [.setUp])

        facts.drives[0].bootOut.version = CircuitPythonVersion("7.3.3")
        finding = Troubleshooter.diagnose(facts).first
        XCTAssertEqual(finding?.title, "The Keybow 2040 has CircuitPython 7.3.3, which the firmware doesn’t run on")
    }

    func testOlderFirmwareIsANote() {
        let drive = CircuitPythonDrive(drive: URL(fileURLWithPath: "/Volumes/CIRCUITPY"),
                                       bootOut: BootOut(text: "UID:\(keybowID)"), firmware: .older, model: .keybow2040)
        let findings = Troubleshooter.diagnose(TroubleshootingFacts(now: now, sought: [sought], devices: [keybowDevice],
                                                                    boards: [keybowBoard()], drives: [drive], connected: [keybowID]))
        XCTAssertEqual(findings.map(\.severity), [.note, .good])
        XCTAssertEqual(findings.first?.actions, [.setUp])
    }

    func testWhatTheConsoleSaysIsRead() {
        let safe = ConsoleReading(text: """
            Auto-reload is off.
            Running in safe mode! Not running saved code.

            You are in safe mode because:
            Power dipped. Make sure you are providing enough power.
            Press reset to exit safe mode.

            Press any key to enter the REPL. Use CTRL-D to reload.
            """)
        XCTAssertEqual(safe.state, .safeMode("Power dipped. Make sure you are providing enough power."))

        let crash = ConsoleReading(text: """
            code.py output:
            Traceback (most recent call last):
              File "code.py", line 33, in <module>
            ImportError: no module named 'pmk'

            Code done running.
            """)
        XCTAssertEqual(crash.state, .crashed("ImportError: no module named 'pmk'", place: "File \"code.py\", line 33, in <module>"))

        XCTAssertEqual(ConsoleReading(text: "usb_cdc.data is not available — check boot.py and hard-reset the keypad").state, .noDataPort)
        XCTAssertEqual(ConsoleReading(text: "KeybowNotes: ignored Ctrl-C from the console (an editor probing the board?)").state, .running)
        XCTAssertEqual(ConsoleReading(text: "Code done running.\nPress any key to enter the REPL.").state, .ended)
        XCTAssertEqual(ConsoleReading(text: "").state, .unknown)
    }

    func testWhatTheConsoleSaidDecides() {
        var facts = TroubleshootingFacts(now: now, sought: [sought], devices: [keybowDevice], boards: [keybowBoard()], connected: [])
        facts.console[keybowID] = ConsoleReading(text: "KeybowNotes crashed:\nTraceback (most recent call last):\n  File \"code.py\", line 33\nImportError: no module named 'pmk'")
        var finding = Troubleshooter.diagnose(facts).first
        XCTAssertEqual(finding?.title, "The Keybow 2040’s program keeps crashing")
        XCTAssertTrue(finding?.detail.contains("A library it needs is missing") == true)

        facts.boards = [keybowBoard(ports: 1)]
        facts.console[keybowID] = ConsoleReading(text: "You are in safe mode because:\nPower dipped. Make sure you are providing enough power.\n")
        finding = Troubleshooter.diagnose(facts).first
        XCTAssertEqual(finding?.title, "The Keybow 2040 is in safe mode")
        XCTAssertTrue(finding?.fixes.contains { $0.contains("hub with its own power supply") } == true)
    }

    // MARK: Running something else

    func testABoardInItsBootloaderIsExplained() {
        let waiting = USBDevice(name: "RP2 Boot", vendorID: 0x2E8A, productID: 0x0003, location: USBLocation(0x1450_0000))
        let findings = Troubleshooter.diagnose(TroubleshootingFacts(now: now, devices: [waiting], connected: []))
        XCTAssertEqual(findings.first?.title, "A board is waiting in its bootloader, on a USB socket on the Mac")
        XCTAssertFalse(findings.contains { $0.id.hasPrefix("missing") }, "it's what Set Up is waiting for")
    }

    func testAKeypadRunningMicroPythonIsKnownByItsID() {
        let pico = SoughtKeypad(name: "RGB Keypad", model: .rgbKeypad, serial: picoID)
        let micro = USBDevice(name: "Board in FS mode", vendorID: 0x2E8A, productID: 0x0005, serial: picoID,
                              location: USBLocation(0x1480_0000))
        let finding = Troubleshooter.diagnose(TroubleshootingFacts(now: now, sought: [pico], devices: [micro], connected: [])).first
        XCTAssertEqual(finding?.title, "The RGB Keypad on a USB socket on the Mac is running MicroPython")
        XCTAssertEqual(finding?.severity, .problem)
    }

    // MARK: Power and loose plugs

    func testAKeypadThatKeepsDroppingOutIsCaught() {
        let gone = (0..<3).map { event("HS06@14500000: AppleUSBHostPort::terminateDevice: destroying 0x16d0/08c6/0100 (Keybow 2040): hardware connection lost", Double($0) * -120) }
        var facts = TroubleshootingFacts(now: now, sought: [sought], devices: [keybowDevice], boards: [keybowBoard()], events: gone,
                                         connected: [keybowID])
        XCTAssertEqual(Troubleshooter.diagnose(facts).first?.title, "The Keybow 2040 keeps disconnecting")

        facts.restarts = [DateInterval(start: at(-600), end: now)]
        XCTAssertFalse(Troubleshooter.diagnose(facts).contains { $0.id.hasPrefix("flapping") }, "Set Up restarted it")
    }

    func testTooMuchPowerIsAProblem() {
        let power = USBLogEvent(date: at(-60), location: USBLocation(0x1440_0000), kind: .overcurrent)
        let findings = Troubleshooter.diagnose(TroubleshootingFacts(now: now, sought: [sought], events: [power], connected: []))
        XCTAssertEqual(findings.first { $0.id == "overcurrent" }?.severity, .problem)
        XCTAssertEqual(findings.first { $0.id == "overcurrent" }?.title, "A USB port was switched off for drawing too much power")
    }

    // MARK: What's looked for

    func testKeypadsKnownAndNamedAreLookedFor() throws {
        let (document, _) = OutlineParser.parse("""
            1. Work [Copy]

            # keypad Desk [Keybow 2040, id: \(keybowID)]
            1. Desk [Copy]

            # keypad Spare [RGB Keypad]
            1. Spare [Copy]
            """)
        let config = try XCTUnwrap(OutlineCompiler.compile(document, locateApp: { _ in nil }).config)
        let known = [KnownKeypad(serial: keybowID, model: .keybow2040, lastSeen: at(-60))]
        let sought = SoughtKeypad.all(known: known, config: config)
        XCTAssertEqual(sought.map(\.name), ["Desk", "Spare"])
        XCTAssertEqual(sought[0].serial, keybowID)
        XCTAssertEqual(sought[0].lastSeen, at(-60))
        XCTAssertNil(sought[1].serial)
        XCTAssertEqual(sought[1].model, .rgbKeypad)

        let noted = KnownKeypads.record([KeypadDevice(serial: picoID, model: .rgbKeypad, dataPort: "/dev/cu.x")],
                                        devices: [hub, USBDevice(name: "Pico", vendorID: 0x239A, productID: 0x80F4,
                                                                 serial: picoID, location: USBLocation(0x1442_0000))],
                                        into: known, now: now)
        XCTAssertEqual(noted.count, 2)
        XCTAssertEqual(noted[1].lastPlace, "port 2 of the hub “USB2.0 HUB”")
        XCTAssertEqual(noted[1].lastLocation, 0x1442_0000)
        XCTAssertEqual(SoughtKeypad.all(known: noted, config: config).map(\.name), ["Desk", "RGB Keypad"],
                       "the RGB Keypad seen is the one the section means")
    }

    func testTheReportHasItAll() {
        let events = failures(port: "14420000", from: -60)
        let facts = TroubleshootingFacts(now: now, sought: [sought], devices: [hub], events: events, eventsSince: at(-3600),
                                         connected: [], keys: .pulsingRed)
        let report = Troubleshooter.report(facts, findings: Troubleshooter.diagnose(facts), version: "1.0")
        XCTAssertTrue(report.contains("[PROBLEM] The Mac couldn’t talk to something plugged into port 2 of the hub “USB2.0 HUB”"))
        XCTAssertTrue(report.contains("Its keys: Slowly pulsing red"))
        XCTAssertTrue(report.contains("USB2.0 HUB 1a40:0101 at 14400000"))
        XCTAssertTrue(report.contains("14420000 gave up, and switched the port off"))
        XCTAssertTrue(report.contains("KeybowNotes 1.0"))
    }
}
