import AppKit
import Foundation

public struct ActionOutcome: Equatable, Sendable {
    public let succeeded: Bool
    /// One line for the overlay: "Created “Standup — 26 Sep 2026”".
    public let message: String
    /// Anything worth knowing beyond that: where it went, what to fix.
    public let detail: String?

    public static func success(_ message: String, _ detail: String? = nil) -> ActionOutcome {
        ActionOutcome(succeeded: true, message: message, detail: detail)
    }

    public static func failure(_ message: String, _ detail: String? = nil) -> ActionOutcome {
        ActionOutcome(succeeded: false, message: message, detail: detail)
    }
}

/// Carries out a plan. Apple's apps are driven with AppleScript run through
/// `osascript`, with every value passed as an argument — never pasted into the
/// script, where a quote in a title would break it or worse.
public enum ActionRunner {
    public static func run(_ plan: ActionPlan) async -> ActionOutcome {
        do {
            return try await perform(plan)
        } catch let error as RunError {
            return .failure(error.message, error.detail)
        } catch {
            return .failure("That didn't work.", "\(error)")
        }
    }

    // MARK: - Each action

    private static func perform(_ plan: ActionPlan) async throws -> ActionOutcome {
        switch plan {
        case .createNote(let location, let title, let html):
            _ = try await appleScript(Scripts.createNote, app: "Notes",
                                      [location.account, location.folders.joined(separator: "/"), html])
            return .success("Created “\(title)”", "in \(location.description)")

        case .appendToNote(let location, let name, let entryHTML, let titleHTML, let createIfMissing, let guards):
            let reply = try await appleScript(Scripts.appendToNote, app: "Notes", [
                location.account, location.folders.joined(separator: "/"), name, entryHTML,
                createIfMissing ? "1" : "0", String(guards.maxCharacters),
                guards.refuseInlineImages ? "1" : "0", titleHTML,
            ])
            if reply.hasPrefix("GUARD:size:") {
                let size = reply.dropFirst("GUARD:size:".count)
                return .failure("Didn't add to “\(name)”: it's too big to rewrite safely",
                                "\(size) characters against a limit of \(guards.maxCharacters). Raise guards.maxBodyBytes to allow it.")
            }
            if reply == "GUARD:image" {
                return .failure("Didn't add to “\(name)”: it has an inline image",
                                "Appending would turn the image into an attachment. Set guards.refuseInlineImages to false to allow it.")
            }
            return .success(reply == "created" ? "Started “\(name)”" : "Added to “\(name)”",
                            "in \(location.description)")

        case .createReminder(let title, let notes, let due, let list):
            if EventKitService.isAvailable {
                let created = try await eventKit {
                    try await EventKitService.shared.createReminder(title: title, notes: notes, due: due, list: list)
                }
                var detail = "in \(created.listTitle)"
                if let due { detail += ", due \(displayed(due))" }
                if created.usedDefault { detail += " — there is no list called “\(list)”" }
                return .success("Reminder: \(title)", detail)
            }
            let reply = try await appleScript(Scripts.createReminder, app: "Reminders",
                                              [list, title, notes, due.map(stamp) ?? ""])
            let listUsed = reply.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            var detail = "in \(listUsed)"
            if let due { detail += ", due \(displayed(due))" }
            if reply.hasPrefix("DEFAULTLIST:") { detail += " — there is no list called “\(list)”" }
            return .success("Reminder: \(title)", detail)

        case .createEvent(let title, let start, let duration, let alert, let calendarID, let calendarName, let notes, let show):
            if EventKitService.isAvailable {
                let created = try await eventKit {
                    try await EventKitService.shared.createEvent(
                        title: title, start: start, duration: duration, alertMinutes: alert,
                        calendarID: calendarID, calendarName: calendarName, notes: notes)
                }
                if show { await showInCalendar(created.identifier) }
                var detail = "\(displayed(start)) in \(created.calendarTitle)"
                if let alert { detail += ", alert \(alert) min before" }
                if let note = created.note { detail += ". " + note }
                return .success("Event: \(title)", detail)
            }
            let reply = try await appleScript(Scripts.createEvent, app: "Calendar", [
                calendarID, calendarName, title, stamp(start), String(Int(duration / 60)),
                String(alert ?? -1), notes, show ? "1" : "0",
            ])
            let calendarUsed = reply.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            var detail = "\(displayed(start)) in \(calendarUsed)"
            if let alert { detail += ", alert \(alert) min before" }
            return .success("Event: \(title)", detail)

        case .composeMessage(let to, let body):
            // Opens the conversation with the text in place. Nothing is sent.
            var text = "sms:" + to
            if !body.isEmpty {
                text += "&body=" + (body.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
            }
            guard let url = URL(string: text) else { throw RunError("Couldn't make a Messages link for \(to)") }
            try await openURL(url)
            return .success("Message to \(to) ready", "Nothing is sent until you press Return.")

        case .composeMail(let to, let subject, let body):
            _ = try await appleScript(Scripts.composeMail, app: "Mail", [to, subject, body])
            return .success(to.isEmpty ? "New email ready" : "Email to \(to) ready",
                            "Nothing is sent until you send it.")

        case .openApp(let name, let bundleID, let open):
            return try await openApp(name: name, bundleID: bundleID, open: open)

        case .runShortcut(let name, let input):
            var arguments = ["run", name]
            var inputFile: URL?
            if !input.isEmpty {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("keybow-\(UUID().uuidString).txt")
                try input.write(to: file, atomically: true, encoding: .utf8)
                arguments += ["--input-path", file.path]
                inputFile = file
            }
            defer { inputFile.map { try? FileManager.default.removeItem(at: $0) } }
            let result = try await execute("/usr/bin/shortcuts", arguments)
            guard result.status == 0 else {
                let reason = result.error.isEmpty ? "exit status \(result.status)" : result.error
                throw RunError("Shortcut “\(name)” didn't run", reason)
            }
            return .success("Ran “\(name)”")
        }
    }

    private static func openApp(name: String, bundleID: String, open: String) async throws -> ActionOutcome {
        var appURL: URL?
        if !bundleID.isEmpty {
            appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
        if appURL == nil, !name.isEmpty {
            appURL = AppLocator.installedPath(name)
        }
        let label = name.isEmpty ? bundleID : name
        guard let appURL else { throw RunError("\(label) isn't installed", "Looked for it by bundle ID and in /Applications.") }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if open.isEmpty {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return .success("Opened \(label)")
        }

        let target: URL
        if open.contains("://") {
            guard let url = URL(string: open) else { throw RunError("“\(open)” isn't a valid link") }
            target = url
        } else {
            guard FileManager.default.fileExists(atPath: open) else {
                throw RunError("\(label): nothing at \(open)", "Check the path in the config's projects.")
            }
            target = URL(fileURLWithPath: open)
        }
        _ = try await NSWorkspace.shared.open([target], withApplicationAt: appURL, configuration: configuration)
        return .success("Opened \(target.isFileURL ? target.lastPathComponent : open) in \(label)")
    }

    // MARK: - Plumbing

    /// Runs an EventKit call, turning its errors into ones worth showing.
    private static func eventKit<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as EventKitService.AccessError {
            throw RunError(error.message, error.detail)
        } catch {
            throw RunError("Couldn't save it", error.localizedDescription)
        }
    }

    /// Opens the event in Calendar with its details showing, ready to edit —
    /// the same link Calendar builds for itself. No scripting needed.
    @MainActor
    private static func showInCalendar(_ identifier: String) async {
        guard !identifier.isEmpty,
              let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") else { return }
        try? await openURL(url)
    }

    struct RunError: Error {
        let message: String
        let detail: String?

        init(_ message: String, _ detail: String? = nil) {
            self.message = message
            self.detail = detail
        }
    }

    /// Runs a script with `osascript`, passing each value as an argument to
    /// `on run argv`. Returns what the script returned.
    private static func appleScript(_ source: String, app: String, _ arguments: [String]) async throws -> String {
        let result = try await execute("/usr/bin/osascript", ["-"] + arguments, input: source)
        if result.timedOut {
            throw RunError("\(app) didn't respond",
                           "If macOS is asking whether to allow control of \(app), allow it and try again.")
        }
        guard result.status == 0 else { throw explain(result.error, app: app) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Turns osascript's error text into something a person can act on.
    private static func explain(_ error: String, app: String) -> RunError {
        if error.contains("-1743") {
            return RunError("Not allowed to control \(app)",
                            "Allow it in System Settings → Privacy & Security → Automation.")
        }
        if error.contains("-1728"), app == "Notes" {
            return RunError("Notes couldn't find that account or folder", error)
        }
        for (marker, message) in [("NONOTE:", "There's no note called"), ("NOFOLDER:", "There's no folder called")] {
            if let range = error.range(of: marker) {
                let name = error[range.upperBound...].prefix { $0 != "\"" && $0 != "(" }
                    .trimmingCharacters(in: .whitespaces)
                return RunError("\(message) “\(name)”")
            }
        }
        if error.contains("LOCKED") {
            return RunError("That note is locked", "Unlock it in Notes first.")
        }
        let text = error.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return RunError("\(app) reported a problem", text)
    }

    private struct ProcessResult {
        let status: Int32
        let output: String
        let error: String
        let timedOut: Bool
    }

    /// Set from a timer thread, read in the termination handler.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Long enough for a slow app to launch and act; a first-use permission
    /// prompt waiting for an answer is the usual reason to hit it.
    static let timeout: TimeInterval = 45

    private static func execute(_ path: String, _ arguments: [String], input: String? = nil) async throws -> ProcessResult {
        let timedOut = Flag()
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let output = Pipe()
            let errors = Pipe()
            let stdin = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = stdin

            process.terminationHandler = { finished in
                let out = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: ProcessResult(status: finished.terminationStatus, output: out,
                                                             error: err, timedOut: timedOut.isSet))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: RunError("Couldn't start \(path)", "\(error)"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
            }
            if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
            try? stdin.fileHandleForWriting.close()
        }
    }

    @MainActor
    private static func openURL(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open(url, configuration: configuration)
    }

    /// "2026 9 27 9 0": the local date, for scripts to rebuild without any
    /// locale-dependent date parsing.
    private static func stamp(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return [parts.year, parts.month, parts.day, parts.hour, parts.minute]
            .map { String($0 ?? 0) }.joined(separator: " ")
    }

    private static func displayed(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM, HH:mm"
        return formatter.string(from: date)
    }
}

/// The scripts. Each takes its values from `argv`, and fetches properties into
/// variables before using them: compound expressions like "name of container
/// of x" are evaluated by the app and can fail (see spikes/FINDINGS.md).
private enum Scripts {
    /// Finds or creates a nested folder path like "Work/Notes/Standup".
    private static let resolveFolder = """
    on resolveFolder(theAccount, folderPath, createMissing)
        tell application "Notes"
            if folderPath is "" then return default folder of theAccount
            set AppleScript's text item delimiters to "/"
            set parts to text items of folderPath
            set AppleScript's text item delimiters to ""
            set destination to theAccount
            repeat with part in parts
                set folderName to contents of part
                if folderName is not "" then
                    set existing to (folders of destination whose name is folderName)
                    if (count of existing) > 0 then
                        set destination to item 1 of existing
                    else if createMissing then
                        set destination to make new folder at destination with properties {name:folderName}
                    else
                        error "NOFOLDER:" & folderName
                    end if
                end if
            end repeat
            return destination
        end tell
    end resolveFolder

    on accountNamed(accountName)
        tell application "Notes"
            if accountName is "" then return default account
            return account accountName
        end tell
    end accountNamed
    """

    static let createNote = """
    on run argv
        set accountName to item 1 of argv
        set folderPath to item 2 of argv
        set bodyHTML to item 3 of argv
        set theAccount to my accountNamed(accountName)
        set destination to my resolveFolder(theAccount, folderPath, true)
        tell application "Notes"
            set newNote to make new note at destination with properties {body:bodyHTML}
            show newNote
            activate
            set noteID to id of newNote
        end tell
        return noteID
    end run

    """ + resolveFolder

    static let appendToNote = """
    on run argv
        set accountName to item 1 of argv
        set folderPath to item 2 of argv
        set noteName to item 3 of argv
        set entryHTML to item 4 of argv
        set createIfMissing to (item 5 of argv) is "1"
        set maxCharacters to (item 6 of argv) as integer
        set refuseImages to (item 7 of argv) is "1"
        set titleHTML to item 8 of argv

        set theAccount to my accountNamed(accountName)
        set destination to my resolveFolder(theAccount, folderPath, createIfMissing)
        tell application "Notes"
            set matches to (notes of destination whose name is noteName)
            if (count of matches) is 0 then
                if not createIfMissing then error "NONOTE:" & noteName
                set theNote to make new note at destination with properties {body:titleHTML & entryHTML}
                show theNote
                activate
                return "created"
            end if
            set theNote to item 1 of matches
            set isLocked to password protected of theNote
            if isLocked then error "LOCKED"
            set currentBody to body of theNote
            set bodyLength to length of currentBody
            if bodyLength > maxCharacters then return "GUARD:size:" & bodyLength
            if refuseImages and (currentBody contains "data:image") then return "GUARD:image"
            set body of theNote to currentBody & entryHTML
            show theNote
            activate
        end tell
        return "appended"
    end run

    """ + resolveFolder

    private static let dateFrom = """
    on dateFrom(stamp)
        set AppleScript's text item delimiters to " "
        set parts to text items of stamp
        set AppleScript's text item delimiters to ""
        set theDate to current date
        -- Day first, so a short month can't overflow while the others are set.
        set day of theDate to 1
        set year of theDate to (item 1 of parts) as integer
        set month of theDate to (item 2 of parts) as integer
        set day of theDate to (item 3 of parts) as integer
        set time of theDate to ((item 4 of parts) as integer) * hours + ((item 5 of parts) as integer) * minutes
        return theDate
    end dateFrom
    """

    static let createReminder = """
    on run argv
        set listName to item 1 of argv
        set theTitle to item 2 of argv
        set theNotes to item 3 of argv
        set dueStamp to item 4 of argv
        set usedDefault to false
        tell application "Reminders"
            if listName is "" then
                set theList to default list
            else
                set found to (lists whose name is listName)
                if (count of found) > 0 then
                    set theList to item 1 of found
                else
                    set theList to default list
                    set usedDefault to true
                end if
            end if
            tell theList to set newReminder to make new reminder with properties {name:theTitle}
            if theNotes is not "" then set body of newReminder to theNotes
            if dueStamp is not "" then
                set dueDate to my dateFrom(dueStamp)
                set due date of newReminder to dueDate
                set remind me date of newReminder to dueDate
            end if
            set listUsed to name of theList
        end tell
        if usedDefault then return "DEFAULTLIST:" & listUsed
        return "OK:" & listUsed
    end run

    """ + dateFrom

    static let createEvent = """
    on run argv
        set calendarID to item 1 of argv
        set calendarName to item 2 of argv
        set theTitle to item 3 of argv
        set startDate to my dateFrom(item 4 of argv)
        set durationMinutes to (item 5 of argv) as integer
        set alertMinutes to (item 6 of argv) as integer
        set theNotes to item 7 of argv
        set showIt to (item 8 of argv) is "1"
        set endDate to startDate + durationMinutes * minutes
        tell application "Calendar"
            if calendarID is not "" then
                set theCalendar to first calendar whose calendarIdentifier is calendarID
            else if calendarName is not "" then
                set theCalendar to first calendar whose name is calendarName
            else
                set theCalendar to first calendar whose writable is true
            end if
            set calendarUsed to name of theCalendar
            tell theCalendar
                set newEvent to make new event at end of events with properties {summary:theTitle, start date:startDate, end date:endDate, description:theNotes}
            end tell
            if alertMinutes ≥ 0 then
                tell newEvent to make new display alarm at end of display alarms with properties {trigger interval:(0 - alertMinutes)}
            end if
            if showIt then
                show newEvent
                activate
            end if
        end tell
        return "OK:" & calendarUsed
    end run

    """ + dateFrom

    static let composeMail = """
    on run argv
        set toAddress to item 1 of argv
        set theSubject to item 2 of argv
        set theBody to item 3 of argv
        tell application "Mail"
            set newMessage to make new outgoing message with properties {visible:true, subject:theSubject, content:theBody}
            if toAddress is not "" then
                tell newMessage to make new to recipient at end of to recipients with properties {address:toAddress}
            end if
            activate
        end tell
        return "OK"
    end run
    """
}
