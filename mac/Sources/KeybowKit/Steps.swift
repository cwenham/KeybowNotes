import Foundation

// Steps: more than one action for a key. Bulleted items under a key are its
// steps, run one after another when it's chosen, each inheriting from the key
// as a key inherits from its branch. A step with steps under it is a
// condition — `If {{answer}} is yes`, `Else if …`, `Else` — whose steps run
// only when it holds. See docs/CONFIG-LANGUAGE.md, "Steps".
//
//     1. Jot [Ask, text: "What's on your mind?"]
//        - Ask                                   ← runs the key's own action
//        - If {{answer}} contains tomorrow
//           - [Reminders, title: "{{answer}}", due: tomorrow]
//        - Else
//           - [append, find.byName: Inbox, entry: "{{answer}}"]

// MARK: - Conditions

/// What a condition step says: which branch of an If it is, and its test.
public struct StepCondition: Equatable, Sendable {
    public enum Branch: Equatable, Sendable {
        /// `If …`: starts a chain.
        case ifTrue
        /// `Else if …`: when nothing before it in the chain held.
        case elseIf
        /// `Else`, `Otherwise`: when nothing before it held.
        case otherwise
    }

    public let branch: Branch
    /// Nil for `Else`.
    public let test: StepTest?

    public init(branch: Branch, test: StepTest?) {
        self.branch = branch
        self.test = test
    }

    /// Reads a step's label. Nil when it isn't a condition — it doesn't begin
    /// `If`, `Else` or `Otherwise` — and a failure, with what's wrong, when
    /// it begins like one but can't be read.
    public static func parse(_ label: String) -> Result<StepCondition, StepConditionError>? {
        var text = label.trimmingCharacters(in: .whitespaces)
        // "If it rains:" reads as "If it rains".
        if text.hasSuffix(":") { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
        let lower = text.lowercased()

        if ["else", "otherwise"].contains(lower) { return .success(StepCondition(branch: .otherwise, test: nil)) }
        for prefix in ["else if ", "otherwise if ", "elif "] where lower.hasPrefix(prefix) {
            return test(String(text.dropFirst(prefix.count))).map { StepCondition(branch: .elseIf, test: $0) }
        }
        if lower.hasPrefix("if ") {
            return test(String(text.dropFirst(3))).map { StepCondition(branch: .ifTrue, test: $0) }
        }
        if lower == "if" || lower == "else if" || lower == "otherwise if" { return .failure(.nothingToTest) }
        if lower.hasPrefix("else ") || lower.hasPrefix("otherwise ") { return .failure(.elseTakesNothing) }
        return nil
    }

    private static func test(_ text: String) -> Result<StepTest, StepConditionError> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(.nothingToTest) }
        if TemplateBlocks.contains(trimmed), let block = TemplateBlocks.names(in: trimmed).first {
            return .failure(.block(block))
        }
        return StepTest.parse(trimmed)
    }

    /// How it's written, as a step's label: `If {{answer}} is yes`.
    public var label: String {
        switch branch {
        case .ifTrue: return "If " + (test?.text ?? "")
        case .elseIf: return "Else if " + (test?.text ?? "")
        case .otherwise: return "Else"
        }
    }
}

public enum StepConditionError: Error, Equatable, Sendable, CustomStringConvertible {
    case nothingToTest
    case elseTakesNothing
    case missingSide(String)
    case block(String)

    public var description: String {
        switch self {
        case .nothingToTest:
            return "An If needs something to test: “If {{answer}} is yes”, or “If {{selection}}” for anything there."
        case .elseTakesNothing:
            return "Else stands alone; for another test, write “Else if …”."
        case .missingSide(let word):
            return "“\(word)” needs something on each side: “{{answer}} \(word) yes”."
        case .block(let name):
            return "{{#\(name)}} can't go in a condition: a reply mustn't decide what runs."
        }
    }
}

/// A condition's test: a value, and what it's compared with.
public struct StepTest: Equatable, Sendable {
    public enum Operator: String, CaseIterable, Sendable {
        /// `If {{answer}}`: there's something there.
        case truthy
        case equals, notEquals
        case contains, notContains
        case startsWith, endsWith
        case greater, less, greaterOrEqual, lessOrEqual
        case empty, notEmpty
    }

    /// The text on the left, its {{values}} not yet filled in; quotes taken off.
    public let left: String
    public let op: Operator
    /// The text on the right; empty for a test with one side.
    public let right: String
    /// As written.
    public let text: String

    public init(left: String, op: Operator, right: String = "", text: String? = nil) {
        self.left = left
        self.op = op
        self.right = right
        self.text = text ?? left
    }

    /// The words and signs, longest first, so `is not` is found before `is`.
    /// Words need a space on each side.
    private static let spellings: [(String, Operator)] = [
        ("does not contain", .notContains), ("doesn't contain", .notContains), ("doesn’t contain", .notContains),
        ("is not empty", .notEmpty), ("isn't empty", .notEmpty), ("isn’t empty", .notEmpty),
        ("is empty", .empty),
        ("starts with", .startsWith), ("begins with", .startsWith), ("ends with", .endsWith),
        ("contains", .contains), ("is not", .notEquals), ("isn't", .notEquals), ("isn’t", .notEquals),
        ("equals", .equals), ("is", .equals),
        ("==", .equals), ("!=", .notEquals), (">=", .greaterOrEqual), ("<=", .lessOrEqual),
        ("=", .equals), (">", .greater), ("<", .less),
    ]

    /// Reads `{{answer}} is yes`. The first word or sign outside quotes and
    /// `{{…}}` splits it; with none, it's a test that something's there.
    public static func parse(_ text: String) -> Result<StepTest, StepConditionError> {
        let characters = Array(text)
        let lowered = Array(text.lowercased())
        var depth = 0
        var quote: Character?
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == closing(open) { quote = nil }
                index += 1
                continue
            }
            if character == "{", index + 1 < characters.count, characters[index + 1] == "{" {
                depth += 1
                index += 2
                continue
            }
            if character == "}", depth > 0, index + 1 < characters.count, characters[index + 1] == "}" {
                depth -= 1
                index += 2
                continue
            }
            if depth == 0, closing(character) != nil, startsQuote(at: index, in: characters) {
                quote = character
                index += 1
                continue
            }
            if depth == 0, let (spelling, op) = operatorAt(index, in: lowered) {
                let left = String(characters[..<index]).trimmingCharacters(in: .whitespaces)
                let rest = String(characters[(index + spelling.count)...]).trimmingCharacters(in: .whitespaces)
                if op == .empty || op == .notEmpty {
                    // "is empty" ends the test; anything after makes it "is …".
                    if rest.isEmpty {
                        guard !left.isEmpty else { return .failure(.missingSide(spelling)) }
                        return .success(StepTest(left: unquoted(left), op: op, text: text))
                    }
                    index += 1
                    continue
                }
                guard !left.isEmpty, !rest.isEmpty else { return .failure(.missingSide(spelling)) }
                return .success(StepTest(left: unquoted(left), op: op, right: unquoted(rest), text: text))
            }
            index += 1
        }
        return .success(StepTest(left: unquoted(text), op: .truthy, text: text))
    }

    private static func closing(_ open: Character) -> Character? {
        switch open {
        case "\"": return "\""
        case "'": return "'"
        case "“": return "”"
        case "‘": return "’"
        default: return nil
        }
    }

    /// A quote that opens a value — at the start, or after a space — not an
    /// apostrophe inside a word: `Bob's`.
    private static func startsQuote(at index: Int, in characters: [Character]) -> Bool {
        index == 0 || characters[index - 1] == " "
    }

    private static func operatorAt(_ index: Int, in lowered: [Character]) -> (String, Operator)? {
        for (spelling, op) in spellings {
            let word = Array(spelling)
            guard index + word.count <= lowered.count, Array(lowered[index..<(index + word.count)]) == word else { continue }
            if spelling.first!.isLetter {
                // A word: a space before it and after it, or the end.
                guard index > 0, lowered[index - 1] == " " else { continue }
                let after = index + word.count
                guard after == lowered.count || lowered[after] == " " else { continue }
            }
            return (spelling, op)
        }
        return nil
    }

    /// `"yes please"` → `yes please`; quotes keep spaces at the ends, and let
    /// a value hold words like `is`.
    static func unquoted(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let close = closing(first), text.last == close else { return text }
        return String(text.dropFirst().dropLast())
    }

    /// Whether it holds, its {{values}} filled in by `expand`. Text is
    /// compared without regard to case or the spaces around it; numbers, as
    /// numbers.
    public func holds(_ expand: (String) -> String) -> Bool {
        let value = expand(left).trimmingCharacters(in: .whitespacesAndNewlines)
        let other = expand(right).trimmingCharacters(in: .whitespacesAndNewlines)
        let a = value.lowercased(), b = other.lowercased()
        let numbers = Self.number(value).flatMap { x in Self.number(other).map { (x, $0) } }
        switch op {
        case .truthy: return !["", "false", "no", "off", "0"].contains(a)
        case .empty: return value.isEmpty
        case .notEmpty: return !value.isEmpty
        case .equals: return numbers.map { $0 == $1 } ?? (a == b)
        case .notEquals: return !(numbers.map { $0 == $1 } ?? (a == b))
        case .contains: return a.contains(b)
        case .notContains: return !a.contains(b)
        case .startsWith: return a.hasPrefix(b)
        case .endsWith: return a.hasSuffix(b)
        case .greater: return numbers.map { $0 > $1 } ?? (a.localizedStandardCompare(b) == .orderedDescending)
        case .less: return numbers.map { $0 < $1 } ?? (a.localizedStandardCompare(b) == .orderedAscending)
        case .greaterOrEqual: return numbers.map { $0 >= $1 } ?? (a.localizedStandardCompare(b) != .orderedAscending)
        case .lessOrEqual: return numbers.map { $0 <= $1 } ?? (a.localizedStandardCompare(b) != .orderedDescending)
        }
    }

    /// `21`, `21.5`, `-3` — and `21°` or `21 %`, as a sensor gives it.
    static func number(_ text: String) -> Double? {
        if let plain = Double(text) { return plain }
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " °%"))
        return trimmed.isEmpty || trimmed == text ? nil : Double(trimmed)
    }
}

// MARK: - Steps in the outline

extension OutlineNode {
    /// What a step's label makes it: nil for an action, else its condition —
    /// or what's wrong with one.
    public var condition: Result<StepCondition, StepConditionError>? { StepCondition.parse(label) }

    /// Whether this step is a condition — If, Else if or Else — even one that
    /// can't be read.
    public var isCondition: Bool { condition != nil }

    /// Adds a step at the end of this key's steps — or, with `under`, of the
    /// steps of the step there — and says its place.
    @discardableResult
    mutating func appendStep(_ step: OutlineNode, under path: [Int]) -> Int {
        guard let first = path.first else {
            steps.append(step)
            return steps.count - 1
        }
        guard first < steps.count else { return 0 }
        return steps[first].appendStep(step, under: Array(path.dropFirst()))
    }

    /// The step at a path through this key's steps.
    public func step(at path: [Int]) -> OutlineNode? {
        guard let first = path.first, first >= 0, first < steps.count else { return nil }
        return path.count == 1 ? steps[first] : steps[first].step(at: Array(path.dropFirst()))
    }

    /// The list of steps a step at `path` sits in, changed.
    mutating func changeSteps(holding path: [Int], _ change: (inout [OutlineNode]) throws -> Void) rethrows {
        guard path.count > 1 else {
            try change(&steps)
            return
        }
        try steps[path[0]].changeSteps(holding: Array(path.dropFirst()), change)
    }

    /// Where a step is among this key's steps, by its ID.
    func stepPath(of id: UUID) -> [Int]? {
        for (index, step) in steps.enumerated() {
            if step.id == id { return [index] }
            if let inner = step.stepPath(of: id) { return [index] + inner }
        }
        return nil
    }

    /// Every step under it, at any depth, in order.
    public var allSteps: [OutlineNode] {
        steps.flatMap { [$0] + $0.allSteps }
    }
}

// MARK: - Steps resolved, for running

/// One of a chosen key's steps, with what it inherits worked out: an action
/// ready to plan, or a condition and the steps it guards.
public struct ResolvedStep: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case action
        case condition(StepCondition)
    }

    public let kind: Kind
    /// What the step is called; may be empty.
    public let label: String
    /// For an action, the action; for a condition, what its steps inherit.
    public let action: ActionSpec
    /// Values for templates: the key's, with the step's own and those of the
    /// conditions above it laid over.
    public let params: [String: String]
    /// A condition's steps.
    public let steps: [ResolvedStep]

    public init(kind: Kind, label: String, action: ActionSpec, params: [String: String], steps: [ResolvedStep] = []) {
        self.kind = kind
        self.label = label
        self.action = action
        self.params = params
        self.steps = steps
    }

    public var isAction: Bool { kind == .action }
}

extension Array where Element == ResolvedStep {
    /// The first action, looking into conditions: the step most likely first
    /// — what decides whether the key waits before running.
    public var firstAction: ResolvedStep? {
        for step in self {
            if step.isAction { return step }
            if let inner = step.steps.firstAction { return inner }
        }
        return nil
    }

    /// The step at a path through these steps.
    public func step(at path: [Int]) -> ResolvedStep? {
        guard let first = path.first, first >= 0, first < count else { return nil }
        return path.count == 1 ? self[first] : self[first].steps.step(at: [Int](path.dropFirst()))
    }

    /// How many actions, at any depth.
    public var actionCount: Int { actions.count }

    /// Every action, at any depth, in order.
    public var actions: [ResolvedStep] {
        flatMap { $0.isAction ? [$0] : $0.steps.actions }
    }
}

extension ResolvedSelection {
    /// The same choice, as one step of it: the step's action and values.
    public func doing(_ step: ResolvedStep) -> ResolvedSelection {
        ResolvedSelection(tree: tree, path: path, labels: labels, params: step.params, action: step.action, node: node)
    }

    /// The first step's selection, or this one when it has no steps.
    public var firstStep: ResolvedSelection {
        steps.firstAction.map(doing) ?? self
    }
}
