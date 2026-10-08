@testable import KeybowKit
import XCTest

/// Helper programs, run to the end — however much they say.
final class SubprocessTests: XCTestCase {
    func testOutputAndErrorsAreReadInFull() throws {
        // More than a pipe holds, each way: written and read at once, or it stalls.
        let input = String(repeating: "keybow\n", count: 50_000)
        let echoed = try Subprocess.runAndWait("/bin/cat", [], input: input, timeout: 20)
        XCTAssertEqual(echoed.output.count, input.utf8.count)
        XCTAssertTrue(echoed.succeeded)

        let chatty = try Subprocess.runAndWait("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\\\0' e >&2; echo done"],
                                        timeout: 20)
        XCTAssertEqual(chatty.errors.count, 300_000)
        XCTAssertEqual(chatty.text, "done\n")
        XCTAssertFalse(chatty.timedOut)
    }

    func testATimeoutStopsIt() throws {
        let started = Date()
        let result = try Subprocess.runAndWait("/bin/sleep", ["30"], timeout: 0.3)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testFailingAndMissingPrograms() async throws {
        let failed = try await Subprocess.run("/bin/sh", ["-c", "echo nope >&2; exit 3"])
        XCTAssertEqual(failed.status, 3)
        XCTAssertEqual(failed.errorText, "nope\n")
        XCTAssertFalse(failed.succeeded)
        XCTAssertThrowsError(try Subprocess.runAndWait("/nowhere/at/all", []))
    }

    func testWhatOsascriptSays() {
        XCTAssertEqual(Osascript.reason("12:40: execution error: Notes got an error: Can’t get folder \"X\". (-1728)\n"),
                       "Can’t get folder \"X\".")
        XCTAssertEqual(Osascript.reason("execution error: The variable x is not defined. (-2753)"),
                       "The variable x is not defined.")
        XCTAssertTrue(Osascript.isNotAllowed("execution error: Not authorized to send Apple events to Notes. (-1743)"))
        XCTAssertFalse(Osascript.isNotAllowed("execution error: Notes got an error: Can’t get folder \"X\". (-1728)"))
    }
}
