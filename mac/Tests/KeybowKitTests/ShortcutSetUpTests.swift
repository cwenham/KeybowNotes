@testable import KeybowKit
import XCTest

private final class Opened: @unchecked Sendable {
    var count = 0
}

/// A helper shortcut that isn't there yet: how to make it, with Open
/// Shortcuts — nothing is opened, and the clipboard is the host's own.
final class ShortcutSetUpTests: XCTestCase {
    private let page = ActionRunner.timerSetUpPage("KeybowNotes Timer")
    private let steps = ActionRunner.timerSteps("KeybowNotes Timer")

    func testOpenShortcutsCopiesTheNameAndOpensANewOne() async {
        let host = MemoryModuleHost()
        host.displayResult = .ok
        let opened = Opened()
        let outcome = await ShortcutsApp.offerToMake("KeybowNotes Timer", page: page, steps: steps, host: host,
                                                     open: { opened.count += 1; return true })
        XCTAssertEqual(outcome.message, "Copied “KeybowNotes Timer”")
        XCTAssertEqual(outcome.detail, "Paste it as the new shortcut's name")
        XCTAssertEqual(host.copied, ["KeybowNotes Timer"])
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(host.displayed.first?.okTitle, "Open Shortcuts")
        XCTAssertEqual(host.displayed.first?.buttons, [.cancel, .ok])
        XCTAssertEqual(host.displayed.first?.content, .markdown(page))
    }

    func testShortcutsThatWontOpenLeaveTheNameCopied() async {
        let host = MemoryModuleHost()
        host.displayResult = .ok
        let outcome = await ShortcutsApp.offerToMake("KeybowNotes Timer", page: page, steps: steps, host: host,
                                                     open: { false })
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.detail, "“KeybowNotes Timer” is on the clipboard, ready to paste.")
    }

    func testCancelAndNowhereToShowIt() async {
        let host = MemoryModuleHost()
        host.displayResult = .cancel
        let opened = Opened()
        let cancelled = await ShortcutsApp.offerToMake("KeybowNotes Timer", page: page, steps: steps, host: host,
                                                       open: { opened.count += 1; return true })
        XCTAssertTrue(cancelled.isQuiet)
        XCTAssertEqual(host.copied, [])
        XCTAssertEqual(opened.count, 0)

        // The command line shows nothing: the steps are the failure's detail.
        for nowhere in [nil, { () -> ModuleHost in let h = MemoryModuleHost(); h.displayResult = .dismissed; return h }()] {
            let outcome = await ShortcutsApp.offerToMake("KeybowNotes Timer", page: page, steps: steps, host: nowhere,
                                                         open: { opened.count += 1; return true })
            XCTAssertEqual(outcome.message, "Set up the “KeybowNotes Timer” shortcut first")
            XCTAssertEqual(outcome.detail, steps)
        }
        XCTAssertEqual(opened.count, 0)
    }

    func testTheTimersPage() {
        XCTAssertEqual(page, """
            **Set up the “KeybowNotes Timer” shortcut**

            Clock can't be scripted, but Shortcuts can start its timers. Make a new shortcut called **KeybowNotes Timer**, with:

            1. **Start Timer**: click its duration, choose **Shortcut Input**, and set the unit to **seconds**

            Open Shortcuts copies its name, ready to paste. Then press the key again.
            """)
    }
}
