@testable import KeybowKit
import XCTest

/// The app, made up: says what it was asked.
private final class FakeApp: AppAsking {
    var asked: [[String]] = []
    var refusal: String?

    func ask(_ command: String, _ values: [String]) throws -> String {
        asked.append([command] + values)
        if let refusal { throw TreeControl.Problem(refusal) }
        return "answered \(command)"
    }
}

/// KeybowNotes for AI agents: the Model Context Protocol.
final class MCPServerTests: XCTestCase {
    private var app: FakeApp!
    private var server: MCPServer!

    override func setUp() {
        app = FakeApp()
        server = MCPServer(bridge: app)
    }

    private func send(_ message: [String: Any]) -> [String: Any]? {
        let data = try! JSONSerialization.data(withJSONObject: message)
        return server.handle(String(decoding: data, as: UTF8.self))
    }

    private func call(_ tool: String, _ arguments: [String: Any] = [:]) -> (text: String, isError: Bool) {
        let reply = send(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": tool, "arguments": arguments]])
        let result = reply?["result"] as? [String: Any]
        let content = (result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (content, result?["isError"] as? Bool ?? false)
    }

    func testItIntroducesItselfInTheClientsVersion() {
        let reply = send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                          "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]]])
        let result = reply?["result"] as? [String: Any]
        XCTAssertEqual(reply?["id"] as? Int, 1)
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "keybownotes")
        XCTAssertNotNil((result?["capabilities"] as? [String: Any])?["tools"])
        XCTAssertTrue((result?["instructions"] as? String)?.contains("get_guide") == true)

        let unknown = send(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        XCTAssertEqual((unknown?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18", "its own, else")
        XCTAssertNil(send(["jsonrpc": "2.0", "method": "notifications/initialized"]), "no reply to a notification")
    }

    func testItListsItsTools() {
        let tools = (send(["jsonrpc": "2.0", "id": 3, "method": "tools/list"])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        let names = tools?.compactMap { $0["name"] as? String } ?? []
        XCTAssertEqual(names, ["get_guide", "list_action_types", "check_outline", "list_keypads", "get_tree", "get_outline",
                               "list_entries", "add_entry", "change_entry", "remove_entry", "replace_tree", "add_keypad",
                               "run_entry", "stopwatch"])
        let remove = tools?.first { $0["name"] as? String == "remove_entry" }
        XCTAssertEqual((remove?["annotations"] as? [String: Any])?["destructiveHint"] as? Bool, true)
        XCTAssertEqual((remove?["inputSchema"] as? [String: Any])?["required"] as? [String], ["path"])
    }

    func testToolsAskTheAppInOrder() {
        XCTAssertEqual(call("add_entry", ["entry": "Lamp [Home, entity: light.desk_lamp]", "under": "Lights", "tree": "row 2"]).text,
                       "answered add")
        XCTAssertEqual(app.asked.last, ["add", "Lamp [Home, entity: light.desk_lamp]", "Lights", "row 2", ""])
        _ = call("change_entry", ["path": "Lights/Lamp", "to": "Desk lamp", "keypad": "Desk"])
        XCTAssertEqual(app.asked.last, ["change", "Lights/Lamp", "Desk lamp", "", "Desk"])
        _ = call("run_entry", ["path": "Lights/Lamp"])
        XCTAssertEqual(app.asked.last, ["trigger", "Lights/Lamp", "", ""])
        _ = call("stopwatch")
        XCTAssertEqual(app.asked.last, ["stopwatch", "read"])
        _ = call("stopwatch", ["command": "Start"])
        XCTAssertEqual(app.asked.last, ["stopwatch", "start"])
    }

    func testWhatGoesWrongIsTheToolsError() {
        var said = call("remove_entry")
        XCTAssertTrue(said.isError)
        XCTAssertEqual(said.text, "remove_entry needs path.")
        app.refusal = "There's no “Lamp” at the top."
        said = call("run_entry", ["path": "Lamp"])
        XCTAssertTrue(said.isError)
        XCTAssertEqual(said.text, "There's no “Lamp” at the top.")
        XCTAssertTrue(call("stopwatch", ["command": "explode"]).isError)
        let unknown = send(["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": "fly"]])
        XCTAssertEqual((unknown?["error"] as? [String: Any])?["code"] as? Int, -32602)
    }

    func testCheckingNeedsNoApp() {
        let said = call("check_outline", ["outline": "5. Five [Copy]"])
        XCTAssertEqual(said.text, "line 1: couldn't be read — Item 5: keys are numbered 1 to 4.")
        XCTAssertTrue(app.asked.isEmpty)
    }

    func testThePromptForDesigningTrees() {
        let prompts = (send(["jsonrpc": "2.0", "id": 4, "method": "prompts/list"])?["result"] as? [String: Any])?["prompts"] as? [[String: Any]]
        XCTAssertEqual(prompts?.first?["name"] as? String, "design_keypad")
        let got = send(["jsonrpc": "2.0", "id": 5, "method": "prompts/get",
                        "params": ["name": "design_keypad", "arguments": ["description": "Lights and writing."]]])
        let messages = (got?["result"] as? [String: Any])?["messages"] as? [[String: Any]]
        let text = (messages?.first?["content"] as? [String: Any])?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Lights and writing."))
        XCTAssertTrue(text.contains("check_outline"))
    }

    func testOsascriptsComplaintsAreMadeReadable() {
        XCTAssertEqual(AppBridge.reason("123:456: execution error: KeybowNotes got an error: There's no “X” at the top. (1)\n"),
                       "There's no “X” at the top.")
        XCTAssertTrue(AppBridge.reason("execution error: Not authorized to send Apple events to KeybowNotes. (-1743)")
            .contains("Privacy & Security → Automation"))
    }
}
