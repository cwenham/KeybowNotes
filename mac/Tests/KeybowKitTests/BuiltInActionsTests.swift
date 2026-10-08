@testable import KeybowKit
import XCTest

/// The built-in action types, described once — and read as they were when
/// each part of the app kept its own table.
final class BuiltInActionsTests: XCTestCase {
    /// Those built in, without any module's.
    private let vocabulary = ActionVocabulary()

    func testKeywordsReadAndWritten() {
        let read: [String: String] = [
            "notes": "notes.create", "new": "notes.create", "create": "notes.create", "append": "notes.append",
            "calendar": "calendar.createEvent", "reminders": "reminders.create", "messages": "messages.compose",
            "mail": "mail.compose", "call": "phone.call", "facetime": "phone.call", "link": "url.open",
            "browser": "url.open", "copy": "clipboard.copy", "clipboard": "clipboard.copy", "insert": "text.insert",
            "paste": "text.insert", "direct insert": "text.insertDirect", "type": "text.insertDirect",
            "timer": "clock.timer", "maps": "maps.search", "music": "music.play",
        ]
        XCTAssertEqual(vocabulary.keywords, Set(read.keys))
        for (word, type) in read {
            XCTAssertEqual(vocabulary.knownType(word.uppercased()), type, word)
            XCTAssertEqual(OutlineCompiler.role(of: .word(word), inheritedType: nil, inheritedApp: nil, listNames: [],
                                                locateApp: { _ in nil }, vocabulary: vocabulary), .actionType(type), word)
        }
        XCTAssertEqual(vocabulary.knownType("music.play"), "music.play", "by its full name")
        XCTAssertNil(vocabulary.knownType("teleport"))

        let written: [String: String] = [
            "notes.create": "Notes", "notes.append": "append", "calendar.createEvent": "Calendar",
            "reminders.create": "Reminders", "messages.compose": "Messages", "mail.compose": "Mail", "phone.call": "Call",
            "url.open": "Link", "clipboard.copy": "Copy", "text.insert": "Insert", "text.insertDirect": "Direct Insert",
            "clock.timer": "Timer", "maps.search": "Maps", "music.play": "Music",
        ]
        for type in BuiltInActions.types.map(\.type) {
            XCTAssertEqual(vocabulary.keyword(for: type), written[type], type)
        }
    }

    func testFieldsAndTheirKinds() {
        XCTAssertEqual(Set(vocabulary.fields.map(\.key)).union(["type", "instant"]), [
            "type", "folder", "title", "template", "account", "entry", "createIfMissing",
            "find.byName", "guards.maxBodyBytes", "guards.refuseInlineImages",
            "start", "duration", "alertMinutes", "calendar", "calendarId", "notes", "show",
            "due", "list", "to", "body", "subject",
            "app", "bundleId", "open", "url", "target", "name", "input", "via", "text",
            "shortcut", "query", "playlist", "album", "artist", "shuffle", "instant", "format",
            "song", "genre",
        ])
        XCTAssertTrue(vocabulary.isNumericField("alertMinutes", type: "calendar.createEvent"))
        XCTAssertTrue(vocabulary.isNumericField("guards.maxBodyBytes", type: "notes.append"))
        XCTAssertTrue(vocabulary.isNumericField("alertMinutes", type: nil), "for any action")
        XCTAssertFalse(vocabulary.isNumericField("duration", type: "calendar.createEvent"), "30m is text")
        XCTAssertTrue(vocabulary.isBooleanField("show", type: "calendar.createEvent"))
        XCTAssertTrue(vocabulary.isBooleanField("createIfMissing", type: "notes.append"))
        XCTAssertTrue(vocabulary.isBooleanField("guards.refuseInlineImages", type: "notes.append"))
        XCTAssertTrue(vocabulary.isBooleanField("shuffle", type: "music.play"))
        XCTAssertTrue(vocabulary.isBooleanField("instant", type: "url.open"), "every action's")
        XCTAssertFalse(vocabulary.isBooleanField("shuffle", type: "notes.create"))

        for type in BuiltInActions.types {
            XCTAssertFalse(type.title.isEmpty, type.type)
            XCTAssertFalse(type.symbol.isEmpty, type.type)
            for field in type.fields {
                XCTAssertFalse(field.help.isEmpty, "\(type.type) \(field.key) says what it's for")
            }
        }
        XCTAssertEqual(BuiltInActions.types.count, 16)
        XCTAssertEqual(BuiltInActions.types.filter(\.takesText).map(\.type), ["clipboard.copy", "text.insert", "text.insertDirect"])
    }

    func testDefaults() {
        XCTAssertEqual(Set(BuiltInActions.defaults.keys), [
            "notes.create", "notes.append", "calendar.createEvent", "reminders.create", "messages.compose",
            "mail.compose", "phone.call", "app.open",
        ])
        XCTAssertEqual(BuiltInActions.defaults["calendar.createEvent"]?["start"], .string("{{when}}"))
        XCTAssertEqual(KeybowConfig.builtInDefaultAction.fields, BuiltInActions.defaults["notes.create"],
                       "a bare leaf's note is filed as a [Notes] one is")
    }

    func testNoteWordsAreTypesToReplace() throws {
        var doc = OutlineParser.parse("1. Docs [new, template.md]").0
        let id = try XCTUnwrap(doc.roots(.main)[0]?.id)
        try doc.setType(id, "notes.append")
        XCTAssertEqual(doc.node(id)?.text, "Docs [append, template.md]")
        try doc.setType(id, "notes.create")
        XCTAssertEqual(doc.node(id)?.text, "Docs [Notes, template.md]")
    }

    func testTheCatalogListsThem() {
        let catalog = AgentGuide.catalog()
        XCTAssertTrue(catalog.contains("- `phone.call`, Phone call — `Call`, `FaceTime`"), catalog)
        XCTAssertTrue(catalog.contains("- `notes.create`, New note — `Notes`, `New`, `Create`"))
        XCTAssertTrue(catalog.contains("- `maps.search`, Search Maps — `Maps`\n"))
    }

    func testModulesJoinThem() {
        let vocabulary = ActionVocabulary(modules: [
            ModuleActionType(type: "lamp", title: "Lamp", keywords: ["Lamp", "Copy"], symbol: "lightbulb", fields: [
                ModuleField(key: "level", title: "Level", kind: .number),
                ModuleField(key: "ok", title: "On OK", kind: .action),
            ]),
        ])
        XCTAssertEqual(vocabulary.knownType("lamp"), "lamp")
        XCTAssertEqual(vocabulary.type(forKeyword: "copy"), "clipboard.copy", "a module can't take a built-in keyword")
        XCTAssertTrue(vocabulary.isNumericField("level", type: "lamp"))
        XCTAssertTrue(vocabulary.isActionField("ok.text"), "a field of the action OK runs")
        XCTAssertEqual(vocabulary.heldField("ok.text")?.field, "text")
        XCTAssertFalse(ActionVocabulary().isActionField("level"), "only where the module is")
    }
}
