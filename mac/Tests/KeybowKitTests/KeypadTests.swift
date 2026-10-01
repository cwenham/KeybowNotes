@testable import KeybowKit
import XCTest

final class KeypadTests: XCTestCase {
    private let outline = """
        1. Work [Copy]
           1. Standup

        # row 2
        1. Capture [Copy]

        # keypad RGB Keypad [RGB Keypad]
        1. Music [Copy]
           1. Play
        # row 3
        1. Timers [Copy]

        # keypad Spare [Keybow 2040, id: E66000000000AAAA]
        1. Spare [Copy]

        # contacts
        - Alex Example [phone: +15550100]
        """

    private let keybow = KeypadDevice(serial: "E66000000000BBBB", model: .keybow2040, dataPort: "/dev/a")
    private let rgb = KeypadDevice(serial: "E66000000000CCCC", model: .rgbKeypad, dataPort: "/dev/b")
    private let spare = KeypadDevice(serial: "e66000000000aaaa", model: .keybow2040, dataPort: "/dev/c")

    private func labels(_ level: [OutlineNode?]) -> [String] { level.compactMap { $0?.label } }
    private func labels(_ level: [TreeNode?]) -> [String] { level.compactMap { $0?.label } }

    func testKeypadSectionsHoldTheirOwnTrees() {
        let (document, problems) = OutlineParser.parse(outline)
        XCTAssertEqual(problems, [])
        XCTAssertEqual(labels(document.roots(.main)), ["Work"], "before any keypad heading: the first keypad's")
        XCTAssertEqual(labels(document.roots(.row2)), ["Capture"])
        XCTAssertEqual(document.keypads.map(\.name), ["RGB Keypad", "Spare"])
        XCTAssertEqual(document.keypads.map(\.model), [.rgbKeypad, .keybow2040])
        XCTAssertEqual(document.keypads.map(\.id), [nil, "E66000000000AAAA"])
        XCTAssertEqual(labels(document.roots(.main, keypad: 1)), ["Music"], "its main tree right under its heading")
        XCTAssertEqual(labels(document.roots(.row3, keypad: 1)), ["Timers"], "a tree heading after it is its")
        XCTAssertEqual(labels(document.roots(.row3)), [])
        XCTAssertEqual(labels(document.roots(.main, keypad: 2)), ["Spare"])
        XCTAssertEqual(document.contacts.map(\.name), ["Alex Example"], "contacts stay shared")
        XCTAssertEqual(document.keypadCount, 3)
    }

    func testItWritesBackAsItReads() {
        let (document, _) = OutlineParser.parse(outline)
        let written = OutlineWriter.text(document)
        XCTAssertTrue(written.contains("# keypad RGB Keypad [RGB Keypad]\n1. Music [Copy]\n   1. Play\n\n# row 3\n1. Timers [Copy]"),
                      written)
        XCTAssertTrue(written.contains("# keypad Spare [Keybow 2040, id: E66000000000AAAA]\n1. Spare [Copy]"))
        XCTAssertEqual(OutlineWriter.text(OutlineParser.parse(written).0), written)
        XCTAssertLessThan(written.range(of: "# row 2")!.lowerBound, written.range(of: "# keypad")!.lowerBound,
                          "the first keypad's trees come first")
    }

    func testAFileWithoutKeypadsIsAsItWas() {
        let plain = "1. Work [Copy]\n\n# row 2\n1. Capture [Copy]\n"
        let (document, _) = OutlineParser.parse(plain)
        XCTAssertTrue(document.keypads.isEmpty)
        XCTAssertEqual(OutlineWriter.text(document), plain)
        let config = try! XCTUnwrap(OutlineCompiler.compile(document, locateApp: { _ in nil }).config)
        XCTAssertEqual(labels(config.forDevice(rgb).roots(.main)), ["Work"], "every keypad shares the trees")
    }

    func testEachDeviceGetsItsKeypadsTrees() throws {
        let (document, _) = OutlineParser.parse(outline)
        let compiled = OutlineCompiler.compile(document, locateApp: { _ in nil })
        let config = try XCTUnwrap(compiled.config)
        XCTAssertEqual(config.keypads.map(\.name), ["RGB Keypad", "Spare"])
        XCTAssertEqual(config.keypadIndex(for: rgb), 1, "by model")
        XCTAssertEqual(config.keypadIndex(for: spare), 2, "by its ID, over the model's section")
        XCTAssertEqual(config.keypadIndex(for: keybow), 0, "no section of its own: the first keypad's")
        XCTAssertEqual(labels(config.forDevice(rgb).roots(.main)), ["Music"])
        XCTAssertEqual(labels(config.forDevice(rgb).roots(.row3)), ["Timers"])
        XCTAssertEqual(labels(config.forDevice(keybow).roots(.main)), ["Work"])
        XCTAssertEqual(config.forDevice(rgb).contacts["Alex Example"]?["phone"], "+15550100", "shared")
        XCTAssertTrue(compiled.json.contains(#""keypads": ["#), compiled.json)
    }

    func testWithNoTreesOfItsOwnTheFirstSectionIsTheFallback() throws {
        let (document, _) = OutlineParser.parse("# keypad Desk [Keybow 2040]\n1. Work [Copy]\n")
        let config = try XCTUnwrap(OutlineCompiler.compile(document, locateApp: { _ in nil }).config)
        XCTAssertEqual(config.keypadIndex(for: rgb), 1)
        XCTAssertEqual(labels(config.forDevice(rgb).roots(.main)), ["Work"])
    }

    func testAModelThatIsntOneIsNoted() {
        let (document, _) = OutlineParser.parse("# keypad Odd [Stream Deck]\n1. Work [Copy]\n")
        let compiled = OutlineCompiler.compile(document, locateApp: { _ in nil })
        XCTAssertEqual(compiled.warnings, ["Keypad “Odd”: “Stream Deck” isn't a model — Keybow 2040 or RGB Keypad."])
        XCTAssertNil(document.keypads.first?.model)
    }

    func testNodesInAKeypadsTreesAreFoundAndEdited() throws {
        var (document, _) = OutlineParser.parse(outline)
        let play = try XCTUnwrap(document.roots(.main, keypad: 1)[0]?.children[0])
        let location = try XCTUnwrap(document.location(of: play.id))
        XCTAssertEqual(location.container, .tree(.main, keypad: 1))
        XCTAssertEqual(location.path, [0, 0])
        XCTAssertEqual(document.node(at: location)?.label, "Play")
        XCTAssertEqual(OutlineContainer.tree(.row3, keypad: 1).levels, 2)
        XCTAssertEqual(OutlineContainer.tree(.main), .tree(.main, keypad: 0), "the first keypad's, unless said")

        try document.setText(play.id, "Pause [Copy]")
        XCTAssertEqual(document.roots(.main, keypad: 1)[0]?.children[0]?.label, "Pause")
        XCTAssertEqual(labels(document.roots(.main)), ["Work"], "the first keypad's trees untouched")
    }

    func testModelsByName() {
        XCTAssertEqual(KeypadDevice.Model(words: "Keybow 2040"), .keybow2040)
        XCTAssertEqual(KeypadDevice.Model(words: "keybow"), .keybow2040)
        XCTAssertEqual(KeypadDevice.Model(words: "RGB Keypad"), .rgbKeypad)
        XCTAssertEqual(KeypadDevice.Model(words: "Pico"), .rgbKeypad)
        XCTAssertNil(KeypadDevice.Model(words: "Stream Deck"))
    }
}
