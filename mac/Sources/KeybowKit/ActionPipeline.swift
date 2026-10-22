import Foundation

/// What a key's action shows as it goes: the overlay, in the app.
@MainActor
public protocol ActionShowing: AnyObject {
    /// A dry run: what it would have done.
    func showPreview(_ summary: ActionSummary, path: String)
    /// Why it won't run.
    func showRefused(_ reason: String, summary: ActionSummary)
    /// Waiting on values or replies, with a timer and a way out.
    func showWorking(_ summary: ActionSummary, path: String, title: String, cancel: @escaping () -> Void)
    func updateWorking(title: String)
    func endWorking()
    /// Cancelled while it waited.
    func showCancelled()
    func showRunning(_ summary: ActionSummary, path: String)
    func showFinished(_ outcome: ActionOutcome, summary: ActionSummary, warnings: [String])
    /// Nothing to say: what it did is on the screen.
    func stepAside()
}

/// The selected text in the app in front, when an action asks for it.
public enum SelectionReading: Equatable, Sendable {
    case text(String)
    case nothingSelected
    /// This app hasn't Accessibility access to read it.
    case notAllowed
}

/// What happens between a key's press and its action: the values it
/// fetches, the replies its blocks ask for, the selected text it reads, and
/// the checks that refuse it — then the action itself, and the one its
/// outcome runs next. What it shows goes to `display`; what it needs of the
/// Mac comes through `Surroundings`, so it runs the same with stand-ins.
///
/// The system log is kept on disk and readable by any admin, so the selected
/// text, the clipboard and anything copied or typed stay out of what it logs.
@MainActor
public final class ActionPipeline {
    /// What it needs of the Mac.
    public struct Surroundings {
        /// {{clipboard}} and {{frontApp}}, as they are when the key's pressed.
        /// {{selection}} is read only when an action uses it.
        public var values: @MainActor () -> [String: String]
        /// An image or PDF on the clipboard, as {{clipboard}} gives it —
        /// read only when used, since it's scaled to size first.
        public var clipboardMedia: @MainActor () -> String?
        /// The app in front: where text would be typed.
        public var frontmostApp: @MainActor () -> pid_t?
        /// The selected text, which can mean sending the app ⌘C.
        public var readSelection: @MainActor () async -> SelectionReading
        /// Whether this app may type into others.
        public var mayInsertText: @MainActor () -> Bool
        /// Asks for Accessibility access, for next time.
        public var askForAccessibility: @MainActor () -> Void
        public var putOnClipboard: @MainActor (String) -> Void
        /// The first event or reminder asks for access: brings that prompt
        /// forward, where it can be seen.
        public var bringPromptsForward: @MainActor (ActionPlan) -> Void
        /// Does it.
        public var run: @MainActor (ActionPlan) async -> ActionOutcome
        public var log: @MainActor (String) -> Void
        public var logError: @MainActor (String) -> Void

        public init(values: @escaping @MainActor () -> [String: String],
                    clipboardMedia: @escaping @MainActor () -> String?,
                    frontmostApp: @escaping @MainActor () -> pid_t?,
                    readSelection: @escaping @MainActor () async -> SelectionReading,
                    mayInsertText: @escaping @MainActor () -> Bool,
                    askForAccessibility: @escaping @MainActor () -> Void,
                    putOnClipboard: @escaping @MainActor (String) -> Void,
                    bringPromptsForward: @escaping @MainActor (ActionPlan) -> Void,
                    run: @escaping @MainActor (ActionPlan) async -> ActionOutcome,
                    log: @escaping @MainActor (String) -> Void,
                    logError: @escaping @MainActor (String) -> Void) {
            self.values = values
            self.clipboardMedia = clipboardMedia
            self.frontmostApp = frontmostApp
            self.readSelection = readSelection
            self.mayInsertText = mayInsertText
            self.askForAccessibility = askForAccessibility
            self.putOnClipboard = putOnClipboard
            self.bringPromptsForward = bringPromptsForward
            self.run = run
            self.log = log
            self.logError = logError
        }
    }

    /// How actions run, as Settings has it now.
    public struct Settings {
        public var dryRun: Bool
        public var templatesDirectory: URL?
        public var defaultCalendarID: String
        public var defaultReminderListID: String

        public init(dryRun: Bool = false, templatesDirectory: URL? = nil, defaultCalendarID: String = "",
                    defaultReminderListID: String = "") {
            self.dryRun = dryRun
            self.templatesDirectory = templatesDirectory
            self.defaultCalendarID = defaultCalendarID
            self.defaultReminderListID = defaultReminderListID
        }
    }

    private let display: ActionShowing
    private let surroundings: Surroundings
    private let registry: ModuleRegistry
    private let config: @MainActor () -> KeybowConfig
    private let settings: @MainActor () -> Settings
    /// Values being fetched and replies worked out for an action: one at a
    /// time, cancellable.
    private var pendingWork: Task<Void, Never>?
    /// Keys' steps under way, each running one after another.
    private var sequences: [UUID: Task<Void, Never>] = [:]
    /// For testing the Cancel button: pressed by itself after this long.
    public var cancelAfter: TimeInterval?

    public init(display: ActionShowing, surroundings: Surroundings, registry: ModuleRegistry = .shared,
                config: @escaping @MainActor () -> KeybowConfig,
                settings: @escaping @MainActor () -> Settings) {
        self.display = display
        self.surroundings = surroundings
        self.registry = registry
        self.config = config
        self.settings = settings
    }

    /// Whether it's waiting on values or replies.
    public var isWaiting: Bool { pendingWork != nil }

    /// Stops waiting, and runs nothing — nor any step still to come.
    public func cancel() {
        pendingWork?.cancel()
        for task in sequences.values { task.cancel() }
    }

    /// Runs a leaf's action. `chosenAt` is when the key was pressed: the
    /// action's "now", so a stopwatch starts on the press, not when the
    /// overlay has caught up. `values` join what the action can use: a
    /// display's `{{displayed}}`, for the action its OK runs. `report` hears
    /// how it went — for a script or an agent that asked — whichever way it
    /// ends.
    public func fire(_ selection: ResolvedSelection, chosenAt: Date = Date(), values: [String: String] = [:],
                     report: ((ActionOutcome) -> Void)? = nil) {
        guard selection.steps.isEmpty else {
            runSteps(selection, chosenAt: chosenAt, values: values, report: report)
            return
        }
        fireOne(selection, chosenAt: chosenAt, values: values, report: report)
    }

    /// One action, from its press to its outcome. As one of a key's steps,
    /// `done` hears how it ended — once, whichever way — and the overlay
    /// hears of a success at the end of the steps rather than now; `path`
    /// says which step it is, and `read` is the selection as already read.
    private func fireOne(_ selection: ResolvedSelection, chosenAt: Date = Date(), values: [String: String] = [:],
                         path shownPath: String? = nil, read: SelectionReading? = nil,
                         report: ((ActionOutcome) -> Void)? = nil, done: ((StepEnd) -> Void)? = nil) {
        let config = config()
        let settings = settings()
        let path = shownPath ?? selection.pathDescription
        func refuse(_ message: String) {
            display.showRefused(message, summary: ActionSummary(selection: selection, config: config, registry: registry))
            report?(.failure(message))
            done?(StepEnd(outcome: .failure(message), stop: .failed, shown: true))
        }

        if settings.dryRun {
            let summary = ActionSummary(selection: selection, config: config, registry: registry)
            display.showPreview(summary, path: path)
            let outcome = ActionOutcome.success("Dry run: nothing done", "It would: \(summary.verb) \(summary.subject)")
            report?(outcome)
            done?(StepEnd(outcome: outcome, shown: true))
            return
        }

        var environment = registry.values(now: Date())
        environment.merge(surroundings.values()) { _, mac in mac }
        var context = ActionContext(
            templatesDirectory: settings.templatesDirectory,
            now: chosenAt,
            environment: environment.merging(values) { _, given in given },
            defaultCalendarID: settings.defaultCalendarID,
            defaultReminderListID: settings.defaultReminderListID)

        // Blocks — {{#ai}} — are refused before anything is asked where a
        // reply could steer the action, and one lot at a time.
        let blockTexts: [String]
        do {
            blockTexts = try ActionPlanner.blockTexts(for: selection, context: context, vocabulary: registry.vocabulary)
        } catch {
            surroundings.log("  can't run: \(error)")
            refuse("\(error)")
            return
        }
        // Nor is a block sent what the person keeps from whoever replies —
        // the selection, from Claude — and nothing is read to find out.
        if let refusal = registry.refusal(forBlocksIn: blockTexts) {
            surroundings.log("  can't run: \(refusal)")
            refuse(refusal)
            return
        }
        // Values modules fetch — {{api.weather}} — and what they need first.
        let used = ActionPlanner.placeholders(for: selection, context: context, vocabulary: registry.vocabulary)
        // A value the tree gives itself — `location: Office` — isn't fetched.
        let given = ActionPlanner.values(for: selection, context: context)
        let fetchedNames = registry.fetchedNames(in: used).filter { given[$0] == nil }
        let needed = used.union(registry.valuesNeeded(toFetch: fetchedNames))
        if needed.contains("clipboard"), let media = surroundings.clipboardMedia() {
            context.environment["clipboard"] = media
        }
        let waits = !blockTexts.isEmpty || !fetchedNames.isEmpty
        if waits, pendingWork != nil {
            refuse("Still waiting on the last fetch or replies. Cancel it, or let it finish, then press again.")
            return
        }

        // A key's later steps use the selection as it was read for the first
        // that wanted it: typing replaces it.
        var selectionRead = read
        if case .text(let text)? = read, needed.contains("selection") { context.environment["selection"] = text }
        let needsSelection = needed.contains("selection") && read == nil
        guard needsSelection || waits else {
            run(selection, context: context, values: values, path: path, read: selectionRead, report: report, done: done)
            return
        }
        // The app to type into, if it comes to that: waiting leaves time to
        // switch to another.
        let frontApp = surroundings.frontmostApp()
        let work = Task { @MainActor in
            defer { if waits { self.pendingWork = nil } }
            if needsSelection {
                let reading = await surroundings.readSelection()
                switch reading {
                case .text(let text):
                    context.environment["selection"] = text
                    selectionRead = reading
                case .nothingSelected:
                    selectionRead = reading
                case .notAllowed:
                    surroundings.log("  can't run: no Accessibility access for {{selection}}")
                    refuse("KeybowNotes needs Accessibility access to read the selected text. "
                           + "Allow it in System Settings, then press again.")
                    surroundings.askForAccessibility()
                    return
                }
            }
            if waits {
                guard let prepared = await prepare(fetchedNames, blockTexts, selection: selection, context: context,
                                                   config: config, path: path) else {
                    let message = "It didn't run: cancelled, or what it needed couldn't be had — the overlay said which."
                    report?(.failure(message))
                    done?(StepEnd(outcome: .failure(message), stop: Task.isCancelled ? .cancelled : .failed, shown: true))
                    return
                }
                context = prepared
            }
            run(selection, context: context, values: values, typingInto: waits ? frontApp : nil, path: path,
                read: selectionRead, report: report, done: done)
        }
        if waits { pendingWork = work }
    }

    /// Fetches the values the action uses, then works out its blocks —
    /// innermost first, those that can go together at once — with a timer
    /// and a Cancel button on the overlay. Nil if cancelled or refused,
    /// having said so.
    private func prepare(_ fetchedNames: [String], _ texts: [String], selection: ResolvedSelection,
                         context: ActionContext, config: KeybowConfig, path: String) async -> ActionContext? {
        var context = context
        let summary = ActionSummary(selection: selection, config: config, environment: context.environment, registry: registry)
        let askers = Set(texts.flatMap(TemplateBlocks.names(in:)).compactMap { name in
            registry.module(handlingBlock: name)?.manifest.blocks.first { $0.name == name }?.title
        })
        let askTitle = askers.count == 1 ? "Asking \(askers.first!)…" : "Waiting for replies…"
        let fetchTitle = "Fetching " + registry.fetchSubject(for: fetchedNames,
                                                            given: ActionPlanner.values(for: selection, context: context)) + "…"
        // Shown only if the wait lasts: a quote from a file, or a kept
        // response, is there before it would be seen.
        let title = WaitTitle(fetchedNames.isEmpty ? askTitle : fetchTitle)
        let showing = Task { @MainActor [weak self, display] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            display.showWorking(summary, path: path, title: title.text) { self?.cancel() }
        }
        defer {
            showing.cancel()
            display.endWorking()
        }
        if let after = cancelAfter {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(after))
                self?.cancel()
            }
        }

        let started = Date()
        do {
            if !fetchedNames.isEmpty {
                let rows = ActionPlanner.listSources(for: selection, context: context, vocabulary: registry.vocabulary)
                let values = try await registry.fetch(fetchedNames, params: ActionPlanner.values(for: selection, context: context),
                                                      now: context.now, rows: rows)
                context.environment.merge(values) { _, fetched in fetched }
                surroundings.log(String(format: "  fetched %d value%@ in %.1fs", values.count, values.count == 1 ? "" : "s",
                                        Date().timeIntervalSince(started)))
            }
            if !texts.isEmpty {
                title.text = askTitle
                display.updateWorking(title: askTitle)
                let registry = registry
                let replies = try await TemplateBlocks.resolve(
                    texts, params: ActionPlanner.values(for: selection, context: context),
                    now: context.now, calendar: context.calendar) { call in
                    try await registry.reply(to: call)
                }
                surroundings.log(String(format: "  %d repl%@ in %.1fs", replies.count, replies.count == 1 ? "y" : "ies",
                                        Date().timeIntervalSince(started)))
                context.blockReplies = replies
            }
            return context
        } catch is CancellationError {
            surroundings.log("  cancelled while waiting")
            display.showCancelled()
        } catch let error as ModuleError {
            // Only the headline is logged: the detail can quote a server, and
            // a server can quote back what it was sent — the selection, say.
            surroundings.logError("  FAILED while waiting: \(error.message)")
            display.showFinished(.failure(error.message, error.detail), summary: summary, warnings: [])
        } catch {
            surroundings.logError("  FAILED while waiting: \(error)")
            display.showRefused("\(error)", summary: summary)
        }
        return nil
    }

    private func run(_ selection: ResolvedSelection, context: ActionContext, values: [String: String],
                     typingInto frontApp: pid_t? = nil, path: String, read: SelectionReading?,
                     report: ((ActionOutcome) -> Void)?, done: ((StepEnd) -> Void)?) {
        let config = config()
        let summary = ActionSummary(selection: selection, config: config, environment: context.environment, registry: registry)
        func refuse(_ message: String) {
            display.showRefused(message, summary: summary)
            report?(.failure(message))
            done?(StepEnd(outcome: .failure(message), stop: .failed, shown: true))
        }

        var isPrivate = !ActionPlanner.placeholders(for: selection, context: context, vocabulary: registry.vocabulary)
            .isDisjoint(with: ["selection", "clipboard", "displayed", "answer"])

        let planned: PlannedAction
        do {
            planned = try ActionPlanner.plan(selection, config: config, context: context, registry: registry)
        } catch {
            surroundings.log("  can't run: \(isPrivate ? "(details not logged)" : "\(error)")")
            refuse("\(error)")
            return
        }
        // Inserting text into another app needs Accessibility access.
        var inserted: String?
        switch planned.plan {
        case .copyToClipboard:
            isPrivate = true
        case .insertText(let text, _), .insertTextDirectly(let text, _):
            isPrivate = true
            inserted = text
        default:
            break
        }
        if inserted != nil, !surroundings.mayInsertText() {
            surroundings.log("  can't run: no Accessibility access for inserting text")
            refuse("KeybowNotes needs Accessibility access to type into other apps. "
                   + "Allow it in System Settings, then press again.")
            surroundings.askForAccessibility()
            return
        }
        // Switched apps while waiting on replies: don't type into the wrong one.
        if let inserted, let frontApp, surroundings.frontmostApp() != frontApp {
            surroundings.putOnClipboard(inserted)
            surroundings.log("  not inserted: the app in front changed while waiting")
            refuse("You switched apps while waiting, so the text wasn't typed in. It's on the clipboard instead.")
            return
        }

        surroundings.bringPromptsForward(planned.plan)
        display.showRunning(summary, path: path)
        Task { @MainActor [isPrivate] in
            let started = Date()
            let outcome = await surroundings.run(planned.plan)
            let seconds = String(format: "%.1fs", Date().timeIntervalSince(started))
            let line = "  \(outcome.succeeded ? "done" : "FAILED") in \(seconds)"
                + (isPrivate ? " (details not logged)" : ": \(outcome.message)" + (outcome.detail.map { " — \($0)" } ?? ""))
            outcome.succeeded ? surroundings.log(line) : surroundings.logError(line)
            for warning in planned.warnings where !isPrivate { surroundings.log("  warning: \(warning)") }
            report?(outcome)
            if let next = outcome.followUp {
                // OK's or Cancel's own action is part of this one: the steps
                // after it wait for it, and see what was typed or shown.
                let given = values.merging(outcome.values) { _, now in now }
                follow(next, of: selection, values: given, text: outcome.followUpText, path: path, read: read,
                       done: done.map { done in { end in
                           var end = end
                           end.values = outcome.values.merging(end.values) { _, later in later }
                           if next == "cancel", end.stop == nil { end.stop = .declined }
                           done(end)
                       } })
            } else if let done {
                done(StepEnd(outcome: outcome, values: outcome.values, selection: read, warnings: planned.warnings,
                             summary: summary, stop: outcome.succeeded ? nil : .failed))
            } else if !outcome.isQuiet {
                display.showFinished(outcome, summary: summary, warnings: planned.warnings)
            } else {
                display.stepAside()
            }
        }
    }

    /// Runs the node's own `ok` or `cancel` action, as though its key had just
    /// been pressed — or nothing, when it has none.
    private func follow(_ key: String, of selection: ResolvedSelection, values: [String: String], text: String?,
                        path: String, read: SelectionReading?, done: ((StepEnd) -> Void)?) {
        guard let next = selection.action?.nestedAction(key) else {
            done?(StepEnd(outcome: .quiet, selection: read))
            return
        }
        surroundings.log("  then \(key): \(next.type)")
        var fields = next.fields
        // Copy, Insert and the like, given no text: what was shown, or typed.
        if fields["text"] == nil, fields["template"] == nil, let text { fields["text"] = .string(text) }
        fireOne(selection.with(action: ActionSpec(type: next.type, fields: fields)), values: values, path: path,
                read: read, done: done)
    }

    // MARK: - Steps

    /// A key's steps, one after another: each waits for the one before to
    /// finish — an Ask for its answer, a display for its button — and sees
    /// what it gave. One that fails, is refused or is cancelled stops the
    /// rest. The overlay shows each as it runs, and how they went at the end.
    private func runSteps(_ selection: ResolvedSelection, chosenAt: Date, values: [String: String],
                          report: ((ActionOutcome) -> Void)?) {
        let config = config()
        if settings().dryRun {
            let summary = ActionSummary(selection: selection, config: config, registry: registry)
            display.showPreview(summary, path: selection.pathDescription)
            let each = Self.describe(selection.steps) { step in
                let summary = ActionSummary(selection: selection.doing(step), config: config, registry: registry)
                return "\(summary.verb) \(summary.subject)"
            }
            report?(.success("Dry run: nothing done", "It would: " + each))
            return
        }
        let id = UUID()
        let run = StepRun(values: values, chosenAt: chosenAt)
        let task = Task { @MainActor [weak self] in
            await self?.perform(selection.steps, of: selection, run: run)
            self?.sequences[id] = nil
            self?.finish(run, of: selection, report: report)
        }
        sequences[id] = task
    }

    /// "Copy “Hello”, then if {{answer}} is yes: Show …" — for a dry run.
    static func describe(_ steps: [ResolvedStep], _ action: (ResolvedStep) -> String) -> String {
        steps.map { step in
            switch step.kind {
            case .action: return action(step)
            case .condition(let condition):
                let inner = describe(step.steps, action)
                return condition.label.prefix(1).lowercased() + condition.label.dropFirst() + ": " + (inner.isEmpty ? "nothing" : inner)
            }
        }.joined(separator: ", then ")
    }

    private func perform(_ steps: [ResolvedStep], of selection: ResolvedSelection, run: StepRun) async {
        // Whether the If before has had a branch taken: nil outside a chain.
        var taken: Bool?
        for step in steps {
            if Task.isCancelled, run.stop == nil { run.stop = .cancelled }
            guard run.stop == nil else { return }
            switch step.kind {
            case .action:
                taken = nil
                run.number += 1
                let label = step.label.isEmpty ? "step \(run.number)" : step.label
                surroundings.log("  step \(run.number): \(step.action.type)")
                let now = run.number == 1 ? run.chosenAt : Date()
                let end = await withCheckedContinuation { continuation in
                    fireOne(selection.doing(step), chosenAt: now, values: run.values,
                            path: selection.pathDescription + " · " + label, read: run.selection,
                            done: { end in continuation.resume(returning: end) })
                }
                run.ended(end, number: run.number)
            case .condition(let condition):
                let holds: Bool
                switch condition.branch {
                case .ifTrue:
                    holds = await self.holds(condition, step, of: selection, run: run)
                    taken = holds
                case .elseIf:
                    guard taken == false else { continue }
                    holds = await self.holds(condition, step, of: selection, run: run)
                    taken = holds
                case .otherwise:
                    holds = taken == false
                    taken = nil
                }
                guard run.stop == nil else { return }
                surroundings.log("  \(condition.branch == .otherwise ? "else" : "if"): \(holds ? "yes" : "no")")
                if holds { await perform(step.steps, of: selection, run: run) }
            }
        }
    }

    /// Whether a condition holds, now: its values are those of the steps
    /// before it, the key's, and what's selected, copied or fetched.
    private func holds(_ condition: StepCondition, _ step: ResolvedStep, of selection: ResolvedSelection,
                       run: StepRun) async -> Bool {
        guard let test = condition.test else { return true }
        var values = registry.values(now: Date())
        values.merge(surroundings.values()) { _, mac in mac }
        values.merge(run.values) { _, given in given }
        let names = Template.names(in: test.left).union(Template.names(in: test.right))
        if names.contains("selection") {
            if run.selection == nil {
                let reading = await surroundings.readSelection()
                if reading == .notAllowed {
                    surroundings.askForAccessibility()
                    display.showRefused("KeybowNotes needs Accessibility access to read the selected text. "
                                        + "Allow it in System Settings, then press again.",
                                        summary: ActionSummary(selection: selection.doing(step), config: config(),
                                                               registry: registry))
                    run.stop = .failed
                    run.shown = true
                    return false
                }
                run.selection = reading
            }
            if case .text(let text)? = run.selection { values["selection"] = text }
        }
        values.merge(step.params) { _, fromTree in fromTree }
        let fetched = registry.fetchedNames(in: names).filter { values[$0] == nil }
        if !fetched.isEmpty {
            do {
                let found = try await registry.fetch(fetched, params: values, now: Date())
                values.merge(found) { _, fetched in fetched }
            } catch {
                let message = (error as? ModuleError)?.message ?? "\(error)"
                surroundings.logError("  FAILED while fetching for a condition: \(message)")
                display.showFinished(.failure(message, (error as? ModuleError)?.detail),
                                     summary: ActionSummary(selection: selection.doing(step), config: config(),
                                                            registry: registry),
                                     warnings: ["“\(condition.label)” couldn't be tested, so the steps after it didn't run."])
                run.stop = .failed
                run.shown = true
                return false
            }
        }
        let now = Date()
        return test.holds { Template.expand($0, params: values, now: now).text }
    }

    /// What the overlay says once the steps are over, and what `report` hears.
    private func finish(_ run: StepRun, of selection: ResolvedSelection, report: ((ActionOutcome) -> Void)?) {
        let ends = run.ends
        switch run.stop {
        case .cancelled?:
            if !run.shown { display.showCancelled() }
            report?(.failure("Cancelled", ends.isEmpty ? nil : "after \(ends.count) of its steps"))
            return
        case .declined?:
            // Cancel on an Ask or a display: nothing more to say — unless
            // its own Cancel action did something.
            if let last = ends.last, !last.end.outcome.isQuiet, let summary = last.end.summary {
                display.showFinished(last.end.outcome, summary: summary, warnings: last.end.warnings)
            } else {
                display.stepAside()
            }
            report?(.success("Stopped at Cancel", "after \(ends.count) of its steps"))
            return
        case .failed?:
            guard let last = ends.last else {
                report?(.failure("It didn't run: the overlay said why."))
                return
            }
            if !last.end.shown, let summary = last.end.summary {
                display.showFinished(last.end.outcome, summary: summary,
                                     warnings: last.end.warnings + ["Stopped at step \(last.number): nothing after it ran."])
            }
            report?(last.end.outcome)
            return
        case nil:
            break
        }
        let said = ends.filter { !$0.end.outcome.isQuiet }
        let warnings = ends.flatMap(\.end.warnings)
        guard let last = said.last, let summary = last.end.summary else {
            display.stepAside()
            report?(.success("Done", ends.count == 1 ? "1 step" : "\(ends.count) steps"))
            return
        }
        if ends.count == 1 {
            display.showFinished(last.end.outcome, summary: summary, warnings: warnings)
            report?(last.end.outcome)
            return
        }
        let earlier = said.dropLast().map(\.end.outcome.message)
        let outcome = ActionOutcome.success(last.end.outcome.message,
                                            earlier.isEmpty ? last.end.outcome.detail : earlier.joined(separator: " · "))
        display.showFinished(outcome, summary: summary.titled("\(ends.count) steps"), warnings: warnings)
        report?(outcome)
    }
}

/// How one of a key's steps ended, for those after it.
struct StepEnd {
    enum Stop {
        /// It failed, or was refused.
        case failed
        /// Cancel was chosen on an Ask or a display.
        case declined
        /// The waiting was cancelled — the overlay's button, the menu's.
        case cancelled
    }

    var outcome: ActionOutcome
    /// What it gives the steps after it: `{{answer}}`, `{{displayed}}`.
    var values: [String: String] = [:]
    /// The selection, as read for it.
    var selection: SelectionReading?
    var warnings: [String] = []
    /// What ran, for the overlay.
    var summary: ActionSummary?
    var stop: Stop?
    /// Already on the overlay: a refusal, a cancellation.
    var shown = false
}

/// Where a key's steps have got to.
@MainActor
private final class StepRun {
    var values: [String: String]
    let chosenAt: Date
    var selection: SelectionReading?
    var number = 0
    var ends: [(number: Int, end: StepEnd)] = []
    var stop: StepEnd.Stop?
    var shown = false

    init(values: [String: String], chosenAt: Date) {
        self.values = values
        self.chosenAt = chosenAt
    }

    func ended(_ end: StepEnd, number: Int) {
        ends.append((number, end))
        values.merge(end.values) { _, later in later }
        if let reading = end.selection, reading != .notAllowed { selection = reading }
        if let stop = end.stop {
            self.stop = stop
            shown = end.shown
        }
    }
}

/// What the wait is for, as it changes: read when the overlay shows it.
@MainActor
private final class WaitTitle {
    var text: String
    init(_ text: String) { self.text = text }
}
