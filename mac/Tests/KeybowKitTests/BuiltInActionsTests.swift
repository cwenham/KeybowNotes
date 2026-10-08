@testable import KeybowKit
import XCTest

/// The built-in action types, described once — and read as they were when
/// each part of the app kept its own table.
final class BuiltInActionsTests: XCTestCase {
    func testKeywordsReadAndWritten() {
        let read: [String: String] = [
            "notes": "notes.create", "new": "notes.create", "create": "notes.create", "append": "notes.append",
            "calendar": "calendar.createEvent", "reminders": "reminders.create", "messages": "messages.compose",
            "mail": "mail.compose", "call": "phone.call", "facetime": "phone.call", "link": "url.open",
            "browser": "url.open", "copy": "clipboard.copy", "clipboard": "clipboard.copy", "insert": "text.insert",
            "paste": "text.insert", "direct insert": "text.insertDirect", "type": "text.insertDirect",
            "timer": "clock.timer", "maps": "maps.search", "music": "music.play",
        ]
        XCTAssertEqual(BuiltInActions.keywords, read)
        for (word, type) in read {
            XCTAssertEqual(OutlineCompiler.knownType(word.uppercased()), type, word)
            XCTAssertEqual(OutlineCompiler.role(of: .word(word), inheritedType: nil, inheritedApp: nil, listNames: [],
                                                locateApp: { _ in nil }), .actionType(type), word)
        }
        XCTAssertEqual(OutlineCompiler.knownType("music.play"), "music.play", "by its full name")
        XCTAssertNil(OutlineCompiler.knownType("teleport"))

        let written: [String: String] = [
            "notes.create": "Notes", "notes.append": "append", "calendar.createEvent": "Calendar",
            "reminders.create": "Reminders", "messages.compose": "Messages", "mail.compose": "Mail", "phone.call": "Call",
            "url.open": "Link", "clipboard.copy": "Copy", "text.insert": "Insert", "text.insertDirect": "Direct Insert",
            "clock.timer": "Timer", "maps.search": "Maps", "music.play": "Music",
        ]
        for type in BuiltInActions.types.map(\.type) {
            XCTAssertEqual(OutlineDocument.keyword(for: type), written[type], type)
        }
    }

    func testFieldsAndTheirKinds() {
        XCTAssertEqual(BuiltInActions.fields, [
            "type", "folder", "title", "template", "account", "entry", "createIfMissing",
            "find.byName", "guards.maxBodyBytes", "guards.refuseInlineImages",
            "start", "duration", "alertMinutes", "calendar", "calendarId", "notes", "show",
            "due", "list", "to", "body", "subject",
            "app", "bundleId", "open", "url", "target", "name", "input", "via", "text",
            "shortcut", "query", "playlist", "album", "artist", "shuffle", "instant", "format",
        ])
        XCTAssertTrue(OutlineCompiler.isNumericField("alertMinutes", type: "calendar.createEvent"))
        XCTAssertTrue(OutlineCompiler.isNumericField("guards.maxBodyBytes", type: "notes.append"))
        XCTAssertTrue(OutlineCompiler.isNumericField("alertMinutes", type: nil), "for any action")
        XCTAssertFalse(OutlineCompiler.isNumericField("duration", type: "calendar.createEvent"), "30m is text")
        XCTAssertTrue(OutlineCompiler.isBooleanField("show", type: "calendar.createEvent"))
        XCTAssertTrue(OutlineCompiler.isBooleanField("createIfMissing", type: "notes.append"))
        XCTAssertTrue(OutlineCompiler.isBooleanField("guards.refuseInlineImages", type: "notes.append"))
        XCTAssertTrue(OutlineCompiler.isBooleanField("shuffle", type: "music.play"))
        XCTAssertTrue(OutlineCompiler.isBooleanField("instant", type: "url.open"), "every action's")
        XCTAssertFalse(OutlineCompiler.isBooleanField("shuffle", type: "notes.create"))

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
        XCTAssertTrue(catalog.contains("- `phone.call`, phone call — `Call`, `FaceTime`"), catalog)
        XCTAssertTrue(catalog.contains("- `notes.create`, new note — `Notes`, `New`, `Create`"))
        XCTAssertTrue(catalog.contains("- `shortcut`, run a shortcut\n"))
    }
}
