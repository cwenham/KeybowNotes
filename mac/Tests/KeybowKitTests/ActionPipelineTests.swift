@testable import KeybowKit
import XCTest

/// What the overlay was asked to show, in order.
@MainActor
private final class FakeOverlay: ActionShowing {
    var shown: [String] = []

    func showPreview(_ summary: ActionSummary, path: String) { shown.append("preview: \(summary.verb)") }
    func showRefused(_ reason: String, summary: ActionSummary) { shown.append("refused: \(reason)") }
    func showWorking(_ summary: ActionSummary, path: String, title: String, cancel: @escaping () -> Void) {
        shown.append("working: \(title)")
    }
    func updateWorking(title: String) { shown.append("working: \(title)") }
    func endWorking() { shown.append("done working") }
    func showCancelled() { shown.append("cancelled") }
    func showRunning(_ summary: ActionSummary, path: String) { shown.append("running") }
    func showFinished(_ outcome: ActionOutcome, summary: ActionSummary, warnings: [String]) {
        shown.append("finished: \(outcome.message)")
    }
    func stepAside() { shown.append("aside") }
}

/// The Mac, as the pipeline sees it: nothing really runs or is typed.
@MainActor
private final class FakeMac {
    var front: pid_t = 100
    var selection: SelectionReading = .text("the selected words")
    var mayInsert = true
    var askedForAccess = 0
    var clipboard: [String] = []
    var outcomes: [ActionOutcome] = []
    var ran: [ActionPlan] = []
    var onRun: (() -> Void)?
    var logged: [String] = []

    var surroundings: ActionPipeline.Surroundings {
        ActionPipeline.Surroundings(
            values: { ["clipboard": "copied earlier", "frontApp": "TextEdit"] },
            clipboardMedia: { nil },
            frontmostApp: { [unowned self] in front },
            readSelection: { [unowned self] in selection },
            mayInsertText: { [unowned self] in mayInsert },
            askForAccessibility: { [unowned self] in askedForAccess += 1 },
            putOnClipboard: { [unowned self] in clipboard.append($0) },
            bringPromptsForward: { _ in },
            run: { [unowned self] plan in
                ran.append(plan)
                defer { onRun?() }
                return outcomes.isEmpty ? .success("Done") : outcomes.removeFirst()
            },
            log: { [unowned self] in logged.append($0) },
            logError: { [unowned self] in logged.append("ERROR" + $0) })
    }
}

/// Fetches `{{slow.…}}` values, taking its time.
private final class Slow: KeybowModule, @unchecked Sendable {
    let manifest = ModuleManifest(id: "slow", name: "Slow", fetches: ["slow"])
    var delay: Duration = .milliseconds(50)
    func start(host: ModuleHost) {}
    func summary(of request: ModuleRequest, now: Date) -> ModuleSummary { ModuleSummary(verb: "", subject: "") }
    func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome { .quiet }
    func fetch(_ names: [String], params: [String: String], now: Date) async throws -> [String: String] {
        try await Task.sleep(for: delay)
        return Dictionary(uniqueKeysWithValues: names.map { ($0, "fetched") })
    }
}

/// A module type with an OK of its own, like Display's.
private final class Showcase: KeybowModule, @unchecked Sendable {
    let manifest = ModuleManifest(id: "showcase", name: "Showcase", actionTypes: [
        ModuleActionType(type: "showcase", title: "Showcase", keywords: ["Showcase"], symbol: "eye", fields: [
            ModuleField(key: "ok", title: "On OK", kind: .action),
        ], takesText: true),
    ])
    func start(host: ModuleHost) {}
    func summary(of request: ModuleRequest, now: Date) -> ModuleSummary { ModuleSummary(verb: "Show", subject: "") }
    func run(_ request: ModuleRequest, now: Date) async -> ActionOutcome { .quiet }
}

/// From a key's press to its action — and what's shown, logged and refused
/// on the way.
@MainActor
final class ActionPipelineTests: XCTestCase {
    private var overlay: FakeOverlay!
    private var mac: FakeMac!
    private var registry: ModuleRegistry!
    private var slow: Slow!
    private var settings = ActionPipeline.Settings()
    private var pipeline: ActionPipeline!

    override func setUp() async throws {
        overlay = FakeOverlay()
        mac = FakeMac()
        registry = ModuleRegistry()
        slow = Slow()
        registry.register(slow, host: MemoryModuleHost())
        settings = ActionPipeline.Settings()
        pipeline = ActionPipeline(display: overlay, surroundings: mac.surroundings, registry: registry,
                                  config: { ConfigStoreStandIn.config }, settings: { [unowned self] in settings })
    }

    /// The first key of a one-line tree, ready to fire.
    private func selection(_ line: String) throws -> ResolvedSelection {
        let compiled = OutlineCompiler.compile(OutlineParser.parse("1. " + line).0, locateApp: { _ in nil })
        let config = try XCTUnwrap(compiled.config, compiled.configError ?? "")
        ConfigStoreStandIn.config = config
        return try XCTUnwrap(config.resolve(path: [0]))
    }

    /// Fires, and waits to hear how it went.
    @discardableResult
    private func fire(_ line: String) async throws -> ActionOutcome {
        let selection = try selection(line)
        let heard = expectation(description: "reported")
        var outcome: ActionOutcome?
        pipeline.fire(selection) { outcome = $0; heard.fulfill() }
        await fulfillment(of: [heard], timeout: 5)
        // The overlay hears after the report.
        try await Task.sleep(for: .milliseconds(20))
        return try XCTUnwrap(outcome)
    }

    func testAnActionRunsAndSaysSo() async throws {
        let outcome = try await fire("Coffee [Maps, query: coffee]")
        XCTAssertEqual(outcome, .success("Done"))
        XCTAssertEqual(mac.ran.count, 1)
        guard case .searchMaps(let query)? = mac.ran.first else { return XCTFail("\(mac.ran)") }
        XCTAssertEqual(query, "coffee")
        XCTAssertEqual(overlay.shown, ["running", "finished: Done"])
        XCTAssertTrue(mac.logged.last?.hasSuffix(": Done") == true, "\(mac.logged)")
    }

    func testWhatsCopiedOrSelectedStaysOutOfTheLog() async throws {
        try await fire("Snippet [Copy, text: secret words]")
        guard case .copyToClipboard(let text, _)? = mac.ran.first else { return XCTFail("\(mac.ran)") }
        XCTAssertEqual(text, "secret words")
        XCTAssertTrue(mac.logged.last?.hasSuffix("(details not logged)") == true)

        mac.outcomes = [.failure("It broke", "the selected words were…")]
        try await fire("Look up [Maps, query: \"{{selection}}\"]")
        guard case .searchMaps(let query)? = mac.ran.last else { return XCTFail("\(mac.ran)") }
        XCTAssertEqual(query, "the selected words", "read, since it's used")
        XCTAssertFalse(mac.logged.joined().contains("selected words"), "\(mac.logged)")
        XCTAssertTrue(mac.logged.last?.hasPrefix("ERROR") == true)
    }

    func testADryRunDoesNothing() async throws {
        settings.dryRun = true
        let outcome = try await fire("Coffee [Maps, query: coffee]")
        XCTAssertEqual(outcome.message, "Dry run: nothing done")
        XCTAssertEqual(mac.ran.count, 0)
        XCTAssertEqual(overlay.shown, ["preview: Search Maps"])
    }

    func testAccessibilityIsAskedForWhenNeeded() async throws {
        mac.mayInsert = false
        let outcome = try await fire("Sign-off [Insert, text: Thanks]")
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(mac.ran.count, 0)
        XCTAssertEqual(mac.askedForAccess, 1)
        XCTAssertTrue(overlay.shown.first?.hasPrefix("refused: KeybowNotes needs Accessibility access to type") == true)

        mac.selection = .notAllowed
        try await fire("Look up [Maps, query: \"{{selection}}\"]")
        XCTAssertEqual(mac.ran.count, 0)
        XCTAssertEqual(mac.askedForAccess, 2)
        XCTAssertTrue(overlay.shown.last?.contains("read the selected text") == true)
    }

    func testFetchedValuesAreWaitedFor() async throws {
        try await fire("Weather [Maps, query: \"{{slow.place}}\"]")
        guard case .searchMaps(let query)? = mac.ran.first else { return XCTFail("\(mac.ran)") }
        XCTAssertEqual(query, "fetched")
        XCTAssertFalse(pipeline.isWaiting)
        XCTAssertTrue(mac.logged.contains { $0.hasPrefix("  fetched 1 value in") }, "\(mac.logged)")
    }

    func testTextIsntTypedIntoAnotherApp() async throws {
        let selection = try selection("Weather [Insert, text: \"{{slow.now}}\"]")
        let heard = expectation(description: "reported")
        pipeline.fire(selection) { _ in heard.fulfill() }
        mac.front = 200     // switched apps while it fetched
        await fulfillment(of: [heard], timeout: 5)
        XCTAssertEqual(mac.ran.count, 0)
        XCTAssertEqual(mac.clipboard, ["fetched"], "on the clipboard instead")
        XCTAssertTrue(overlay.shown.last?.hasPrefix("refused: You switched apps") == true, "\(overlay.shown)")
    }

    func testOneWaitAtATime() async throws {
        slow.delay = .milliseconds(300)
        let first = try selection("Weather [Maps, query: \"{{slow.place}}\"]")
        let done = expectation(description: "first done")
        pipeline.fire(first) { _ in done.fulfill() }
        XCTAssertTrue(pipeline.isWaiting)
        let second = try await fire("Weather [Maps, query: \"{{slow.place}}\"]")
        XCTAssertTrue(second.message.hasPrefix("Still waiting"))
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(mac.ran.count, 1)
        XCTAssertFalse(pipeline.isWaiting)
    }

    func testCancellingTheWait() async throws {
        slow.delay = .seconds(10)
        let selection = try selection("Weather [Maps, query: \"{{slow.place}}\"]")
        let heard = expectation(description: "reported")
        var outcome: ActionOutcome?
        pipeline.fire(selection) { outcome = $0; heard.fulfill() }
        pipeline.cancel()
        await fulfillment(of: [heard], timeout: 5)
        XCTAssertEqual(outcome?.succeeded, false)
        XCTAssertEqual(mac.ran.count, 0)
        XCTAssertTrue(overlay.shown.contains("cancelled"), "\(overlay.shown)")
        XCTAssertFalse(pipeline.isWaiting)
    }

    func testAnOutcomeRunsTheNextAction() async throws {
        ModuleRegistry.shared.register(Showcase(), host: MemoryModuleHost())
        let line = "Idea [Showcase, text: Hi, ok: Copy, ok.text: \"{{displayed}}!\"]"
        mac.outcomes = [.then("ok", values: ["displayed": "Hi"])]
        let both = expectation(description: "ran both")
        mac.onRun = { [unowned self] in if mac.ran.count == 2 { both.fulfill() } }
        try await fire(line)
        await fulfillment(of: [both], timeout: 5)
        guard case .copyToClipboard(let text, _) = mac.ran[1] else { return XCTFail("\(mac.ran)") }
        XCTAssertEqual(text, "Hi!", "with what the first one said")
        XCTAssertTrue(mac.logged.contains("  then ok: clipboard.copy"), "\(mac.logged)")
    }
}

/// The config the last selection came from, for the pipeline to describe it by.
@MainActor
private enum ConfigStoreStandIn {
    static var config = try! KeybowConfig.parse(Data(#"{ "trees": {} }"#.utf8))
}
