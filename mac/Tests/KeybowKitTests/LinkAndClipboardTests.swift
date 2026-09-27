import KeybowKit
import XCTest

final class LinkAndClipboardTests: XCTestCase {
    private var templates: URL!

    override func setUpWithError() throws {
        templates = FileManager.default.temporaryDirectory.appendingPathComponent("keybow-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        try "Quote: {{selection}}\n— from {{frontApp}}".write(
            to: templates.appendingPathComponent("quote.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: templates)
    }

    private func locate(_ name: String) -> OutlineConverter.AppMatch? {
        name == "Safari" ? OutlineConverter.AppMatch(name: "Safari", installed: true, isService: false) : nil
    }

    private func resolve(_ outline: String, path: [Int]) throws -> (ResolvedSelection, KeybowConfig) {
        let (document, _) = OutlineParser.parse(outline)
        let compiled = OutlineCompiler.compile(document, locateApp: locate)
        let config = try XCTUnwrap(compiled.config, compiled.configError ?? "")
        return (try XCTUnwrap(config.resolve(path: path)), config)
    }

    private func plan(_ outline: String, path: [Int], environment: [String: String] = [:]) throws -> ActionPlan {
        let (selection, config) = try resolve(outline, path: path)
        return try ActionPlanner.plan(selection, config: config, context: ActionContext(
            templatesDirectory: templates, environment: environment)).plan
    }

    private func assertRefused(_ outline: String, path: [Int], environment: [String: String] = [:],
                               with expected: ActionPlanError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try plan(outline, path: path, environment: environment), file: file, line: line) {
            XCTAssertEqual($0 as? ActionPlanError, expected, file: file, line: line)
        }
    }

    // MARK: - Placeholders

    func testValuesInsideALinkAreEncoded() {
        XCTAssertEqual(Template.linkEncoded("swift & rust = fun?"), "swift%20%26%20rust%20%3D%20fun%3F")
        XCTAssertEqual(Template.linkEncoded("owner/repo:main"), "owner/repo:main", "paths still read as paths")
        XCTAssertEqual(Template.linkEncoded("café"), "caf%C3%A9")
    }

    func testTemplateNames() {
        XCTAssertEqual(Template.names(in: "{{selection}} {{contact.phone|none}} {{date:d MMM}} {{ leaf }}"),
                       ["selection", "contact.phone", "date", "leaf"])
        XCTAssertTrue(Template.isSinglePlaceholder(" {{selection}} "))
        XCTAssertFalse(Template.isSinglePlaceholder("https://x/{{selection}}"))
        XCTAssertFalse(Template.isSinglePlaceholder("{{a}}{{b}}"))
    }

    func testABareLinkIsAWordNotAPair() {
        XCTAssertEqual(Annotation(parsing: "https://example.com/a?b=c"), .word("https://example.com/a?b=c"))
        XCTAssertEqual(Annotation(parsing: "url: https://example.com"), .pair(key: "url", value: "https://example.com"))
        XCTAssertEqual(Annotation(parsing: "phone: +1 555"), .pair(key: "phone", value: "+1 555"))
    }

    // MARK: - Opening links

    func testABareLinkOpensItself() throws {
        XCTAssertEqual(try plan("1. Docs [https://developer.apple.com/documentation]", path: [0]),
                       .openLink(URL(string: "https://developer.apple.com/documentation")!))
    }

    func testTheSelectionIsEncodedIntoASearch() throws {
        let outline = #"1. Search [url: "https://duckduckgo.com/?q={{selection}}"]"#
        XCTAssertEqual(try plan(outline, path: [0], environment: ["selection": "swift & rust"]),
                       .openLink(URL(string: "https://duckduckgo.com/?q=swift%20%26%20rust")!))
    }

    func testASelectedLinkIsOpenedAsItStands() throws {
        let outline = #"1. Open it [Link, url: "{{selection}}"]"#
        XCTAssertEqual(try plan(outline, path: [0], environment: ["selection": "https://x.com/a?b=1&c=2"]),
                       .openLink(URL(string: "https://x.com/a?b=1&c=2")!))
        XCTAssertEqual(try plan(outline, path: [0], environment: ["selection": "apple.com/mac"]),
                       .openLink(URL(string: "https://apple.com/mac")!), "a bare address gets https")
        assertRefused(outline, path: [0], environment: ["selection": "hello world"],
                      with: .notALink("hello world"))
    }

    func testNothingSelectedSaysSo() {
        assertRefused(#"1. Search [url: "https://duckduckgo.com/?q={{selection}}"]"#, path: [0],
                      environment: ["frontApp": "Safari"], with: .nothingSelected(app: "Safari", for: "link"))
        XCTAssertEqual(ActionPlanError.nothingSelected(app: "Safari", for: "link").description,
                       "Nothing is selected in Safari, and the link needs it.")
    }

    func testAPathTakesTheSelectionUnencoded() throws {
        let outline = #"1. File [Link, url: "~/Downloads/{{selection}}"]"#
        guard case .openLink(let url) = try plan(outline, path: [0], environment: ["selection": "My File.pdf"]) else {
            return XCTFail()
        }
        XCTAssertTrue(url.isFileURL)
        XCTAssertTrue(url.path.hasSuffix("/Downloads/My File.pdf"))
    }

    func testLeavesInheritTheBrowser() throws {
        let outline = """
        1. Web [Browser]
           1. Apple [https://apple.com]
        """
        XCTAssertEqual(try plan(outline, path: [0, 0]), .openLink(URL(string: "https://apple.com")!))
    }

    func testALinkUnderAnAppOpensInThatApp() throws {
        let outline = """
        1. Safari [Safari]
           1. Docs [https://developer.apple.com]
        """
        guard case .openApp(let name, _, let open) = try plan(outline, path: [0, 0]) else { return XCTFail() }
        XCTAssertEqual(name, "Safari")
        XCTAssertEqual(open, "https://developer.apple.com")
    }

    func testAnAppLinkEncodesItsValuesButNotAWholePlaceholder() throws {
        let outline = """
        1. Repos [Safari]
           1. Tool [open: "https://github.com/{{repo}}", repo: owner/my tool]
           2. Site [open: "{{site}}", site: https://example.com/?a=1&b=2]
        """
        guard case .openApp(_, _, let open) = try plan(outline, path: [0, 0]),
              case .openApp(_, _, let whole) = try plan(outline, path: [0, 1]) else { return XCTFail() }
        XCTAssertEqual(open, "https://github.com/owner/my%20tool")
        XCTAssertEqual(whole, "https://example.com/?a=1&b=2")
    }

    // MARK: - Copying

    func testCopyTheLabelByDefault() throws {
        let outline = """
        1. Snippets [Copy]
           1. Kind regards
        """
        XCTAssertEqual(try plan(outline, path: [0, 0]), .copyToClipboard("Kind regards"))
    }

    func testCopyPassedValues() throws {
        let outline = """
        1. Numbers [Clipboard, text: "{{contact.phone}}"]
           1. Alex Example
           2. Nobody

        # contacts
        - Alex Example [phone: +1 555 0100]
        """
        XCTAssertEqual(try plan(outline, path: [0, 0]), .copyToClipboard("+1 555 0100"))
        assertRefused(outline, path: [0, 1], with: .missing(["contact.phone"], for: "text to copy"))
    }

    func testCopyKeepsLinesAndSpaces() throws {
        XCTAssertEqual(try plan(#"1. Address [Copy, text: "1 High Street\nTown  "]"#, path: [0]),
                       .copyToClipboard("1 High Street\nTown  "))
    }

    func testCopyFromATemplateWithTheSelection() throws {
        let outline = "1. Quote [Copy, quote.md]"
        XCTAssertEqual(try plan(outline, path: [0], environment: ["selection": "To be", "frontApp": "Books"]),
                       .copyToClipboard("Quote: To be\n— from Books"))
    }

    // MARK: - Knowing when to read the selection

    func testPlaceholdersIncludeTheTemplateFile() throws {
        let context = ActionContext(templatesDirectory: templates)
        let (quote, _) = try resolve("1. Quote [Copy, quote.md]", path: [0])
        XCTAssertTrue(ActionPlanner.placeholders(for: quote, context: context).contains("selection"))
        let (plain, _) = try resolve("1. Snippet [Copy]", path: [0])
        XCTAssertFalse(ActionPlanner.placeholders(for: plain, context: context).contains("selection"))
    }

    func testSummaryShowsWhereTheSelectionGoes() throws {
        let (selection, config) = try resolve(#"1. Search [url: "https://duckduckgo.com/?q={{selection}}"]"#, path: [0])
        let before = ActionSummary(selection: selection, config: config)
        XCTAssertEqual(before.verb, "Open link")
        XCTAssertEqual(before.details, ["https://duckduckgo.com/?q=‹selected text›"])
        XCTAssertTrue(before.missing.isEmpty)
        let after = ActionSummary(selection: selection, config: config, environment: ["selection": "cats"])
        XCTAssertEqual(after.details, ["https://duckduckgo.com/?q=cats"])
    }

    func testTheEditorWritesTheKeywords() throws {
        var document = OutlineDocument()
        document.trees[.main] = [OutlineNode(label: "Thing"), nil, nil, nil]
        let id = try XCTUnwrap(document.roots(.main)[0]?.id)
        try document.setType(id, "url.open")
        XCTAssertEqual(document.node(id)?.annotations, [.word("Link")])
        try document.setType(id, "clipboard.copy")
        XCTAssertEqual(document.node(id)?.annotations, [.word("Copy")])
    }
}
