import AppKit
import KeybowKit

// AppleScript's commands, as Packaging/KeybowNotes.sdef names them: each hands
// its arguments to `Automation`, and answers with what it said — or with its
// refusal, as the script's error.

/// A command answered asynchronously: the script waits while it runs.
class AutomationCommand: NSScriptCommand {
    func text(_ key: String) -> String? {
        (evaluatedArguments?[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    var direct: String? {
        (directParameter as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// Runs `work` on the main thread, and answers the script with its result.
    func answer(_ work: @escaping @MainActor (Automation) async throws -> Any) -> Any? {
        suspendExecution()
        Task { @MainActor in
            do {
                guard let automation = Automation.shared else { throw Automation.Problem("KeybowNotes is still starting.") }
                resumeExecution(withResult: try await work(automation))
            } catch {
                scriptErrorNumber = 1
                scriptErrorString = "\(error)"
                resumeExecution(withResult: nil)
            }
        }
        return nil
    }

    func required(_ value: String?, _ what: String) throws -> String {
        guard let value else { throw Automation.Problem("Say \(what).") }
        return value
    }
}

@objc(KBTriggerCommand)
final class TriggerCommand: AutomationCommand {
    override func performDefaultImplementation() -> Any? {
        answer { [self] automation in
            let outcome = try await automation.trigger(try required(direct, "which entry to run"), tree: text("tree"),
                                                       keypad: text("keypad"))
            let said = outcome.message + (outcome.detail.map { " — \($0)" } ?? "")
            guard outcome.succeeded else { throw Automation.Problem(said) }
            return said.isEmpty ? "Done" : said
        }
    }
}

@objc(KBAddEntryCommand)
final class AddEntryCommand: AutomationCommand {
    override func performDefaultImplementation() -> Any? {
        answer { [self] automation in
            try automation.add(try required(direct, "the entry to add"), under: text("under"), tree: text("tree"),
                               keypad: text("keypad"))
        }
    }
}

@objc(KBRemoveEntryCommand)
final class RemoveEntryCommand: AutomationCommand {
    override func performDefaultImplementation() -> Any? {
        answer { [self] automation in
            try automation.remove(try required(direct, "which entry to remove"), tree: text("tree"), keypad: text("keypad"))
        }
    }
}

@objc(KBChangeEntryCommand)
final class ChangeEntryCommand: AutomationCommand {
    override func performDefaultImplementation() -> Any? {
        answer { [self] automation in
            try automation.change(try required(direct, "which entry to change"), to: try required(text("to"), "what to change it to"),
                                  tree: text("tree"), keypad: text("keypad"))
        }
    }
}

@objc(KBTreeOutlineCommand)
final class TreeOutlineCommand: AutomationCommand {
    override func performDefaultImplementation() -> Any? {
        answer { [self] automation in try automation.outline(tree: text("tree"), keypad: text("keypad")) }
    }
}

@objc(KBTreeEntriesCommand)
final class TreeEntriesCommand: AutomationCommand {
    override func performDefaultImplementation() -> Any? {
        answer { [self] automation in try automation.leaves(tree: text("tree"), keypad: text("keypad")) }
    }
}

@objc(KBReplaceTreeCommand)
final class ReplaceTreeCommand: AutomationCommand {
    override func performDefaultImplementation() -> Any? {
        answer { [self] automation in
            try automation.replace(tree: text("tree"), keypad: text("keypad"),
                                   with: try required(text("outline"), "the tree, with outline"))
        }
    }
}

@objc(KBWholeOutlineCommand)
final class WholeOutlineCommand: AutomationCommand {
    override func performDefaultImplementation() -> Any? {
        answer { automation in try automation.wholeOutline() }
    }
}

@objc(KBCheckOutlineCommand)
final class CheckOutlineCommand: AutomationCommand {
    override func performDefaultImplementation() -> Any? {
        answer { [self] automation in automation.check(try required(direct, "the outline to check")) }
    }
}

@objc(KBKeypadNamesCommand)
final class KeypadNamesCommand: AutomationCommand {
    override func performDefaultImplementation() -> Any? {
        answer { automation in try automation.keypads() }
    }
}

@objc(KBAddKeypadCommand)
final class AddKeypadCommand: AutomationCommand {
    override func performDefaultImplementation() -> Any? {
        answer { [self] automation in
            try automation.addKeypad(named: try required(direct, "the keypad's name"), model: text("model"), id: text("id"))
        }
    }
}

/// start, stop, lap, reset and toggle stopwatch: the command's own name says which.
@objc(KBStopwatchCommand)
final class StopwatchCommand: AutomationCommand {
    override func performDefaultImplementation() -> Any? {
        let codes: [String: String] = ["SwSt": "start", "SwSp": "stop", "SwLp": "lap", "SwRs": "reset", "SwTg": "toggle"]
        let code = commandDescription.appleEventCode
        let id = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? ""
        let command = codes[id] ?? "toggle"
        return answer { automation in try await automation.stopwatch(command) }
    }
}

@objc(KBMusicLibraryCommand)
final class MusicLibraryCommand: AutomationCommand {
    override func performDefaultImplementation() -> Any? {
        answer { [self] automation in
            try await automation.musicLibrary(direct ?? "overview", genre: text("genre"), artist: text("artist"),
                                              album: text("album"), rankedBy: text("rankedBy"),
                                              limit: evaluatedArguments?["limit"] as? Int)
        }
    }
}

@objc(KBStopwatchReadingCommand)
final class StopwatchReadingCommand: AutomationCommand {
    override func performDefaultImplementation() -> Any? {
        answer { automation in automation.stopwatchReading() }
    }
}
