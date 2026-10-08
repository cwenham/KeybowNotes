import Foundation

/// Trees drafted by Claude from what a person says they want their keypads
/// for: what it's told, how its outline is found in the reply, and how a
/// draft goes into the person's tree file. The asking itself is the app's,
/// through the Claude module.
public enum TreeDraft {
    /// What's drafted, and where it goes.
    public enum Scope: Equatable, Sendable {
        /// A keypad section of its own, with all its trees.
        case newKeypad(name: String, model: KeypadDevice.Model?)
        /// Every tree of a keypad that's there, replacing them: 0 is Default.
        case keypad(Int)
        /// One tree of a keypad, replacing it.
        case tree(TreeKind, keypad: Int)
    }

    /// What the person has, so the draft uses it rather than inventing.
    public struct Context: Equatable, Sendable {
        /// Their whole tree file, when they agree to send it.
        public var outline: String?
        /// "Keybow 2040, using the trees “Desk”".
        public var keypads: [String]
        public var apps: [String]
        public var shortcuts: [String]
        /// "light.desk_lamp — Desk lamp".
        public var homeEntities: [String]

        public init(outline: String? = nil, keypads: [String] = [], apps: [String] = [], shortcuts: [String] = [],
                    homeEntities: [String] = []) {
            self.outline = outline
            self.keypads = keypads
            self.apps = apps
            self.shortcuts = shortcuts
            self.homeEntities = homeEntities
        }
    }

    /// What Claude is told first: the guide, the language, and what's here.
    public static func system(guide: String, catalog: String) -> String {
        guide + "\n\n---\n\n" + catalog
    }

    /// What to draft, for whom, with what they have.
    public static func request(_ wanted: String, scope: Scope, document: OutlineDocument, context: Context) -> String {
        var parts: [String] = []
        parts.append("# What I'd like my keypads for\n\n" + wanted.trimmingCharacters(in: .whitespacesAndNewlines))
        let names = TreeControl.keypadNames(document)
        let task: String
        switch scope {
        case .newKeypad(let name, let model):
            task = "Draft all the trees for a new keypad section, “\(name)”" + (model.map { ", for a \($0.title)" } ?? "")
                + ". Write its trees as Default trees — the main tree's entries first, then `# row 2`, `# row 3`, "
                + "`# bottom` as you use them — without a `# keypad` heading: KeybowNotes puts them in the section."
        case .keypad(let index):
            task = "Draft all the trees for the keypad “\(names[min(index, names.count - 1)])”, replacing the ones it "
                + "has. Write them as Default trees — the main tree's entries first, then `# row 2`, `# row 3`, "
                + "`# bottom` as you use them — without a `# keypad` heading."
        case .tree(let tree, let index):
            let heading = tree == .main ? "no heading" : "the heading `# \(tree.name)`"
            task = "Draft the \(tree.name) tree of the keypad “\(names[min(index, names.count - 1)])”, "
                + "replacing the one it has. Write just that tree, with \(heading); "
                + "`[pages]` on its heading if it should be pages."
        }
        parts.append("# What to draft\n\n" + task + " Add `# list` sections it uses, and `# contacts` or `# projects` "
                     + "entries only with details I've given. Answer as the guide's *Designing in the app* says.")
        var have: [String] = []
        if !context.keypads.isEmpty { have.append("Keypads plugged in: " + context.keypads.joined(separator: "; ") + ".") }
        if !context.apps.isEmpty { have.append("Apps installed: " + context.apps.joined(separator: ", ") + ".") }
        if !context.shortcuts.isEmpty { have.append("Shortcuts: " + context.shortcuts.map { "“\($0)”" }.joined(separator: ", ") + ".") }
        if !context.homeEntities.isEmpty {
            have.append("Home Assistant entities, which `[Home, entity: …]` controls:\n"
                        + context.homeEntities.map { "- \($0)" }.joined(separator: "\n"))
        } else {
            have.append("Home Assistant isn't set up: don't use `[Home]`.")
        }
        parts.append("# What I have\n\n" + have.joined(separator: "\n\n"))
        if let outline = context.outline, !outline.isEmpty {
            parts.append("# My tree file as it is\n\nFor my contacts, projects and lists, and how I like things — "
                         + "not to copy unless it fits.\n\n```outline\n\(outline)\n```")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Asking again, with what the compiler found.
    public static func repair(_ wanted: String, scope: Scope, document: OutlineDocument, context: Context,
                              draft: String, mistakes: String) -> String {
        request(wanted, scope: scope, document: document, context: context)
            + "\n\n# Your last draft\n\n```outline\n\(draft)\n```\n\n# What KeybowNotes found in it\n\n\(mistakes)\n\n"
            + "Correct every mistake, and answer the same way: the whole outline, then a short note."
    }

    /// A turn of the conversation after the first: what the person says, with
    /// the draft as it stands — their own changes in the editor included.
    public static func followUp(_ said: String, current: String) -> String {
        """
        # The draft as it stands

        With any changes I've made to it by hand:

        ```outline
        \(current)
        ```

        # What I'd like

        \(said.trimmingCharacters(in: .whitespacesAndNewlines))

        If this changes the draft, answer as before: the whole outline in one block, then a short note. If I'm only \
        asking something, just answer — no outline.
        """
    }

    /// The drafted part of a document — a keypad's trees, or one tree — as
    /// outline text, with the lists the document has.
    public static func outline(of document: OutlineDocument, scope: Scope) -> String {
        var part = OutlineDocument()
        switch scope {
        case .newKeypad:
            return ""
        case .keypad(let index):
            for tree in TreeKind.allCases {
                part.setRoots(document.roots(tree, keypad: index), tree)
                if document.isPaged(tree, keypad: index) { part.pages.insert(tree) }
            }
        case .tree(let tree, let index):
            part.setRoots(document.roots(tree, keypad: index), tree)
            if document.isPaged(tree, keypad: index) { part.pages.insert(tree) }
        }
        part.lists = document.lists
        return OutlineWriter.text(part).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A reply kept in the conversation, its outline left out: only the
    /// newest draft goes with each turn, so a long conversation stays small.
    public static func withoutOutline(_ reply: String) -> String {
        var inside = false
        var lines: [String] = []
        for line in reply.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if !inside { lines.append("(an earlier draft, since changed)") }
                inside.toggle()
                continue
            }
            if !inside { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    /// Carries what was drafted in a working copy into the person's own file:
    /// the drafted keypad's or tree's trees, and the lists, contacts and
    /// projects the draft added. `asNewSection` adds the drafted keypad as a
    /// section of its own, under the name and model it has in the copy.
    @discardableResult
    public static func carry(from draft: OutlineDocument, original: OutlineDocument, scope: Scope,
                             asNewSection: Bool, into document: inout OutlineDocument) throws -> String {
        let target: Int
        let kinds: [TreeKind]
        var said: String
        switch scope {
        case .newKeypad:
            throw TreeControl.Problem("There's no draft yet.")
        case .keypad(let index):
            guard index <= draft.keypads.count else { throw TreeControl.Problem("The drafted keypad isn't there any more.") }
            kinds = TreeKind.allCases
            if asNewSection {
                var section = draft.keypads[index - 1]
                var name = section.name
                var number = 2
                while TreeControl.keypadNames(document).contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    name = "\(section.name) \(number)"
                    number += 1
                }
                section.name = name
                target = document.addKeypad(OutlineKeypad(name: name, annotations: section.annotations))
                said = "Added “\(name)” to your tree"
            } else {
                // The keypad of that name: indexes needn't match.
                target = try TreeControl.keypad(TreeControl.keypadNames(draft)[index], in: document)
                said = "Replaced the trees of “\(TreeControl.keypadNames(document)[target])”"
            }
            for kind in kinds {
                document.setRoots(draft.roots(kind, keypad: index), kind, keypad: target)
                let paged = draft.isPaged(kind, keypad: index)
                if document.isPaged(kind, keypad: target) != paged { try? document.setPages(paged, for: kind, keypad: target) }
            }
        case .tree(let tree, let index):
            target = try TreeControl.keypad(TreeControl.keypadNames(draft)[min(index, draft.keypads.count)], in: document)
            document.setRoots(draft.roots(tree, keypad: index), tree, keypad: target)
            let paged = draft.isPaged(tree, keypad: index)
            if document.isPaged(tree, keypad: target) != paged { try? document.setPages(paged, for: tree, keypad: target) }
            said = "Replaced the \(tree.name) tree of “\(TreeControl.keypadNames(document)[target])”"
        }
        // What the draft added, and the person's file hasn't.
        let lists = draft.lists.filter { list in
            !original.lists.contains { $0.name == list.name } && !document.lists.contains { $0.name == list.name }
        }
        document.lists += lists
        let contacts = draft.contacts.filter { entry in
            !original.contacts.contains { $0.name == entry.name } && !document.contacts.contains { $0.name == entry.name }
        }
        document.contacts += contacts
        let projects = draft.projects.filter { entry in
            !original.projects.contains { $0.name == entry.name } && !document.projects.contains { $0.name == entry.name }
        }
        document.projects += projects
        let added = [lists.isEmpty ? nil : "\(lists.count) list\(lists.count == 1 ? "" : "s")",
                     contacts.isEmpty ? nil : "\(contacts.count) contact\(contacts.count == 1 ? "" : "s")",
                     projects.isEmpty ? nil : "\(projects.count) project\(projects.count == 1 ? "" : "s")"].compactMap { $0 }
        return said + (added.isEmpty ? "." : ", with " + added.joinedAsList + ".")
    }

    /// The outline in a reply: its block marked `outline` — else its first
    /// fenced block — else nil.
    public static func outline(in reply: String) -> String? {
        var blocks: [(language: String, text: String)] = []
        var current: (language: String, lines: [String])?
        for line in reply.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = current {
                    blocks.append((open.language, open.lines.joined(separator: "\n")))
                    current = nil
                } else {
                    current = (String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased(), [])
                }
            } else {
                current?.lines.append(line)
            }
        }
        let chosen = blocks.first { $0.language == "outline" } ?? blocks.first
        return chosen.map { $0.text.trimmingCharacters(in: .newlines) }
    }

    /// What's said around the outline: the note.
    public static func note(in reply: String) -> String {
        var inside = false
        var lines: [String] = []
        for line in reply.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inside.toggle()
                continue
            }
            if !inside { lines.append(line) }
        }
        // Where the block was, one blank line.
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return text
    }

    /// Mistakes only — what must be fixed before it's used — or nil.
    public static func mistakes(_ draft: String) -> String? {
        let (document, problems) = OutlineParser.parse(draft)
        let compiled = OutlineCompiler.compile(document, locateApp: { _ in nil })
        var lines = problems.map { "line \($0.line): couldn't be read — \($0.message)" }
        lines += compiled.diagnostics.filter { $0.severity == .error }.map { "line \($0.line): \($0.message)" }
        if let error = compiled.configError { lines.append("doesn't compile: \(error)") }
        if document.trees.values.allSatisfy({ $0.allSatisfy { $0 == nil } }) && document.keypads.isEmpty {
            lines.append("there are no trees in it")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Puts a draft into the person's file: its trees where the scope says,
    /// its lists that aren't there already, and contacts and projects not
    /// already named. Says what it did.
    @discardableResult
    public static func apply(_ draft: String, scope: Scope, to document: inout OutlineDocument) throws -> String {
        let (drafted, problems) = OutlineParser.parse(draft)
        guard problems.isEmpty else { throw TreeControl.Problem("The draft has lines that can't be read: try again.") }
        // The draft's trees: its Default ones — or, written as a section after
        // all, that section's.
        var trees = drafted.trees
        var pages = drafted.pages
        if trees.values.allSatisfy({ $0.allSatisfy { $0 == nil } }), let section = drafted.keypads.first {
            trees = section.trees
            pages = section.pages
        }
        let target: Int
        let kinds: [TreeKind]
        switch scope {
        case .newKeypad(let name, let model):
            var unique = name
            var number = 2
            while TreeControl.keypadNames(document).contains(where: { $0.caseInsensitiveCompare(unique) == .orderedSame }) {
                unique = "\(name) \(number)"
                number += 1
            }
            target = document.addKeypad(OutlineKeypad(name: unique, annotations: model.map { [.word($0.title)] } ?? []))
            kinds = TreeKind.allCases
        case .keypad(let index):
            target = min(index, document.keypads.count)
            kinds = TreeKind.allCases
        case .tree(let tree, let index):
            target = min(index, document.keypads.count)
            kinds = [tree]
            // A draft of one tree may have written it under any heading.
            if trees[tree]?.allSatisfy({ $0 == nil }) ?? true,
               let only = trees.first(where: { !$0.value.allSatisfy { $0 == nil } }) {
                trees = [tree: only.value]
                pages = pages.contains(only.key) ? [tree] : []
            }
        }
        for kind in kinds {
            document.setRoots(trees[kind] ?? OutlineNode.emptyRow, kind, keypad: target)
            if document.isPaged(kind, keypad: target) != pages.contains(kind) {
                try? document.setPages(pages.contains(kind), for: kind, keypad: target)
            }
        }
        let lists = drafted.lists.filter { list in !document.lists.contains { $0.name == list.name } }
        document.lists += lists
        let contacts = drafted.contacts.filter { entry in !document.contacts.contains { $0.name == entry.name } }
        document.contacts += contacts
        let projects = drafted.projects.filter { entry in !document.projects.contains { $0.name == entry.name } }
        document.projects += projects

        let names = TreeControl.keypadNames(document)
        var said = "Put the draft in “\(names[target])”"
        if case .tree(let tree, _) = scope { said = "Put the draft in the \(tree.name) tree of “\(names[target])”" }
        let added = [lists.isEmpty ? nil : "\(lists.count) list\(lists.count == 1 ? "" : "s")",
                     contacts.isEmpty ? nil : "\(contacts.count) contact\(contacts.count == 1 ? "" : "s")",
                     projects.isEmpty ? nil : "\(projects.count) project\(projects.count == 1 ? "" : "s")"].compactMap { $0 }
        return said + (added.isEmpty ? "." : ", with " + added.joinedAsList + ".")
    }
}
