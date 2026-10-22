@testable import KeybowKit
import XCTest

/// Steps: bulleted items under a key, each an action run in turn, and
/// conditions guarding the steps under them.
final class StepsTests: XCTestCase {
    private let outline = """
        1. Standup [Calendar, title: Standup]
           - [Calendar]
           - Notes for it [Notes, folder: Standups]
           - If {{answer}} is yes [mood: glad]
              - [Copy, text: {{mood}}]
           - Else
              - Show [Insert, text: No]
        2. Other

        """

    private func compile(_ text: String) throws -> (OutlineDocument, OutlineCompilation, KeybowConfig) {
        let (document, problems) = OutlineParser.parse(text)
        XCTAssertTrue(problems.isEmpty, "\(problems)")
        let compiled = OutlineCompiler.compile(document, locateApp: { _ in nil })
        return (document, compiled, try XCTUnwrap(compiled.config, compiled.configError ?? ""))
    }

    private func errors(_ compiled: OutlineCompilation) -> [String] {
        compiled.diagnostics.filter { $0.severity == .error }.map(\.message)
    }

    // MARK: - Reading and writing

    func testBulletsUnderAKeyAreItsSteps() throws {
        let (document, problems) = OutlineParser.parse(outline)
        XCTAssertTrue(problems.isEmpty)
        let standup = try XCTUnwrap(document.roots(.main)[0])
        XCTAssertTrue(standup.isLeaf, "steps don't make it a branch")
        XCTAssertEqual(standup.steps.map(\.label), ["", "Notes for it", "If {{answer}} is yes", "Else"])
        XCTAssertEqual(standup.steps[0].annotations, [.word("Calendar")])
        XCTAssertEqual(standup.steps[2].steps.map(\.text), [#"[Copy, text: {{mood}}]"#])
        XCTAssertEqual(standup.steps[3].steps.first?.label, "Show")
        XCTAssertEqual(standup.steps[2].line, 4)
        XCTAssertNotNil(document.roots(.main)[1])
    }

    func testWrittenBackAsTheyWereRead() {
        let (document, _) = OutlineParser.parse(outline)
        XCTAssertEqual(OutlineWriter.text(document), outline)
    }

    func testAKeyCantGoUnderAStep() {
        let (document, problems) = OutlineParser.parse("""
            1. Key
               - Step
                  1. Too far
            2. Next
            """)
        XCTAssertEqual(problems.map(\.line), [3])
        XCTAssertTrue(problems[0].message.contains("can't go under a step"))
        XCTAssertNil(document.roots(.main)[0]?.children[0])
        XCTAssertNotNil(document.roots(.main)[1], "the rest is read")
    }

    func testABulletBeforeAnyKeyIsNoted() {
        let (document, problems) = OutlineParser.parse("""
            # row 2
            - Stray
            1. Key
            """)
        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(document.roots(.row2)[0]?.steps, [])
    }

    func testAPreambleKeepsItsBullets() {
        let text = "My keys\n- a note to self\n\n1. Key\n"
        let (document, problems) = OutlineParser.parse(text)
        XCTAssertTrue(problems.isEmpty)
        XCTAssertEqual(document.preamble, ["My keys", "- a note to self"])
        XCTAssertEqual(OutlineWriter.text(document), text)
    }

    func testStepsInAList() throws {
        let (_, compiled, config) = try compile("""
            1. Mood [@moods]

            # list moods
            1. Great
               - [Copy]
               - [Insert]
            """)
        XCTAssertTrue(errors(compiled).isEmpty, "\(errors(compiled))")
        let selection = try XCTUnwrap(config.resolve(path: [0, 0]))
        XCTAssertEqual(selection.steps.map(\.action.type), ["clipboard.copy", "text.insert"])
    }

    // MARK: - Inheriting

    func testEachStepInheritsFromItsKey() throws {
        let (_, compiled, config) = try compile(outline)
        XCTAssertTrue(errors(compiled).isEmpty, "\(errors(compiled))")
        let selection = try XCTUnwrap(config.resolve(path: [0]))
        XCTAssertEqual(selection.action?.type, "calendar.createEvent", "what the key gives its steps")
        let steps = selection.steps
        XCTAssertEqual(steps.count, 4)

        XCTAssertEqual(steps[0].kind, .action)
        XCTAssertEqual(steps[0].action.type, "calendar.createEvent")
        XCTAssertEqual(steps[0].action.string("title"), "Standup", "from the key")

        XCTAssertEqual(steps[1].label, "Notes for it")
        XCTAssertEqual(steps[1].action.type, "notes.create")
        XCTAssertEqual(steps[1].action.string("folder"), "Standups")
        XCTAssertNotEqual(steps[1].action.string("title"), "Standup", "another type starts afresh")

        guard case .condition(let condition) = steps[2].kind else { return XCTFail("a condition") }
        XCTAssertEqual(condition.branch, .ifTrue)
        XCTAssertEqual(condition.test, StepTest(left: "{{answer}}", op: .equals, right: "yes", text: "{{answer}} is yes"))
        XCTAssertEqual(steps[2].steps.map(\.action.type), ["clipboard.copy"])
        XCTAssertEqual(steps[2].steps[0].params["mood"], "glad", "from the If above it")
        XCTAssertEqual(steps[2].steps[0].params["leaf"], "Standup", "{{leaf}} is still the key's")
        XCTAssertNil(steps[1].params["mood"])

        guard case .condition(let otherwise) = steps[3].kind else { return XCTFail("a condition") }
        XCTAssertEqual(otherwise.branch, .otherwise)
        XCTAssertEqual(steps[3].steps[0].action.type, "text.insert")
    }

    func testTheCompiledFormHoldsThem() throws {
        let (_, compiled, _) = try compile(outline)
        XCTAssertTrue(compiled.json.contains(#""steps": ["#), compiled.json)
        XCTAssertTrue(compiled.json.contains(#""if": "{{answer}} is yes""#), compiled.json)
        XCTAssertTrue(compiled.json.contains(#""else": true"#), compiled.json)
        // And loads again, as a file of it would.
        let config = try KeybowConfig.parse(Data(compiled.json.utf8))
        XCTAssertEqual(config.resolve(path: [0])?.steps.count, 4)
    }

    func testALeafUnderABranchGetsItsValues() throws {
        let (_, compiled, config) = try compile("""
            1. Meeting [Calendar]
               1. Tomorrow
                  - The event
                  - [Reminders, title: "Get ready for {{parent}}", due: "{{when}}"]
            2. Messages [Messages]
               1. Rudy Rudolph
                  - [Messages]
                  - [Mail]
            """)
        XCTAssertTrue(errors(compiled).isEmpty, "\(errors(compiled))")
        let tomorrow = try XCTUnwrap(config.resolve(path: [0, 0]))
        XCTAssertEqual(tomorrow.steps.map(\.action.type), ["calendar.createEvent", "reminders.create"])
        XCTAssertEqual(tomorrow.steps[1].params["when"], "tomorrow", "the label still reads as a date")
        XCTAssertEqual(tomorrow.steps[0].label, "The event")
        XCTAssertEqual(config.contacts["Rudy Rudolph"]?.keys.sorted(), ["email", "phone"], "each step's type asks for its own")
    }

    func testTheFirstStepDecidesTheWait() throws {
        let (_, _, config) = try compile("""
            1. Go [instant: true]
               - [Copy]
               - [Insert]
            2. Wait
               - [Copy]
            """)
        XCTAssertEqual(config.commitDelay(for: try XCTUnwrap(config.resolve(path: [0]))), 0)
        XCTAssertEqual(config.commitDelay(for: try XCTUnwrap(config.resolve(path: [1]))), config.commitDelay)
    }

    func testAStepsInheritedActionForTheInspector() throws {
        let (_, _, config) = try compile(outline)
        XCTAssertEqual(config.inheritedAction(path: [0], step: [1])?.string("folder"), "Standups")
        XCTAssertEqual(config.inheritedAction(path: [0], step: [1], above: true)?.type, "calendar.createEvent")
        XCTAssertEqual(config.inheritedAction(path: [0], step: [2, 0])?.type, "clipboard.copy")
    }

    // MARK: - Mistakes

    func testStepsOnABranchAreAMistake() throws {
        let (document, compiled, config) = try compile("""
            1. Work
               - [Copy]
               1. Standup
            """)
        let work = try XCTUnwrap(document.roots(.main)[0])
        XCTAssertEqual(compiled.nodes[work.id]?.diagnostics.first?.severity, .error)
        XCTAssertEqual(config.resolve(path: [0, 0])?.steps, [])
    }

    func testAnElseNeedsAnIfBeforeIt() throws {
        let (_, compiled, config) = try compile("""
            1. Key
               - Else
                  - [Copy]
               - [Insert]
            """)
        XCTAssertEqual(errors(compiled).count, 1)
        XCTAssertEqual(config.resolve(path: [0])?.steps.map(\.action.type), ["text.insert"], "the Else is left out")
    }

    func testOnlyAConditionHasStepsUnderIt() throws {
        let (_, compiled, config) = try compile("""
            1. Key
               - Copy it [Copy]
                  - [Insert]
               - [Insert]
            """)
        XCTAssertEqual(errors(compiled).count, 1)
        XCTAssertEqual(config.resolve(path: [0])?.steps.count, 1)
    }

    func testAConditionThatCantBeRead() throws {
        let (_, compiled, _) = try compile("""
            1. Key
               - If
                  - [Copy]
               - If {{#ai}}Is it urgent?{{/ai}} is yes
                  - [Copy]
               - If {{answer}} is
                  - [Copy]
               - Else maybe
                  - [Copy]
            """)
        let found = errors(compiled)
        XCTAssertEqual(found.count, 4, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("{{#ai}}") })
    }

    func testAnIfWithNothingUnderItIsNoted() throws {
        let (_, compiled, config) = try compile("""
            1. Key
               - If {{selection}}
               - [Copy]
            """)
        XCTAssertTrue(errors(compiled).isEmpty)
        XCTAssertEqual(compiled.diagnostics.filter { $0.severity == .warning }.count, 1)
        XCTAssertEqual(config.resolve(path: [0])?.steps.count, 2)
    }

    // MARK: - Conditions

    func testConditionsAreRead() throws {
        func parsed(_ label: String) -> StepCondition? { try? StepCondition.parse(label)?.get() }
        XCTAssertNil(StepCondition.parse("Make the note"))
        XCTAssertNil(StepCondition.parse("Iffy"))
        XCTAssertEqual(parsed("Else")?.branch, .otherwise)
        XCTAssertEqual(parsed("otherwise:")?.branch, .otherwise)
        XCTAssertEqual(parsed("Else if {{x}} > 3")?.test?.op, .greater)
        XCTAssertEqual(parsed("If {{x}}")?.test, StepTest(left: "{{x}}", op: .truthy, text: "{{x}}"))
        XCTAssertEqual(parsed("If {{answer}} == 'true'")?.test?.right, "true")
        XCTAssertEqual(parsed("If {{answer}} is not \"the end\"")?.test?.op, .notEquals)
        XCTAssertEqual(parsed("If {{answer}} is not \"the end\"")?.test?.right, "the end")
        XCTAssertEqual(parsed("If {{a}} doesn't contain x")?.test?.op, .notContains)
        XCTAssertEqual(parsed("If {{a}} is empty")?.test?.op, .empty)
        XCTAssertEqual(parsed("If {{a}} is empty-handed")?.test?.right, "empty-handed")
        XCTAssertEqual(parsed("If {{a}} isn't empty")?.test?.op, .notEmpty)
        XCTAssertEqual(parsed(#"If {{api.x name="a is b"}} is c"#)?.test?.left, #"{{api.x name="a is b"}}"#,
                       "words inside a value aren't the test's")
        XCTAssertEqual(parsed("If {{a}} is \"is\"")?.test?.right, "is", "nor inside quotes")
        XCTAssertEqual(parsed("If Bob's {{a}} is x")?.test?.left, "Bob's {{a}}", "an apostrophe isn't a quote")
        XCTAssertEqual(parsed("If {{a}}=b")?.test?.op, .equals)
        XCTAssertEqual(parsed("If {{a}} >= 2")?.test?.op, .greaterOrEqual)
    }

    func testConditionsHold() throws {
        func holds(_ label: String, _ values: [String: String]) throws -> Bool {
            let test = try XCTUnwrap(try StepCondition.parse(label)?.get().test)
            return test.holds { Template.expand($0, params: values).text }
        }
        XCTAssertTrue(try holds("If {{answer}} is yes", ["answer": " Yes "]), "case and spaces aside")
        XCTAssertFalse(try holds("If {{answer}} is yes", ["answer": "no"]))
        XCTAssertTrue(try holds("If {{answer}} != yes", ["answer": "no"]))
        XCTAssertTrue(try holds("If {{answer}}", ["answer": "anything"]))
        for nothing in ["", "false", "No", "off", "0"] {
            XCTAssertFalse(try holds("If {{answer}}", ["answer": nothing]), nothing)
        }
        XCTAssertFalse(try holds("If {{missing}}", [:]), "a missing value is nothing")
        XCTAssertTrue(try holds("If {{missing|}} is empty", [:]))
        XCTAssertTrue(try holds("If {{t}} > 9", ["t": "21.5"]), "numbers as numbers, not text")
        XCTAssertTrue(try holds("If {{t}} == 21", ["t": "21.0"]))
        XCTAssertTrue(try holds("If {{t}} < 19", ["t": "18 °"]))
        XCTAssertTrue(try holds("If {{weekday}} is saturday", ["weekday": "Saturday"]))
        XCTAssertTrue(try holds("If {{s}} contains urgent", ["s": "Not URGENT at all"]))
        XCTAssertTrue(try holds("If {{s}} starts with re:", ["s": "Re: lunch"]))
        XCTAssertTrue(try holds("If {{s}} ends with .pdf", ["s": "Report.PDF"]))
        XCTAssertTrue(try holds("If {{a}} is {{b}}", ["a": "same", "b": "Same"]), "values on both sides")
        XCTAssertTrue(try holds(#"If {{a}} is """#, ["a": ""]))
    }

    // MARK: - Editing

    private func document(_ text: String) -> OutlineDocument { OutlineParser.parse(text).0 }

    func testAddingSteps() throws {
        var doc = document("1. Key [Copy]\n2. Branch\n   1. Leaf\n")
        let key = try XCTUnwrap(doc.roots(.main)[0]?.id)
        let first = try doc.addStep(after: key, label: "First")
        let second = try doc.addStep(after: key)
        try doc.setText(second, "[Maps]")
        let between = try doc.addStep(after: first, label: "Between")
        XCTAssertEqual(doc.node(key)?.steps.map(\.text), ["First", "Between", "[Maps]"])
        XCTAssertEqual(doc.stepAddress(of: between)?.path, [1])
        XCTAssertEqual(doc.keyLocation(of: between)?.path, [0])
        XCTAssertTrue(doc.isStep(between))
        XCTAssertFalse(doc.isStep(key))

        let branch = try XCTUnwrap(doc.roots(.main)[1]?.id)
        XCTAssertThrowsError(try doc.addStep(after: branch)) {
            XCTAssertEqual($0 as? OutlineEditError, .stepsNeedALeaf("Branch"))
        }
    }

    func testNestingStepsUnderAnIf() throws {
        var doc = document("""
            1. Key
               - If {{answer}}
               - [Copy]
               - [Maps]
               - [Insert]
            """)
        let steps = try XCTUnwrap(doc.roots(.main)[0]?.steps)
        func texts() -> [String] { doc.roots(.main)[0]?.steps.map(\.text) ?? [] }
        try doc.indentStep(steps[1].id)
        XCTAssertEqual(texts(), ["If {{answer}}", "[Maps]", "[Insert]"])
        XCTAssertEqual(doc.roots(.main)[0]?.steps[0].steps.map(\.text), ["[Copy]"])
        XCTAssertEqual(doc.stepChain(of: steps[1].id).map(\.label), ["If {{answer}}", ""])
        XCTAssertThrowsError(try doc.indentStep(steps[3].id), "not under an action") {
            XCTAssertEqual($0 as? OutlineEditError, .onlyAConditionTakesSteps)
        }

        try doc.moveStep(steps[3].id, by: -1)
        XCTAssertEqual(texts(), ["If {{answer}}", "[Insert]", "[Maps]"])
        try doc.moveStep(steps[3].id, by: -1)
        XCTAssertThrowsError(try doc.moveStep(steps[3].id, by: -1))
        XCTAssertEqual(texts(), ["[Insert]", "If {{answer}}", "[Maps]"])

        try doc.outdentStep(steps[1].id)
        XCTAssertEqual(texts(), ["[Insert]", "If {{answer}}", "[Copy]", "[Maps]"])
        XCTAssertThrowsError(try doc.outdentStep(steps[1].id)) {
            XCTAssertEqual($0 as? OutlineEditError, .alreadyOutermost)
        }

        try doc.setPair(steps[1].id, key: "text", value: "hi")
        XCTAssertEqual(doc.node(steps[1].id)?.text, "[Copy, text: hi]")
        try doc.delete(steps[0].id)
        XCTAssertEqual(texts(), ["[Insert]", "[Copy, text: hi]", "[Maps]"])
    }

    func testAnIfAndItsElseStayTogether() throws {
        var doc = document("""
            1. Key
               - If {{answer}}
                  - [Copy]
               - Else
                  - [Maps]
            """)
        let steps = try XCTUnwrap(doc.roots(.main)[0]?.steps)
        // A step added at an If goes under it, not between it and its Else.
        let added = try doc.addStep(after: steps[0].id, label: "Then")
        XCTAssertEqual(doc.roots(.main)[0]?.steps[0].steps.map(\.text), ["[Copy]", "Then"])
        // Out of the If: after its Else, too.
        try doc.outdentStep(added)
        XCTAssertEqual(doc.roots(.main)[0]?.steps.map(\.text), ["If {{answer}}", "Else", "Then"])
    }

    func testAddingAnElse() throws {
        var doc = document("""
            1. Key
               - If {{answer}} is yes
                  - [Copy]
               - Else if {{answer}} is no
                  - [Maps]
               - [Insert]
               - If {{answer}}
                  - [Copy]
               - Else
                  - [Maps]
            """)
        let steps = try XCTUnwrap(doc.roots(.main)[0]?.steps)
        func labels() -> [String] { doc.roots(.main)[0]?.steps.map(\.label) ?? [] }
        XCTAssertFalse(doc.hasElse(steps[0].id))
        XCTAssertFalse(doc.hasElse(steps[1].id), "the same If, from its Else if")
        XCTAssertTrue(doc.hasElse(steps[3].id))
        XCTAssertTrue(doc.hasElse(steps[4].id))

        let (otherwise, inside) = try doc.addElse(to: steps[1].id)
        XCTAssertEqual(labels(), ["If {{answer}} is yes", "Else if {{answer}} is no", "Else", "", "If {{answer}}", "Else"],
                       "after the Else if that goes with it")
        XCTAssertEqual(doc.node(otherwise)?.steps.map(\.id), [inside], "with a step under it to type into")
        XCTAssertThrowsError(try doc.addElse(to: steps[0].id)) { XCTAssertEqual($0 as? OutlineEditError, .alreadyHasElse) }
        XCTAssertThrowsError(try doc.addElse(to: steps[3].id)) { XCTAssertEqual($0 as? OutlineEditError, .alreadyHasElse) }
        XCTAssertThrowsError(try doc.addElse(to: steps[2].id)) { XCTAssertEqual($0 as? OutlineEditError, .elseNeedsAnIf) }

        let elseIf = try doc.addElseIf(to: steps[3].id)
        try doc.setText(elseIf, "Else if {{answer}} is maybe")
        XCTAssertEqual(labels().suffix(3), ["If {{answer}}", "Else if {{answer}} is maybe", "Else"], "before its Else")
    }

    func testAKeyWithStepsTakesNoKeys() throws {
        var doc = document("""
            1. Key
               - [Copy]
            2. Next
            """)
        let next = try XCTUnwrap(doc.roots(.main)[1]?.id)
        XCTAssertThrowsError(try doc.indent(next)) { XCTAssertEqual($0 as? OutlineEditError, .keyHasSteps("Key")) }
        XCTAssertThrowsError(try doc.insertNode(at: OutlineLocation(.tree(.main), [0, 0])))
        XCTAssertThrowsError(try doc.paste([OutlineNode(label: "X")], .inside(try XCTUnwrap(doc.roots(.main)[0]?.id))))
    }

    func testCopiedWithTheirKey() throws {
        let doc = document(outline)
        let key = try XCTUnwrap(doc.roots(.main)[0])
        let text = doc.clipboardText([key.id])
        let pasted = OutlineClipboard.nodes(from: text)
        XCTAssertEqual(pasted.count, 1)
        XCTAssertEqual(pasted[0].steps.map(\.text), key.steps.map(\.text))
        XCTAssertEqual(pasted[0].steps[2].steps.map(\.text), key.steps[2].steps.map(\.text))
        XCTAssertFalse(pasted[0].hasChildren, "the bullets are steps, not keys")

        // A key and one of its steps: the key, with all of them.
        XCTAssertEqual(doc.topMost([key.id, key.steps[1].id]), [key.id])
    }

    func testStepsCopiedAndPastedByThemselves() throws {
        var doc = document(outline + "3. Plain [Copy]\n")
        let key = try XCTUnwrap(doc.roots(.main)[0])
        let text = doc.clipboardText([key.steps[2].id, key.steps[2].steps[0].id, key.steps[3].id])
        XCTAssertEqual(text, """
            - If {{answer}} is yes [mood: glad]
               - [Copy, text: {{mood}}]
            - Else
               - Show [Insert, text: No]

            """)
        let steps = OutlineClipboard.steps(from: text)
        XCTAssertEqual(steps.map(\.label), ["If {{answer}} is yes", "Else"])
        let plain = try XCTUnwrap(doc.roots(.main)[2]?.id)
        let placed = try doc.pasteSteps(steps, after: plain)
        XCTAssertEqual(doc.node(plain)?.steps.map(\.label), ["If {{answer}} is yes", "Else"])
        XCTAssertEqual(placed.count, 2)
        XCTAssertNotEqual(placed[0], steps[0].id, "copies")
        // Numbered lines become steps too, when that's what's wanted.
        XCTAssertEqual(OutlineClipboard.steps(from: "1. [Copy]\n2. [Maps]\n").map(\.text), ["[Copy]", "[Maps]"])
    }

    func testAPlainBulletedListStillPastesAsKeys() {
        let nodes = OutlineClipboard.nodes(from: "- Work\n  - Meeting\n- Home\n")
        XCTAssertEqual(nodes.map(\.label), ["Work", "Home"])
        XCTAssertEqual(nodes[0].children.compactMap { $0?.label }, ["Meeting"])
        XCTAssertEqual(nodes[0].steps, [])
    }
}
