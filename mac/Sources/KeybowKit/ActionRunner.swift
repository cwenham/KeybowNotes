import AppKit
import Foundation

public struct ActionOutcome: Equatable, Sendable {
    public let succeeded: Bool
    /// One line for the overlay: "Created “Standup — 26 Sep 2026”".
    public let message: String
    /// Anything worth knowing beyond that: where it went, what to fix.
    public let detail: String?
    /// Nothing to show: it showed itself — a display that's been dismissed.
    public var isQuiet = false
    /// A nested action of the node's own to run next, as though its key had
    /// been pressed: `ok` when a display's OK is chosen. With `values`, which
    /// its placeholders can use: `{{displayed}}`.
    public var followUp: String?
    public var values: [String: String] = [:]
    /// The text a follow-up that takes text, and is given none, uses:
    /// `{{displayed}}`, `{{answer}}`.
    public var followUpText: String?

    public static func success(_ message: String, _ detail: String? = nil) -> ActionOutcome {
        ActionOutcome(succeeded: true, message: message, detail: detail)
    }

    public static func failure(_ message: String, _ detail: String? = nil) -> ActionOutcome {
        ActionOutcome(succeeded: false, message: message, detail: detail)
    }

    /// Done, with nothing more to say.
    public static var quiet: ActionOutcome {
        ActionOutcome(succeeded: true, message: "", detail: nil, isQuiet: true)
    }

    /// Done; now run the node's `action` — `ok` — with these values, and
    /// `text` for one that takes text and has none.
    public static func then(_ action: String, values: [String: String] = [:], text: String? = nil) -> ActionOutcome {
        ActionOutcome(succeeded: true, message: "", detail: nil, isQuiet: true, followUp: action, values: values,
                      followUpText: text)
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

        case .placeCall(let to, let faceTime):
            // Digits, + and the dialling marks are all a tel: link needs.
            let allowed = CharacterSet(charactersIn: "0123456789+*#,;")
            let number = String(to.unicodeScalars.filter { allowed.contains($0) })
            guard !number.isEmpty else { throw RunError("“\(to)” isn't a phone number") }
            guard let url = URL(string: (faceTime ? "facetime-audio:" : "tel:") + number) else {
                throw RunError("Couldn't make a call link for \(to)")
            }
            try await openURL(url)
            return .success(faceTime ? "FaceTime call to \(to)" : "Calling \(to)",
                            faceTime ? "Confirm on screen to start it."
                                     : "Confirm on screen; the call goes through your iPhone.")

        case .composeMail(let to, let subject, let body):
            _ = try await appleScript(Scripts.composeMail, app: "Mail", [to, subject, body])
            return .success(to.isEmpty ? "New email ready" : "Email to \(to) ready",
                            "Nothing is sent until you send it.")

        case .openApp(let name, let bundleID, let open):
            return try await openApp(name: name, bundleID: bundleID, open: open)

        case .module(let request):
            guard let module = ModuleRegistry.shared.module(handling: request.type) else {
                throw RunError("Nothing here runs “\(request.type)” actions")
            }
            return await module.run(request, now: request.time)

        case .runShortcut(let name, let input):
            try await runShortcut(name, input: input)
            return .success("Ran “\(name)”")

        case .startTimer(let seconds, let shortcut):
            guard await ShortcutsApp.names().contains(shortcut) else {
                throw RunError("Set up the “\(shortcut)” shortcut first",
                               "In Shortcuts, make a shortcut called “\(shortcut)” with one action: Start Timer, "
                               + "its duration set to Shortcut Input, in seconds.")
            }
            try await runShortcut(shortcut, input: String(seconds))
            return .success("Timer: \(DateExpression.describe(seconds: TimeInterval(seconds)))", "Started in Clock")

        case .searchMaps(let query):
            guard let url = URL(string: "maps://?q=" + Template.linkEncoded(query)) else {
                throw RunError("Couldn't make a Maps link for “\(query)”")
            }
            try await openURL(url)
            return .success("Searching Maps for “\(query)”")

        case .playPlaylist(let name, let shuffle):
            _ = try await appleScript(Scripts.playPlaylist, app: "Music",
                                      [name, shuffle.map { $0 ? "on" : "off" } ?? ""])
            return .success("Playing “\(name)”", shuffle == true ? "Shuffled" : nil)

        case .playAlbum(let name, let artist):
            let reply = try await appleScript(Scripts.playAlbum, app: "Music", [name, artist, Scripts.albumQueue])
            let count = reply.split(separator: ":").last.map(String.init) ?? ""
            return .success("Playing “\(name)”", "\(count) tracks, from the “\(Scripts.albumQueue)” playlist")

        case .openLink(let url):
            if url.isFileURL {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw RunError("Nothing at \((url.path as NSString).abbreviatingWithTildeInPath)")
                }
                try await openURL(url)
                return .success("Opened \(url.lastPathComponent)")
            }
            do {
                try await openURL(url)
            } catch {
                throw RunError("Couldn't open the link", "No app opens \(url.scheme ?? "these"): links here.")
            }
            return .success("Opened \(url.host ?? url.scheme ?? "the link")", url.absoluteString)

        case .insertText(let text, let format):
            let app = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName }
            do {
                try await TextInsertion.insert(text, format: format)
            } catch TextInsertion.Failure.notAllowed {
                throw RunError("KeybowNotes needs Accessibility access to type into other apps",
                               "Allow it in System Settings → Privacy & Security → Accessibility.")
            }
            let flat = text.replacingOccurrences(of: "\n", with: " ")
            return .success("Inserted “\(flat.count > 50 ? String(flat.prefix(50)) + "…" : flat)”",
                            app.map { "into \($0)" })

        case .insertTextDirectly(let text, let method):
            let app = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName }
            let used: DirectInsertion.Method
            do {
                used = try await DirectInsertion.insert(text, via: method)
            } catch DirectInsertion.Failure.notAllowed {
                throw RunError("KeybowNotes needs Accessibility access to type into other apps",
                               "Allow it in System Settings → Privacy & Security → Accessibility.")
            } catch DirectInsertion.Failure.refused {
                throw RunError("\(app ?? "The app") didn't take the text through accessibility",
                               "Leave via empty to type it instead.")
            }
            let flat = text.replacingOccurrences(of: "\n", with: " ")
            let how = used == .typing ? "typed" : "directly"
            return .success("Inserted “\(flat.count > 50 ? String(flat.prefix(50)) + "…" : flat)”",
                            app.map { "into \($0), \(how)" } ?? how.capitalized)

        case .copyToClipboard(let text, let format):
            await copy(text, format: format)
            let flat = text.replacingOccurrences(of: "\n", with: " ")
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            return .success("Copied “\(flat.count > 50 ? String(flat.prefix(50)) + "…" : flat)”",
                            lines > 1 ? "\(lines) lines, ready to paste" : "Ready to paste")
        }
    }

    @MainActor
    private static func copy(_ text: String, format: TextFormat) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        PasteboardText(text, format: format).write(to: item)
        pasteboard.writeObjects([item])
    }

    /// Runs a shortcut, handing it text as a file: the command line takes no
    /// other kind of input.
    private static func runShortcut(_ name: String, input: String) async throws {
        var arguments = ["run", name]
        var inputFile: URL?
        if !input.isEmpty {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("keybow-\(UUID().uuidString).txt")
            try input.write(to: file, atomically: true, encoding: .utf8)
            arguments += ["--input-path", file.path]
            inputFile = file
        }
        defer { inputFile.map { try? FileManager.default.removeItem(at: $0) } }
        let result: Subprocess.Result
        do {
            result = try await Subprocess.run(ShortcutsApp.path, arguments, timeout: timeout)
        } catch {
            throw RunError("Couldn't start \(ShortcutsApp.path)", "\(error)")
        }
        guard result.succeeded else {
            let said = result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = result.timedOut ? "It took longer than \(Int(timeout)) seconds."
                : said.isEmpty ? "exit status \(result.status)" : said
            throw RunError("Shortcut “\(name)” didn't run", reason)
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
        let result: Subprocess.Result
        do {
            result = try await Osascript.run(source, arguments, timeout: timeout)
        } catch {
            throw RunError("Couldn't start osascript", "\(error)")
        }
        if result.timedOut {
            throw RunError("\(app) didn't respond",
                           "If macOS is asking whether to allow control of \(app), allow it and try again.")
        }
        guard result.status == 0 else { throw explain(result.errorText, app: app) }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Turns osascript's error text into something a person can act on.
    private static func explain(_ error: String, app: String) -> RunError {
        if Osascript.isNotAllowed(error) {
            return RunError("Not allowed to control \(app)", Osascript.allowIt)
        }
        if error.contains("-1728"), app == "Notes" {
            return RunError("Notes couldn't find that account or folder", Osascript.reason(error))
        }
        for (marker, message) in [("NONOTE:", "There's no note called"), ("NOFOLDER:", "There's no folder called"),
                                  ("NOPLAYLIST:", "There's no playlist called"),
                                  ("NOALBUM:", "There's no album in your library called")] {
            if let range = error.range(of: marker) {
                let name = error[range.upperBound...].prefix { $0 != "\"" && $0 != "(" }
                    .trimmingCharacters(in: .whitespaces)
                return RunError("\(message) “\(name)”")
            }
        }
        if error.contains("LOCKED") {
            return RunError("That note is locked", "Unlock it in Notes first.")
        }
        return RunError("\(app) reported a problem", Osascript.reason(error).replacingOccurrences(of: "\n", with: " "))
    }

    /// Long enough for a slow app to launch and act; a first-use permission
    /// prompt waiting for an answer is the usual reason to hit it.
    static let timeout: TimeInterval = 45

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

    static let playPlaylist = """
    on run argv
        set playlistName to item 1 of argv
        set shuffleSetting to item 2 of argv
        tell application "Music"
            set found to (every playlist whose name is playlistName)
            if (count of found) is 0 then error "NOPLAYLIST:" & playlistName
            set thePlaylist to item 1 of found
            if shuffleSetting is "on" then set shuffle enabled to true
            if shuffleSetting is "off" then set shuffle enabled to false
            play thePlaylist
        end tell
        return "OK"
    end run
    """

    /// The playlist an album is played from. Music can only play a playlist in
    /// order, so the album's tracks are put in one of KeybowNotes' own, made
    /// afresh each time. Deleting a playlist never deletes its songs.
    static let albumQueue = "KeybowNotes Album"

    static let playAlbum = """
    on run argv
        set albumName to item 1 of argv
        set artistName to item 2 of argv
        set queueName to item 3 of argv
        tell application "Music"
            set albumTracks to (every track of library playlist 1 whose album is albumName)
            if artistName is not "" then
                set kept to {}
                repeat with candidate in albumTracks
                    set trackArtist to artist of candidate
                    set trackAlbumArtist to album artist of candidate
                    if trackArtist is artistName or trackAlbumArtist is artistName then set end of kept to contents of candidate
                end repeat
                set albumTracks to kept
            end if
            if (count of albumTracks) is 0 then error "NOALBUM:" & albumName
            set keyed to {}
            repeat with candidate in albumTracks
                set discNumber to disc number of candidate
                set trackNumber to track number of candidate
                set end of keyed to {discNumber * 1000 + trackNumber, contents of candidate}
            end repeat
        end tell
        set ordered to my sortByKey(keyed)
        tell application "Music"
            set oldQueues to (every user playlist whose name is queueName)
            repeat with oldQueue in oldQueues
                delete oldQueue
            end repeat
            set albumQueue to make new user playlist with properties {name:queueName}
            repeat with pair in ordered
                duplicate (item 2 of pair) to albumQueue
            end repeat
            set shuffle enabled to false
            play albumQueue
        end tell
        return "OK:" & (count of ordered)
    end run

    -- Disc and track order: an insertion sort on each pair's first item.
    on sortByKey(pairs)
        set sorted to {}
        repeat with pair in pairs
            set thePair to contents of pair
            set slot to (count of sorted) + 1
            repeat with i from 1 to count of sorted
                if item 1 of (item i of sorted) > item 1 of thePair then
                    set slot to i
                    exit repeat
                end if
            end repeat
            if slot is 1 then
                set sorted to {thePair} & sorted
            else if slot > (count of sorted) then
                set end of sorted to thePair
            else
                set sorted to (items 1 thru (slot - 1) of sorted) & {thePair} & (items slot thru -1 of sorted)
            end if
        end repeat
        return sorted
    end sortByKey
    """

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
