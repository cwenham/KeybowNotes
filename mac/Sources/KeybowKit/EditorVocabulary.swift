import Foundation

/// The outline language's words for other editors — the VS Code extension's
/// completion and highlighting: every action type with its keywords and
/// fields, every {{value}}, and the words a step's condition tests with. Read
/// from the same descriptions the tree editor uses, so the two agree.
/// `keybow vocabulary` prints it.
public enum EditorVocabulary {
    /// The vocabulary as a JSON object.
    public static func object(registry: ModuleRegistry = .shared) -> [String: Any] {
        let actions = registry.vocabulary.types.map { action -> [String: Any] in
            [
                "type": action.type,
                "title": action.title,
                "keywords": action.keywords,
                "takesText": action.takesText,
                "fields": action.fields.map(field),
            ]
        }
        let values = ValueCatalog(registry: registry).entries.map(value)
        return [
            "actions": actions,
            "values": values,
            "conditionOperators": StepTest.spellings.map(\.0),
        ]
    }

    /// The vocabulary as JSON text, keys sorted so it changes only when the
    /// language does.
    public static func json(registry: ModuleRegistry = .shared) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object(registry: registry),
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func field(_ field: ModuleField) -> [String: Any] {
        var object: [String: Any] = ["key": field.key, "title": field.title, "help": field.help]
        if !field.hint.isEmpty { object["hint"] = field.hint }
        switch field.kind {
        case .text: object["kind"] = "text"
        case .number: object["kind"] = "number"
        case .flag: object["kind"] = "flag"
        case .action: object["kind"] = "action"
        case .colour: object["kind"] = "colour"
        case .choice(let words):
            object["kind"] = "choice"
            object["choices"] = words
        }
        return object
    }

    private static func value(_ entry: ValueEntry) -> [String: Any] {
        var object: [String: Any] = [
            "name": entry.name, "title": entry.title, "help": entry.help, "example": entry.example,
            "group": entry.group, "insertion": entry.insertion,
        ]
        switch entry.kind {
        case .value: object["kind"] = "value"
        case .call: object["kind"] = "call"
        case .block: object["kind"] = "block"
        }
        if !entry.sample.isEmpty { object["sample"] = entry.sample }
        if entry.fetched { object["fetched"] = true }
        if !entry.attributes.isEmpty {
            object["attributes"] = entry.attributes.map { attribute -> [String: Any] in
                var object: [String: Any] = ["name": attribute.name, "help": attribute.help]
                if !attribute.example.isEmpty { object["example"] = attribute.example }
                if !attribute.choices.isEmpty { object["choices"] = attribute.choices }
                if attribute.required { object["required"] = true }
                return object
            }
        }
        if !entry.formats.isEmpty {
            object["formats"] = entry.formats.map { ["pattern": $0.pattern, "sample": $0.sample] }
        }
        return object
    }
}
