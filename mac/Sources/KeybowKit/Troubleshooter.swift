import Foundation

/// Works out what's wrong with a keypad that isn't working, from what
/// `TroubleshootingFacts` gathers: what's plugged in, what the USB log says
/// happened, what its drive, ports and console show, and what the person
/// says its keys are doing. No guessing beyond what those say, and no AI:
/// each rule is a known way a keypad goes missing, and what fixes it.
public enum Troubleshooter {
    public static func diagnose(_ facts: TroubleshootingFacts) -> [Finding] {
        let sought = facts.sought.isEmpty ? [SoughtKeypad.any] : facts.sought
        var findings: [Finding] = []
        for keypad in sought {
            findings += look(for: keypad, in: facts)
        }
        findings += general(facts, sought: sought)
        var seen = Set<String>()
        findings = findings.filter { seen.insert($0.id).inserted }
        // Worst first, otherwise as found.
        return findings.enumerated().sorted { a, b in
            a.element.severity != b.element.severity ? a.element.severity > b.element.severity : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: - One keypad

    private static func look(for keypad: SoughtKeypad, in facts: TroubleshootingFacts) -> [Finding] {
        let boards = facts.boards.filter { board in
            if let serial = keypad.serial { return same(board.serial, serial) }
            if let model = keypad.model { return board.model == model }
            return true
        }
        if !boards.isEmpty {
            return boards.flatMap { found($0, as: keypad, in: facts) }
        }
        // On USB, but not as a keypad: its unique ID says it's the one.
        if let serial = keypad.serial, let device = facts.devices.first(where: { same($0.serial, serial) }) {
            guard case .keypad = device.identity else { return [elsewise(device, as: keypad, in: facts)] }
            return [Finding(
                id: "ports-\(serial)", severity: .warning,
                title: "The \(keypad.name) is plugged in, but its serial ports haven’t appeared",
                detail: "macOS sees it on \(USBInventory.place(device.location, devices: facts.devices)), but hasn’t set up "
                    + "the ports KeybowNotes talks to it through.",
                fixes: ["Wait a few seconds, then check again.", "Unplug it and plug it back in."])]
        }
        var findings: [Finding] = []
        if let waiting = bootloader(in: facts) {
            findings.append(waiting(keypad))
        }
        let others = facts.devices.filter { device in
            switch device.identity {
            case .microPython, .picoProgram: return true
            case .otherCircuitPython: return keypad.isAny
            default: return false
            }
        }
        findings += others.map { elsewise($0, as: keypad, in: facts, sure: false) }
        if keypad.isAny, !findings.isEmpty { return findings }
        findings.append(missing(keypad, in: facts))
        return findings
    }

    /// A keypad's board, running CircuitPython.
    private static func found(_ board: USBSerialPorts.Board, as keypad: SoughtKeypad,
                              in facts: TroubleshootingFacts) -> [Finding] {
        let name = keypad.isAny ? "The \(board.model.title)" : "The \(keypad.name)"
        let id = "board-\(board.serial)"
        let place = facts.devices.first { same($0.serial, board.serial) }
            .map { USBInventory.place($0.location, devices: facts.devices) }
        let on = place.map { " It’s on \($0)." } ?? ""
        let drive = facts.drives.first { same($0.bootOut.uid, board.serial) }
        let reading = facts.console[board.serial.uppercased()]
        var findings: [Finding] = []

        if case .crashed(let error, let where_)? = reading?.state {
            findings.append(crashing(name, id: id, error: error, place: where_))
        } else if case .safeMode(let reason)? = reading?.state {
            findings.append(safeMode(name, id: id, reason: reason))
        } else if board.ports.count >= 2, let data = board.ports.last {
            // The app itself, seen from the command line, is no stranger.
            let users = facts.portUsers[data] ?? []
            let others = users.filter { !$0.name.lowercased().hasPrefix("keybownotes") }
            if facts.connected?.contains(board.serial.uppercased()) == true
                || (facts.connected == nil && others.isEmpty && !users.isEmpty) {
                findings.append(Finding(id: id, severity: .good, title: "\(name) is connected", detail: on.trimmed))
            } else if !others.isEmpty {
                let names = others.map(\.name).joinedAsList
                findings.append(Finding(
                    id: id, severity: .problem, title: "Another program has \(name.lowercasedFirst)’s data port open",
                    detail: "\(names) has it, and can take what the keypad says before KeybowNotes hears it.",
                    fixes: ["Quit \(names). KeybowNotes connects within a few seconds."]))
            } else if facts.connected == nil {
                findings.append(Finding(id: id, severity: .good, title: "\(name) is plugged in, with its data port on",
                                        detail: on.trimmed))
            } else if reading?.state == .running {
                findings.append(Finding(
                    id: id, severity: .warning, title: "\(name)’s firmware is running, but KeybowNotes hasn’t heard from it",
                    detail: "Its console says it’s running as it should." + on,
                    fixes: ["Quit KeybowNotes and open it again.", "Unplug the keypad and plug it back in."]))
            } else if facts.keys == .flashingPurple {
                findings.append(crashing(name, id: id, error: nil, place: nil, serial: board.serial))
            } else {
                findings.append(Finding(
                    id: id, severity: .warning, title: "\(name) is plugged in, but isn’t answering",
                    detail: "Its data port is there, but its firmware hasn’t said hello." + on,
                    fixes: ["Unplug it and plug it back in.", "If it still doesn’t answer, set it up again: its firmware is copied afresh."],
                    actions: [.readConsole(serial: board.serial), .askKeys, .setUp]))
            }
        } else if let drive {
            if let major = drive.bootOut.version?.major, let supported = facts.supportedMajors, !supported.contains(major) {
                findings.append(Finding(
                    id: id, severity: .problem,
                    title: "\(name) has CircuitPython \(drive.bootOut.version!), which the firmware doesn’t run on",
                    fixes: ["Set it up: it’s given a CircuitPython the firmware runs on."], actions: [.setUp]))
            } else if drive.firmware == .other || drive.firmware == nil {
                findings.append(Finding(
                    id: id, severity: .problem, title: "\(name) is running CircuitPython, but not the KeybowNotes firmware",
                    detail: "Its drive, \(drive.drive.lastPathComponent), doesn’t have the firmware’s files." + on,
                    fixes: ["Set it up: the firmware is copied to it, and anything it replaces is backed up first."],
                    actions: [.setUp]))
            } else {
                findings.append(dataPortOff(name, id: id, serial: board.serial, keys: facts.keys, on: on))
            }
        } else {
            findings.append(Finding(
                id: id, severity: .warning, title: "\(name) is running CircuitPython, but its drive isn’t showing",
                detail: "So whether it has the KeybowNotes firmware can’t be checked, and its data port is off." + on,
                fixes: ["Unplug it and plug it back in.", "If it’s still the same, set it up."],
                actions: [.restart(serial: board.serial), .readConsole(serial: board.serial), .setUp]))
        }
        if let drive, drive.firmware == .older {
            findings.append(Finding(
                id: "older-\(board.serial)", severity: .note,
                title: "\(name)’s firmware is older than this version of KeybowNotes’s",
                fixes: ["Set it up again to bring it up to date. Whatever it replaces is backed up first."], actions: [.setUp]))
        }
        return findings
    }

    private static func crashing(_ name: String, id: String, error: String?, place: String?, serial: String? = nil) -> Finding {
        var detail = error.map { "It stops with: \($0)" + (place.map { " (\($0))" } ?? "") + "." }
            ?? "Its keys flash purple each time it starts again."
        var fixes = ["Set it up again: its firmware and libraries are copied afresh."]
        if let error, error.contains("ImportError") || error.contains("no module named") {
            detail += " A library it needs is missing from its drive."
        } else if let place, place.contains("keymap.py") {
            fixes.insert("If keymap.py on its drive was changed, put it back — setting it up again does.", at: 0)
        } else if let error, error.contains("MemoryError") {
            detail += " It ran out of memory."
        }
        return Finding(id: id, severity: .problem, title: "\(name)’s program keeps crashing", detail: detail, fixes: fixes,
                       actions: [serial.map { .readConsole(serial: $0) }, .setUp].compactMap { $0 })
    }

    private static func safeMode(_ name: String, id: String, reason: String) -> Finding {
        var fixes = ["Unplug it and plug it back in."]
        let lowered = reason.lowercased()
        if lowered.contains("power") || lowered.contains("brownout") {
            fixes += ["Plug it straight into a socket on the Mac, or into a hub with its own power supply.",
                      "Turn the key brightness down in Settings: lit keys draw power."]
        } else {
            fixes.append("If it keeps happening, set it up again.")
        }
        return Finding(id: id, severity: .problem, title: "\(name) is in safe mode",
                       detail: "CircuitPython started without running anything" + (reason.isEmpty ? "." : ": “\(reason)”"),
                       fixes: fixes, actions: [.setUp])
    }

    private static func dataPortOff(_ name: String, id: String, serial: String, keys: KeyLights?, on: String) -> Finding {
        Finding(
            id: id, severity: .warning, title: "\(name)’s data port is off",
            detail: "Its firmware is there, but boot.py — which turns the data port on — only runs as the keypad starts up, "
                + "and hasn’t since the firmware was copied." + (keys == .steadyBlue ? " That’s why its keys are blue." : "") + on,
            fixes: ["Unplug it and plug it back in.", "If its data port’s still off, set it up again."],
            actions: [.restart(serial: serial), .readConsole(serial: serial), .setUp])
    }

    /// On USB, but running something other than the KeybowNotes firmware.
    private static func elsewise(_ device: USBDevice, as keypad: SoughtKeypad, in facts: TroubleshootingFacts,
                                 sure: Bool = true) -> Finding {
        let name = keypad.isAny || !sure ? "A board" : "The \(keypad.name)"
        let running: String
        switch device.identity {
        case .microPython: running = "MicroPython"
        case .picoProgram: running = "a program of its own"
        case .otherCircuitPython: running = "CircuitPython for another board, “\(device.name)”"
        case .bootloader: return bootloaderFinding(name, place: USBInventory.place(device.location, devices: facts.devices))
        default: running = "something else: “\(device.name)”"
        }
        let place = USBInventory.place(device.location, devices: facts.devices)
        let maybe = sure || keypad.isAny ? "" : " If it’s the \(keypad.name), it needs setting up."
        return Finding(
            id: "elsewise-\(device.location)", severity: sure ? .problem : .note,
            title: "\(name) on \(place) is running \(running)",
            detail: "KeybowNotes needs CircuitPython and its own firmware on it." + maybe,
            fixes: ["Set it up: CircuitPython and the firmware are put on it."], actions: [.setUp])
    }

    /// A board in its bootloader, if there is one: it can't say which.
    private static func bootloader(in facts: TroubleshootingFacts) -> ((SoughtKeypad) -> Finding)? {
        let device = facts.devices.first { $0.identity == .bootloader }
        guard device != nil || !facts.bootloaderDrives.isEmpty else { return nil }
        let place = device.map { USBInventory.place($0.location, devices: facts.devices) }
        return { keypad in
            bootloaderFinding(keypad.isAny ? "A board" : "A board — perhaps the \(keypad.name) —", place: place)
        }
    }

    private static func bootloaderFinding(_ name: String, place: String?) -> Finding {
        Finding(
            id: "bootloader", severity: .warning,
            title: "\(name) is waiting in its bootloader" + (place.map { ", on \($0)" } ?? ""),
            detail: "That’s how an RP2040 starts when its BOOT button — BOOTSEL on a Pico — is held as it’s plugged in "
                + "or reset. It shows a drive called RPI-RP2, and runs nothing until it’s given CircuitPython or restarted.",
            fixes: ["To use it as it was, unplug it and plug it back in without holding any button.",
                    "To give it CircuitPython and the firmware, set it up."],
            actions: [.setUp])
    }

    /// Not on USB at all.
    private static func missing(_ keypad: SoughtKeypad, in facts: TroubleshootingFacts) -> Finding {
        let name = keypad.isAny ? "a keypad" : "the \(keypad.name)"
        let id = "missing-\(keypad.serial ?? keypad.model?.rawValue ?? "any")"
        let since = max(keypad.lastSeen ?? facts.eventsSince, facts.eventsSince)
        let trouble = incidents(in: facts.events).contains { $0.end >= since }
        var history = ""
        if let seen = keypad.lastSeen {
            history = "It was last seen \(when(seen, now: facts.now))" + (keypad.lastPlace.map { ", on \($0)" } ?? "") + "."
        }
        if trouble {
            history += history.isEmpty ? "The Mac has had trouble with a USB port lately."
                : " Since then, the Mac has had trouble with a USB port."
        }

        if let watched = facts.watchedPlugIn {
            let during = facts.events.filter { watched.contains($0.date) }
            if during.isEmpty { return nothingReached(keypad, id: id, in: facts) }
            let arrivals = during.compactMap { event -> String? in
                guard case .arrived(_, _, let other, _) = event.kind else { return nil }
                return "“\(other)” on \(USBInventory.place(event.location, devices: facts.devices))"
            }
            if !arrivals.isEmpty, !trouble {
                return Finding(
                    id: id, severity: .problem, title: "Something else arrived, but not \(name)",
                    detail: "While watching, the Mac saw \(arrivals.joinedAsList) plugged in. If that was the cable you "
                        + "plugged in, it leads somewhere other than the keypad.",
                    fixes: ["Follow the cable from the keypad to the Mac, and plug that one in."],
                    actions: [.watchPlugIn])
            }
        }
        if let keys = facts.keys, !trouble {
            return keys.hasPower ? noData(keypad, id: id, in: facts, watched: false, history: history)
                : noPower(keypad, id: id, in: facts, history: history)
        }
        return Finding(
            id: id, severity: trouble ? .warning : .problem,
            title: keypad.isAny ? "No keypad is plugged in, or the Mac can’t see it"
                : "\(name.capitalizedFirst) isn’t plugged in, or the Mac can’t see it",
            detail: history.isEmpty ? "Unplug it and plug it back in while this watches: what the Mac sees then says what’s wrong."
                : history,
            fixes: trouble ? [] : ["Watch while you unplug it and plug it back in."],
            actions: [.watchPlugIn, .askKeys])
    }

    private static func nothingReached(_ keypad: SoughtKeypad, id: String, in facts: TroubleshootingFacts) -> Finding {
        let name = keypad.isAny ? "the keypad" : "the \(keypad.name)"
        switch facts.keys {
        case nil:
            return Finding(
                id: id, severity: .problem, title: "Nothing reached the Mac when \(name) was plugged in",
                detail: "Not even a failed attempt: no data is getting through. What its keys are doing says why.",
                actions: [.askKeys, .watchPlugIn])
        case let keys? where keys.hasPower:
            return noData(keypad, id: id, in: facts, watched: true, history: "")
        default:
            return noPower(keypad, id: id, in: facts, history: "")
        }
    }

    private static func noData(_ keypad: SoughtKeypad, id: String, in facts: TroubleshootingFacts, watched: Bool,
                               history: String) -> Finding {
        let name = keypad.isAny ? "the keypad" : "the \(keypad.name)"
        var fixes = ["Use a cable you know carries data — one you’ve copied files to or from a phone with, say. "
                     + "Many cables only charge."]
        switch keypad.model {
        case .rgbKeypad?: fixes.append("The Pico takes micro-USB, and a lot of micro-USB cables only charge.")
        default: break
        }
        fixes += ["Check the plug is pushed fully into the keypad.", "Try another socket on the Mac."]
        if facts.isAppleSilicon {
            fixes.append("In System Settings, Privacy & Security, check “Allow accessories to connect”: a refused or "
                         + "missed question about a new accessory keeps it out.")
        }
        let seen = watched ? "the Mac saw nothing at all when it was plugged in"
            : "the Mac can’t see it. Watching it plugged in would confirm it"
        return Finding(
            id: id, severity: .problem, title: "\(name.capitalizedFirst) has power, but no data reaches the Mac",
            detail: "Its keys are lit, so its firmware’s running — but \(seen). That’s almost always a cable that only "
                + "charges." + (history.isEmpty ? "" : " " + history),
            fixes: fixes, actions: watched ? [] : [.watchPlugIn])
    }

    private static func noPower(_ keypad: SoughtKeypad, id: String, in facts: TroubleshootingFacts,
                                history: String) -> Finding {
        let name = keypad.isAny ? "the keypad" : "the \(keypad.name)"
        var fixes = ["Check the cable is pushed fully in at both ends.",
                     "Try another socket on the Mac. If it’s on a hub, check the hub is on, or has its own power.",
                     "Try another cable."]
        if keypad.model != .rgbKeypad {
            fixes.append("If the cable has USB-C at both ends, try one with USB-A at the Mac’s end, through an adapter "
                         + "if need be: some boards take no power from USB-C to USB-C.")
        }
        return Finding(
            id: id, severity: .problem, title: "No power is reaching \(name)",
            detail: "Its keys are dark, and the Mac can’t see it." + (history.isEmpty ? "" : " " + history),
            fixes: fixes, actions: [.watchPlugIn])
    }

    // MARK: - Ports and the log

    /// A run of failed attempts on one port.
    struct Incident: Equatable {
        var location: USBLocation
        var start: Date
        var end: Date
        var attempts: Int
        var gaveUp: Bool
    }

    /// Failed attempts, each port's grouped into runs: one plug-in, however
    /// many times it was tried.
    static func incidents(in events: [USBLogEvent]) -> [Incident] {
        var runs: [Incident] = []
        for event in events.sorted(by: { $0.date < $1.date }) {
            guard event.kind == .couldNotAddress || event.kind == .gaveUp else { continue }
            if let index = runs.lastIndex(where: { $0.location == event.location }),
               event.date.timeIntervalSince(runs[index].end) < 30, !runs[index].gaveUp {
                runs[index].end = event.date
                if event.kind == .gaveUp { runs[index].gaveUp = true } else { runs[index].attempts += 1 }
            } else {
                runs.append(Incident(location: event.location, start: event.date, end: event.date,
                                     attempts: event.kind == .couldNotAddress ? 1 : 0, gaveUp: event.kind == .gaveUp))
            }
        }
        return runs
    }

    /// What isn't about one keypad: failing ports, power, a keypad that
    /// keeps dropping out.
    private static func general(_ facts: TroubleshootingFacts, sought: [SoughtKeypad]) -> [Finding] {
        var findings: [Finding] = []
        let anyMissing = sought.contains { keypad in
            !facts.boards.contains { board in
                if let serial = keypad.serial { return same(board.serial, serial) }
                if let model = keypad.model { return board.model == model }
                return true
            }
        }
        // Failures on a hub's ports, or a socket's, taken together: three
        // goes at one hub are one finding.
        let runs = incidents(in: facts.events)
        var places: [USBLocation] = []
        for run in runs.reversed() where !places.contains(run.location.hub ?? run.location) {
            places.append(run.location.hub ?? run.location)
        }
        for place in places.prefix(3) {
            findings.append(incident(runs.filter { ($0.location.hub ?? $0.location) == place }, in: facts, matters: anyMissing))
        }

        if let power = facts.events.last(where: { $0.kind == .overcurrent }) {
            findings.append(Finding(
                id: "overcurrent", severity: .problem,
                title: "A USB port was switched off for drawing too much power",
                detail: "\(USBInventory.place(power.location, devices: facts.devices).capitalizedFirst), "
                    + "\(when(power.date, now: facts.now)).",
                fixes: ["Unplug what’s on that port — or on that hub — and plug the keypad straight into the Mac.",
                        "Use a hub with its own power supply for anything that draws a lot.",
                        "Turn the key brightness down in Settings: lit keys draw power."]))
        }

        // A keypad that keeps going: three times in ten minutes.
        for model in KeypadDevice.Model.allCases {
            let gone = facts.events.filter { event in
                guard case .left(let vendor, let product, _, _) = event.kind,
                      !facts.restarts.contains(where: { $0.contains(event.date) }) else { return false }
                return USBIdentity(vendor: vendor, product: product) == .keypad(model)
            }
            if let last = gone.last, gone.filter({ last.date.timeIntervalSince($0.date) <= 600 }).count >= 3 {
                findings.append(Finding(
                    id: "flapping-\(model.rawValue)", severity: .warning,
                    title: "The \(model.title) keeps disconnecting",
                    detail: "It’s dropped off USB \(gone.count) times since \(when(facts.eventsSince, now: facts.now)), "
                        + "the last \(when(last.date, now: facts.now)).",
                    fixes: ["Check the cable is pushed fully in at both ends: a loose plug does this.",
                            "Try another cable.",
                            "If it’s on a hub, plug it straight into the Mac.",
                            "Turn the key brightness down in Settings: a dip in power restarts it."]))
            }
        }

        // Something else now where a missing keypad last was.
        for keypad in sought {
            guard let location = keypad.lastLocation,
                  !facts.boards.contains(where: { board in keypad.serial.map { same(board.serial, $0) } ?? false }),
                  let other = facts.devices.first(where: { $0.location == location && !$0.identity.isRP2040 })
            else { continue }
            findings.append(Finding(
                id: "taken-\(location)", severity: .note,
                title: "“\(other.name)” is where the \(keypad.name) was last plugged in",
                detail: "On \(USBInventory.place(location, devices: facts.devices)). If the keypad’s cable goes into that "
                    + "socket, check what’s on its other end."))
        }
        return findings
    }

    /// Runs of failures on one hub's ports, or one socket.
    private static func incident(_ runs: [Incident], in facts: TroubleshootingFacts, matters: Bool) -> Finding {
        let first = runs[0]
        let last = runs[runs.count - 1]
        let hub = first.location.hub
        let ports = Array(Set(runs.compactMap { $0.location.ports.last })).sorted()
        let place: String
        if let hub {
            let name = facts.devices.first { $0.location == hub }.map { "the hub “\($0.name)”" } ?? "a hub"
            place = (ports.count == 1 ? "port \(ports[0])" : "ports " + ports.map(String.init).joinedAsList) + " of \(name)"
        } else {
            place = USBInventory.place(first.location, devices: facts.devices)
        }
        let sameDay = runs.allSatisfy { Calendar.current.isDate($0.start, inSameDayAs: facts.now) }
        let times = sameDay ? "at " + runs.map { when($0.start, now: facts.now).dropFirst(3).description }.joinedAsList
            : runs.map { when($0.start, now: facts.now) }.joinedAsList
        let tries = Set(runs.map(\.attempts))
        let count = tries.count == 1 ? "\(tries.first!) time\(tries.first! == 1 ? "" : "s")"
            : "\(tries.min()!)–\(tries.max()!) times"
        let gaveUp = runs.allSatisfy(\.gaveUp)
        var detail = runs.count == 1
            ? "\(times.capitalizedFirst), macOS tried \(count) to set up what was plugged in" + (gaveUp ? ", then switched the port off." : ".")
            : "Something was plugged in \(times). Each time, macOS tried \(count) to set it up"
                + (gaveUp ? ", then switched the port off." : ".")
        if hub != nil, ports.count > 1 {
            detail += " It’s happened on \(ports.count) of this hub’s ports, so the hub is the likeliest cause."
        }
        var severity: Finding.Severity = matters ? .problem : .note
        let later = facts.events.filter { event in
            guard event.date > last.end, case .arrived = event.kind else { return false }
            return true
        }
        let failed = Set(runs.map(\.location))
        if let keypad = later.first(where: { event in
            guard case .arrived(let vendor, let product, _, _) = event.kind, !failed.contains(event.location) else { return false }
            if case .keypad = USBIdentity(vendor: vendor, product: product) { return true }
            return false
        }), case .arrived(_, _, let name, _) = keypad.kind {
            detail += " The \(name) worked when it was plugged into \(USBInventory.place(keypad.location, devices: facts.devices)) "
                + "\(when(keypad.date, now: facts.now)), so the keypad is fine. If that was with the same cable, the trouble is "
                + (hub != nil ? "the hub, or its power." : "that socket.")
        } else if let fine = later.first(where: { failed.contains($0.location) }), case .arrived(_, _, let name, _) = fine.kind {
            detail += " Since then, “\(name)” has worked there."
            severity = .note
        }
        let fixes = hub != nil
            ? ["Plug the keypad straight into a socket on the Mac.",
               "To use the hub again, unplug the hub from the Mac and plug it back in: that turns its ports back on.",
               "If it happens again, give the hub its own power supply, if it takes one — or try another hub.",
               "A shorter cable can help, too."]
            : ["Try another cable — one you know carries data.",
               "Try another socket on the Mac.",
               "Check the plug is pushed fully into the keypad."]
        return Finding(id: "incident-\(hub ?? first.location)", severity: severity,
                       title: "The Mac couldn’t talk to something plugged into \(place)", detail: detail, fixes: fixes)
    }

    // MARK: - Words

    /// The same unique ID, whatever its case.
    public static func same(_ a: String?, _ b: String) -> Bool {
        a?.caseInsensitiveCompare(b) == .orderedSame
    }

    /// "at 18:12", "yesterday at 18:12", "on 5 Oct 2026 at 18:12".
    public static func when(_ date: Date, now: Date = Date()) -> String {
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time.string(from: date))" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time.string(from: date))"
        }
        let day = DateFormatter()
        day.dateStyle = .medium
        day.timeStyle = .none
        return "on \(day.string(from: date)) at \(time.string(from: date))"
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}

extension Array where Element == String {
    /// "a", "a and b", "a, b and c".
    var joinedAsList: String {
        count <= 2 ? joined(separator: " and ") : dropLast().joined(separator: ", ") + " and " + last!
    }
}

extension Troubleshooter {
    /// Everything found, as plain text: for copying into an email or an
    /// issue, so someone else can help.
    public static func report(_ facts: TroubleshootingFacts, findings: [Finding], version: String? = nil) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["KeybowNotes keypad troubleshooting, \(stamp.string(from: facts.now))"]
        let system = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion), "
                     + (facts.isAppleSilicon ? "Apple silicon" : "Intel") + (version.map { ", KeybowNotes \($0)" } ?? ""))
        if !facts.sought.isEmpty {
            lines.append("Looking for: " + facts.sought.map { keypad in
                [keypad.name, keypad.serial.map { "ID \($0)" }, keypad.lastSeen.map { "last seen \(stamp.string(from: $0))" },
                 keypad.lastPlace].compactMap { $0 }.joined(separator: ", ")
            }.joined(separator: "; "))
        }
        if let keys = facts.keys { lines.append("Its keys: \(keys.title)") }

        lines += ["", "FOUND"]
        for finding in findings {
            let mark: String
            switch finding.severity {
            case .problem: mark = "PROBLEM"
            case .warning: mark = "WARNING"
            case .note: mark = "NOTE"
            case .good: mark = "OK"
            }
            lines.append("[\(mark)] \(finding.title)")
            if !finding.detail.isEmpty { lines.append("    \(finding.detail)") }
            for (number, fix) in finding.fixes.enumerated() { lines.append("    \(number + 1). \(fix)") }
        }

        lines += ["", "KEYPAD BOARDS"]
        if facts.boards.isEmpty { lines.append("    none") }
        for board in facts.boards {
            lines.append("    \(board.model.title) ID \(board.serial): " + board.ports.joined(separator: ", ")
                         + (facts.connected.map { $0.contains(board.serial.uppercased()) ? " (connected)" : " (not connected)" } ?? ""))
        }
        for (port, users) in facts.portUsers.sorted(by: { $0.key < $1.key }) {
            lines.append("    \(port) is open in " + users.map { "\($0.name) (\($0.pid))" }.joined(separator: ", "))
        }
        lines += ["", "DRIVES"]
        if facts.drives.isEmpty && facts.bootloaderDrives.isEmpty { lines.append("    none") }
        for drive in facts.drives {
            let firmware: String
            switch drive.firmware {
            case .current?: firmware = "firmware up to date"
            case .older?: firmware = "older firmware"
            case .other?: firmware = "no KeybowNotes firmware"
            case nil: firmware = "not a keypad"
            }
            lines.append("    \(drive.drive.lastPathComponent): CircuitPython \(drive.bootOut.version?.description ?? "?") on "
                         + "\(drive.bootOut.boardID ?? "?"), ID \(drive.bootOut.uid ?? "?"), \(firmware)")
        }
        for drive in facts.bootloaderDrives { lines.append("    \(drive.lastPathComponent): an RP2040 bootloader") }

        lines += ["", "USB DEVICES"]
        for device in facts.devices where !device.isBuiltIn {
            lines.append(String(format: "    %@ %04x:%04x at %@ — %@", device.name, device.vendorID, device.productID,
                                device.location.description, USBInventory.place(device.location, devices: facts.devices)))
        }
        lines += ["", "USB LOG SINCE \(stamp.string(from: facts.eventsSince))"]
        if facts.events.isEmpty { lines.append("    nothing") }
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm:ss"
        for event in facts.events {
            let what: String
            switch event.kind {
            case .arrived(let vendor, let product, let name, let speed):
                what = String(format: "arrived: %@ %04x:%04x at %@", name, vendor, product, speed)
            case .left(let vendor, let product, let name, let reason):
                what = String(format: "left: %@ %04x:%04x, %@", name, vendor, product, reason)
            case .couldNotAddress: what = "couldn't set up what's plugged in"
            case .gaveUp: what = "gave up, and switched the port off"
            case .overcurrent: what = "too much power drawn"
            }
            lines.append("    \(time.string(from: event.date)) \(event.location) \(what)")
        }
        if let watched = facts.watchedPlugIn {
            lines.append("    (watched a plug-in from \(time.string(from: watched.start)) to \(time.string(from: watched.end)))")
        }
        for (serial, reading) in facts.console.sorted(by: { $0.key < $1.key }) {
            lines += ["", "CONSOLE OF \(serial)"]
            lines += reading.text.split(whereSeparator: \.isNewline).suffix(40).map { "    " + $0 }
        }
        return lines.joined(separator: "\n")
    }
}
