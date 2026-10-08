import Foundation

/// KeybowNotes for AI agents: the Model Context Protocol over standard input
/// and output, a JSON-RPC message a line, as `keybow mcp`. Reading the guide,
/// the action types and checking outline text happen here; everything that
/// reads or changes the person's tree, runs an entry or works the stopwatch
/// is asked of the app, through its AppleScript — so macOS asks the person,
/// once, before an agent can, and the app keeps its tree editor in step.
public final class MCPServer {
    static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let bridge: AppAsking

    public init(bridge: AppAsking = AppBridge()) {
        self.bridge = bridge
    }

    public func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = handle(line) { write(reply) }
        }
        exit(0)
    }

    private func write(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(UInt8(ascii: "\n"))
        FileHandle.standardOutput.write(data)
    }

    /// A message in; the reply out — none for a notification.
    public func handle(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return error(nil, -32700, "That isn't JSON.")
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id == nil ? nil : error(id, -32600, "There's no method.")
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return result(id, [
                "protocolVersion": Self.versions.contains(asked) ? asked : Self.versions[0],
                "capabilities": ["tools": [:], "prompts": [:]],
                "serverInfo": ["name": "keybownotes", "title": "KeybowNotes", "version": "1.0"],
                "instructions": """
                    KeybowNotes turns a 4×4 keypad into a menu of actions, set up as trees in an outline. Call \
                    get_guide before designing or changing trees, and list_keypads and get_tree before changing \
                    one. Check outline text with check_outline before writing it. Don't remove or replace what the \
                    person made without asking, and run entries only when they ask.
                    """,
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String else { return error(id, -32602, "Which tool?") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                return result(id, ["content": [["type": "text", "text": try call(name, arguments)]], "isError": false])
            } catch let unknown as UnknownTool {
                return error(id, -32602, "There's no tool \(unknown.name).")
            } catch {
                return result(id, ["content": [["type": "text", "text": "\(error)"]], "isError": true])
            }
        case "prompts/list":
            return result(id, ["prompts": [Self.designPrompt]])
        case "prompts/get":
            guard params["name"] as? String == "design_keypad" else { return error(id, -32602, "There's no such prompt.") }
            let wanted = (params["arguments"] as? [String: Any])?["description"] as? String ?? ""
            return result(id, ["description": "Design KeybowNotes trees", "messages": [[
                "role": "user",
                "content": ["type": "text", "text": Self.designRequest(wanted)],
            ]]])
        default:
            // Notifications — notifications/initialized — need no reply.
            return id == nil ? nil : error(id, -32601, "KeybowNotes doesn't do \(method).")
        }
    }

    private func result(_ id: Any?, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    private func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    // MARK: Tools

    struct UnknownTool: Error { let name: String }

    private func call(_ name: String, _ arguments: [String: Any]) throws -> String {
        func text(_ key: String) -> String { (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func required(_ key: String) throws -> String {
            let value = text(key)
            guard !value.isEmpty else { throw TreeControl.Problem("\(name) needs \(key).") }
            return value
        }
        switch name {
        case "get_guide": return try AgentGuide.text()
        case "list_action_types": return AgentGuide.catalog()
        case "check_outline": return TreeControl.check(try required("outline"))
        case "list_keypads": return try bridge.ask("keypads")
        case "get_tree": return try bridge.ask("tree", text("tree"), text("keypad"))
        case "get_outline": return try bridge.ask("whole")
        case "list_entries": return try bridge.ask("entries", text("tree"), text("keypad"))
        case "add_entry": return try bridge.ask("add", try required("entry"), text("under"), text("tree"), text("keypad"))
        case "change_entry": return try bridge.ask("change", try required("path"), try required("to"), text("tree"), text("keypad"))
        case "remove_entry": return try bridge.ask("remove", try required("path"), text("tree"), text("keypad"))
        case "replace_tree": return try bridge.ask("replace", try required("outline"), text("tree"), text("keypad"))
        case "add_keypad": return try bridge.ask("keypad", try required("name"), text("model"), text("board_id"))
        case "run_entry": return try bridge.ask("trigger", try required("path"), text("tree"), text("keypad"))
        case "stopwatch":
            let command = text("command").isEmpty ? "read" : text("command").lowercased()
            guard ["start", "stop", "lap", "reset", "toggle", "read"].contains(command) else {
                throw TreeControl.Problem("The stopwatch can start, stop, lap, reset, toggle or read.")
            }
            return try bridge.ask("stopwatch", command)
        default:
            throw UnknownTool(name: name)
        }
    }

    private static func tool(_ name: String, _ title: String, _ description: String, _ properties: [String: Any] = [:],
                             required: [String] = [], readOnly: Bool = false, destructive: Bool = false) -> [String: Any] {
        [
            "name": name, "title": title, "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive],
        ]
    }

    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }

    private static let where_: [String: Any] = [
        "tree": string("main, row 2, row 3 or bottom. Left out: main."),
        "keypad": string("Default, or a keypad section's name. Left out: the trees the keypad that's plugged in uses."),
    ]

    static let tools: [[String: Any]] = [
        tool("get_guide", "Read the guide",
             "How to design KeybowNotes trees, then the whole configuration language. Read it before designing or "
             + "changing a tree.", readOnly: true),
        tool("list_action_types", "List the action types",
             "The action types this copy of KeybowNotes has, with their keywords — and for modules, every field.",
             readOnly: true),
        tool("check_outline", "Check outline text",
             "What KeybowNotes would make of outline text: mistakes by line, and what's still to fill in. Changes nothing.",
             ["outline": string("Outline text: a tree, several, or a whole file.")], required: ["outline"], readOnly: true),
        tool("list_keypads", "List the keypads",
             "The keypads' trees by name — Default, then each keypad section — and which keypads plugged in use them.",
             readOnly: true),
        tool("get_tree", "Read a tree", "One tree, as outline text, each entry numbered by its key.", where_, readOnly: true),
        tool("get_outline", "Read the whole tree file",
             "Every keypad's trees, and the lists, contacts, projects and defaults: the file as it is.", readOnly: true),
        tool("list_entries", "List the runnable entries",
             "Every entry in a tree that runs an action, by its labels: what run_entry takes.", where_, readOnly: true),
        tool("add_entry", "Add entries",
             "Adds entries on the first free keys: a line like “Desk lamp [Home, entity: light.desk_lamp]”, or outline "
             + "lines, indented for keys under keys.",
             where_.merging(["entry": string("The entry or entries, as the outline writes them."),
                             "under": string("The entry to put them under, its labels separated by slashes. Left out: the tree's top row.")]) { a, _ in a },
             required: ["entry"]),
        tool("change_entry", "Change an entry",
             "Rewrites an entry's line — its label and what's in its brackets — keeping what's under it.",
             where_.merging(["path": string("The entry: its labels from the top of the tree, separated by slashes."),
                             "to": string("The new line: “Label [annotations]”.")]) { a, _ in a },
             required: ["path", "to"]),
        tool("remove_entry", "Remove an entry", "Removes an entry, with everything under it. Ask the person first.",
             where_.merging(["path": string("The entry: its labels, separated by slashes.")]) { a, _ in a },
             required: ["path"], destructive: true),
        tool("replace_tree", "Replace a tree",
             "Replaces a whole tree with outline text, keys where they're numbered. Ask the person first if the tree "
             + "has anything in it.",
             where_.merging(["outline": string("The tree, as outline text, without its heading.")]) { a, _ in a },
             required: ["outline"], destructive: true),
        tool("add_keypad", "Add a keypad section",
             "A keypad section with trees of its own, for every keypad of a model, or one board.",
             ["name": string("What it's called."), "model": string("Keybow 2040 or RGB Keypad."),
              "board_id": string("One board's unique ID, for two keypads of the same model.")],
             required: ["name"]),
        tool("run_entry", "Run an entry",
             "Runs an entry's action as though its keys were pressed, and says how it went. It acts for real — "
             + "creating events, drafting messages, switching lamps — so run one only when the person asks.",
             where_.merging(["path": string("The entry: its labels, separated by slashes.")]) { a, _ in a },
             required: ["path"]),
        tool("stopwatch", "Work the stopwatch", "Starts, stops, laps, resets or reads KeybowNotes' stopwatch.",
             ["command": ["type": "string", "enum": ["start", "stop", "lap", "reset", "toggle", "read"],
                          "description": "What to do. Left out: read."]]),
    ]

    // MARK: Prompts

    static let designPrompt: [String: Any] = [
        "name": "design_keypad", "title": "Design keypad trees",
        "description": "Design KeybowNotes trees for what the person wants their keypads to do.",
        "arguments": [["name": "description", "description": "What they want the keypads for.", "required": true]],
    ]

    static func designRequest(_ wanted: String) -> String {
        """
        I'd like help setting up my KeybowNotes keypads. Here's what I want them for:

        \(wanted)

        First read the guide (get_guide) and the action types here (list_action_types). Then look at what I have: \
        list_keypads, and get_tree for each tree. Design trees for what I've described, check them with \
        check_outline, and show me the outline with a short note on each tree before changing anything. Once I \
        agree, add them — and don't remove or replace anything of mine without asking.
        """
    }
}

/// What the MCP server asks the app: a command, and its values.
public protocol AppAsking {
    func ask(_ command: String, _ values: [String]) throws -> String
}

extension AppAsking {
    func ask(_ command: String, _ values: String...) throws -> String { try ask(command, values) }
}

/// The app, asked through its AppleScript: `osascript`, with every value
/// passed as an argument rather than written into the script.
public struct AppBridge: AppAsking {
    public init() {}

    static let script = """
        on run argv
            set command to item 1 of argv
            set a to item 2 of argv
            set b to item 3 of argv
            set c to item 4 of argv
            set d to item 5 of argv
            with timeout of 600 seconds
                tell application id "\(AppLocations.bundleID)"
                    if command is "keypads" then return keypad names
                    if command is "tree" then return tree outline tree a keypad b
                    if command is "whole" then return whole outline
                    if command is "entries" then
                        set found to tree entries tree a keypad b
                        set AppleScript's text item delimiters to linefeed
                        return found as text
                    end if
                    if command is "add" then return add entry a under b tree c keypad d
                    if command is "change" then return change entry a to b tree c keypad d
                    if command is "remove" then return remove entry a tree b keypad c
                    if command is "replace" then return replace tree with outline a tree b keypad c
                    if command is "keypad" then return add keypad a model b board id c
                    if command is "trigger" then return trigger a tree b keypad c
                    if command is "stopwatch" then
                        if a is "start" then return start stopwatch
                        if a is "stop" then return stop stopwatch
                        if a is "lap" then return lap stopwatch
                        if a is "reset" then return reset stopwatch
                        if a is "toggle" then return toggle stopwatch
                        return stopwatch reading
                    end if
                end tell
            end timeout
            error "KeybowNotes doesn't know " & command
        end run
        """

    public func ask(_ command: String, _ values: [String]) throws -> String {
        let padded = (values + Array(repeating: "", count: 4)).prefix(4)
        let result = try Osascript.runAndWait(Self.script, [command] + padded)
        guard result.status == 0 else { throw TreeControl.Problem(Self.reason(result.errorText)) }
        return result.text.trimmingCharacters(in: .newlines)
    }

    /// "…: execution error: KeybowNotes got an error: There's no … (1)" → the part a person reads.
    static func reason(_ text: String) -> String {
        if Osascript.isNotAllowed(text) {
            return "macOS hasn't allowed this app to control KeybowNotes: " + Osascript.allowIt
        }
        let reason = Osascript.reason(text)
        if reason.contains("-1728") || reason.contains("Can’t get application") {
            return "KeybowNotes isn't installed, or couldn't be opened."
        }
        return reason.isEmpty ? "KeybowNotes didn't answer." : reason
    }
}
