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

    /// Stops waiting, and runs nothing.
    public func cancel() {
        pendingWork?.cancel()
    }

    /// Runs a leaf's action. `chosenAt` is when the key was pressed: the
    /// action's "now", so a stopwatch starts on the press, not when the
    /// overlay has caught up. `values` join what the action can use: a
    /// display's `{{displayed}}`, for the action its OK runs. `report` hears
    /// how it went — for a script or an agent that asked — whichever way it
    /// ends.
    public func fire(_ selection: ResolvedSelection, chosenAt: Date = Date(), values: [String: String] = [:],
                     report: ((ActionOutcome) -> Void)? = nil) {
        let config = config()
        let settings = settings()
        let path = selection.pathDescription
        func refuse(_ message: String) {
            display.showRefused(message, summary: ActionSummary(selection: selection, config: config))
            report?(.failure(message))
        }

        if settings.dryRun {
            let summary = ActionSummary(selection: selection, config: config)
            display.showPreview(summary, path: path)
            report?(.success("Dry run: nothing done", "It would: \(summary.verb) \(summary.subject)"))
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
            blockTexts = try ActionPlanner.blockTexts(for: selection, context: context)
        } catch {
            surroundings.log("  can't run: \(error)")
            refuse("\(error)")
            return
        }
        // Values modules fetch — {{api.weather}} — and what they need first.
        let used = ActionPlanner.placeholders(for: selection, context: context)
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

        let needsSelection = needed.contains("selection")
        guard needsSelection || waits else {
            run(selection, context: context, report: report)
            return
        }
        // The app to type into, if it comes to that: waiting leaves time to
        // switch to another.
        let frontApp = surroundings.frontmostApp()
        let work = Task { @MainActor in
            defer { if waits { self.pendingWork = nil } }
            if needsSelection {
                switch await surroundings.readSelection() {
                case .text(let text):
                    context.environment["selection"] = text
                case .nothingSelected:
                    break
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
                                                   config: config) else {
                    report?(.failure("It didn't run: cancelled, or what it needed couldn't be had — the overlay said which."))
                    return
                }
                context = prepared
            }
            run(selection, context: context, typingInto: waits ? frontApp : nil, report: report)
        }
        if waits { pendingWork = work }
    }

    /// Fetches the values the action uses, then works out its blocks —
    /// innermost first, those that can go together at once — with a timer
    /// and a Cancel button on the overlay. Nil if cancelled or refused,
    /// having said so.
    private func prepare(_ fetchedNames: [String], _ texts: [String], selection: ResolvedSelection,
                         context: ActionContext, config: KeybowConfig) async -> ActionContext? {
        var context = context
        let summary = ActionSummary(selection: selection, config: config, environment: context.environment)
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
            display.showWorking(summary, path: selection.pathDescription, title: title.text) { self?.cancel() }
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
                let values = try await registry.fetch(fetchedNames, params: ActionPlanner.values(for: selection, context: context),
                                                      now: context.now)
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

    private func run(_ selection: ResolvedSelection, context: ActionContext, typingInto frontApp: pid_t? = nil,
                     report: ((ActionOutcome) -> Void)? = nil) {
        let config = config()
        let summary = ActionSummary(selection: selection, config: config, environment: context.environment)
        let path = selection.pathDescription
        func refuse(_ message: String) {
            display.showRefused(message, summary: summary)
            report?(.failure(message))
        }

        var isPrivate = !ActionPlanner.placeholders(for: selection, context: context)
            .isDisjoint(with: ["selection", "clipboard", "displayed", "answer"])

        let planned: PlannedAction
        do {
            planned = try ActionPlanner.plan(selection, config: config, context: context)
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
                follow(next, of: selection, values: outcome.values, text: outcome.followUpText)
            } else if !outcome.isQuiet {
                display.showFinished(outcome, summary: summary, warnings: planned.warnings)
            } else {
                display.stepAside()
            }
        }
    }

    /// Runs the node's own `ok` or `cancel` action, as though its key had just
    /// been pressed — or nothing, when it has none.
    private func follow(_ key: String, of selection: ResolvedSelection, values: [String: String], text: String?) {
        guard let next = selection.action?.nestedAction(key) else { return }
        surroundings.log("  then \(key): \(next.type)")
        var fields = next.fields
        // Copy, Insert and the like, given no text: what was shown, or typed.
        if fields["text"] == nil, fields["template"] == nil, let text { fields["text"] = .string(text) }
        fire(selection.with(action: ActionSpec(type: next.type, fields: fields)), values: values)
    }
}

/// What the wait is for, as it changes: read when the overlay shows it.
@MainActor
private final class WaitTitle {
    var text: String
    init(_ text: String) { self.text = text }
}
