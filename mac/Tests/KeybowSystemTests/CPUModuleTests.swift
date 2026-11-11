@testable import KeybowKit
@testable import KeybowSystem
import XCTest

private final class FakeCPU: CPUSampler, @unchecked Sendable {
    var next: [CPUTicks]
    init(_ ticks: [CPUTicks]) { next = ticks }
    func ticks() -> CPUTicks? { next.isEmpty ? nil : next.removeFirst() }
}

private final class Opened: @unchecked Sendable {
    var apps: [String] = []
}

/// The CPU key: live on a keypad with screens, Activity Monitor when pressed —
/// and pinned keys, which it's made for.
final class CPUModuleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func registry(_ module: CPUModule) -> ModuleRegistry {
        let registry = ModuleRegistry()
        registry.register(module, host: MemoryModuleHost())
        return registry
    }

    private func config(_ text: String, registry: ModuleRegistry) throws -> (KeybowConfig, OutlineCompilation) {
        let (document, problems) = OutlineParser.parse(text)
        XCTAssertEqual(problems, [])
        let compiled = OutlineCompiler.compile(document, locateApp: { _ in nil }, vocabulary: registry.vocabulary)
        return (try XCTUnwrap(compiled.config), compiled)
    }

    func testLoadIsTheShareOfTimeBusy() {
        let earlier = CPUTicks(busy: 100, idle: 300)
        XCTAssertEqual(CPUTicks(busy: 150, idle: 350).load(since: earlier), 0.5)
        XCTAssertEqual(CPUTicks(busy: 100, idle: 400).load(since: earlier), 0)
        XCTAssertEqual(CPUTicks(busy: 100, idle: 300).load(since: earlier), 0, "no time passed")
        XCTAssertEqual(CPUTicks(busy: 50, idle: 50).load(since: nil), 0.5, "the first: since the Mac started")
        XCTAssertEqual(CPUTicks(busy: 10, idle: 10).load(since: earlier), 0, "a counter that went backwards")
    }

    func testReadingsCompareWithTheLastLook() async throws {
        let module = CPUModule(sampler: FakeCPU([CPUTicks(busy: 0, idle: 100), CPUTicks(busy: 23, idle: 177)]))
        let key = LiveKeySpec(type: "cpu")
        let first = await module.reading(for: key, now: start)
        XCTAssertEqual(first?.value, "0%")
        let next = await module.reading(for: key, now: start)
        let second = try XCTUnwrap(next)
        XCTAssertEqual(second.value, "23%")
        XCTAssertEqual(second.caption, "CPU")
        XCTAssertEqual(second.level ?? -1, 0.23, accuracy: 0.001)
        XCTAssertEqual(module.liveInterval(for: key), 1)
        XCTAssertNil(module.liveInterval(for: LiveKeySpec(type: "other")))
    }

    func testPressingOpensActivityMonitorAtOnce() async {
        let opened = Opened()
        let module = CPUModule(sampler: FakeCPU([]), openApp: { opened.apps.append($0); return true })
        let request = ModuleRequest(type: "cpu", fields: [:], labels: ["CPU"])
        XCTAssertTrue(module.firesAtOnce(request))
        _ = await module.run(request, now: start)
        XCTAssertEqual(opened.apps, ["com.apple.ActivityMonitor"])
    }

    func testItsOnlyForKeypadsWithScreens() throws {
        let registry = registry(CPUModule(sampler: FakeCPU([])))
        XCTAssertTrue(registry.isLive("cpu"))
        XCTAssertTrue(registry.needsDisplay("cpu"))
        let (_, compiled) = try config("""
            1. Work [Copy]
            # keypad Desk [Keybow 2040]
            1. Load [CPU]
            # keypad Deck [Stream Deck]
            1. Load [CPU]
            """, registry: registry)
        let warnings = compiled.diagnostics.filter { $0.message.contains("keypads with screens") }
        XCTAssertEqual(warnings.count, 1, "the Keybow's, not the Stream Deck's: \(compiled.diagnostics)")
    }

    // MARK: Pinned keys

    private let pinned = """
        1. Work [Copy]
           1. Standup [Copy]
        # row 3
        1. Music [Copy]
        2. Radio [Copy]
        3. Podcasts [Copy]
        4. Audiobooks [Copy]
        # bottom
        1. Lights [Copy]
        # pinned
        1. CPU [CPU, colour: 202020]
        2. Clip [Copy]
        """

    func testPinnedKeysAreReadAndWrittenBack() {
        let (document, problems) = OutlineParser.parse(pinned)
        XCTAssertEqual(problems, [])
        XCTAssertEqual(document.roots(.pinned).compactMap { $0?.label }, ["CPU", "Clip"])
        let written = OutlineWriter.text(document)
        XCTAssertTrue(written.contains("# pinned\n1. CPU [CPU, colour: 202020]\n2. Clip [Copy]"), written)
    }

    func testPinnedKeysAreAlongTheBottomFromTheRight() throws {
        let registry = registry(CPUModule(sampler: FakeCPU([])))
        let (config, compiled) = try config(pinned, registry: registry)
        XCTAssertEqual(config.liveKeys(registry: registry), [LiveKeySpec(type: "cpu")])

        let reading = LiveKeyReading(value: "9%", caption: "CPU", level: 0.09)
        let navigator = Navigator(config: config, now: start)
        let view = KeypadView(config: config, tree: nil, path: [], page: nil, currentRow: nil, pending: false,
                              colours: Lighting().colours(for: navigator, config: config),
                              readings: [LiveKeySpec(type: "cpu"): reading])
        let slots = FolderLayout(columns: 5, rows: 3).slots(for: view, registry: registry)
        XCTAssertEqual(slots[14].press, .pinned(0))
        XCTAssertEqual(slots[14].face?.reading, reading)
        XCTAssertEqual(slots[13].press, .pinned(1))
        XCTAssertEqual(slots[13].face?.caption, "Clip")
        XCTAssertEqual(slots[9].press, .showBottomTree(true), "the bottom tree's key moves up for them")
        XCTAssertEqual(slots[12].face?.caption, "Podcasts", "row 3's third key still shows")

        // The second covers row 3's fourth key; the first covers nothing.
        let covered = compiled.diagnostics.filter { $0.message.contains("covers") }
        XCTAssertEqual(covered.map(\.message), ["On a Stream Deck, this covers the row 3 tree's key 4, “Audiobooks”."])
    }

    func testAPinnedKeyRunsAtOnceAndLeavesTheTreesAlone() throws {
        let registry = registry(CPUModule(sampler: FakeCPU([])))
        let (config, _) = try config(pinned, registry: registry)
        var navigator = Navigator(config: config, now: start)
        _ = navigator.keyDown(0, at: start)
        let events = navigator.pressPinned(0, at: start)
        guard case .fire(let selection, _)? = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(selection.tree, .pinned)
        XCTAssertEqual(selection.action?.type, "cpu")
        XCTAssertEqual(navigator.path, [0], "Work is still chosen")
        XCTAssertEqual(navigator.pressPinned(3, at: start), [], "nothing there")
    }

    func testThePinnedKeysAreFlat() {
        let (document, problems) = OutlineParser.parse("# pinned\n1. CPU [CPU]\n   1. Deeper [Copy]\n")
        XCTAssertFalse(problems.isEmpty, "a key under a pinned key is a mistake")
        XCTAssertEqual(document.roots(.pinned)[0]?.hasChildren, false, "and is left out")
    }
}
