# Modules

Some features are auxiliary: useful, but not what KeybowNotes is for. They
would usually be plugins. Rather than build a plugin system now, they're
**modules**: separate Swift targets written against one interface in
KeybowKit, and compiled in. The stopwatch is the first.

A module declares what it adds; the host — the app, or the `keybow` command
line — does the rest. A module never touches the Keybow, the overlay, the menu
bar or the outline directly.

## What a module can do

| | How |
|---|---|
| Add **action types**, with outline keywords and fields | `manifest.actionTypes` |
| Check an action before it runs, with a reason people can act on | `problem(with:)` |
| Run at once on the press, skipping the time to cancel | `firesAtOnce(_:)` |
| Say what a key will do, for the overlay and the tree editor | `summary(of:now:)` |
| **Run** its actions | `run(_:now:)` |
| Offer **{{placeholder}} values** to every action | `values(now:)` |
| Show what it's doing — on the overlay, in the menu bar, by pulsing keys | `status(now:)` |
| Offer **commands in the menu bar's menu**, for things no key has been set up to do | `menuItems(now:)` / `performMenuItem(_:now:)` |
| Keep **state** between runs of the app | `ModuleHost.load` / `save` |
| Put text on the **clipboard** | `ModuleHost.copy` |
| Reply to **template blocks** — `{{#ai}}…{{/ai}}` | `manifest.blocks`, `reply(to:)`, `standIn(for:)` |
| **Refuse a block** for what's written in it — a `{{selection}}` the person keeps from it — before anything is read | `refusal(forBlock:using:)` |
| **Fetch values** when an action needs them — `{{api.weather}}`, `{{quote file="q.md"}}` | `manifest.fetches`, `fetch(_:params:now:)`, `valuesNeeded(toFetch:)`, `standIn(forValue:)`, `fetchSubject(for:)` |
| Read files the tree names, beside its templates | `ModuleHost.templatesFolder` |
| Add **settings** to the Settings window — a page of its own — secrets kept in the Keychain | `manifest.settings`, `manifest.symbol`, `ModuleHost.setting` / `secret` |
| **Show something on screen** until it's dismissed, with OK and Cancel — and a field to type in | `ModuleHost.display(_:)`, `ModuleDisplay.Field` |
| Take a **template or text** whole, like Copy | `ModuleActionType.takesText` |
| Offer **choices for a field** in the tree editor — what's there to control, following the other fields | `ModuleField.offersChoices`, `choices(for:type:fields:)` |
| Show only the **fields that apply** to the action as it's set up | `shownFields(type:fields:)` |
| Take a **colour**, chosen in the editor with a colour picker | a field of kind `.colour` |
| Have the host **run a follow-up action** of the node's own — a display's OK | a field of kind `.action`; `ActionOutcome.then(_:values:)` |
| Keep secrets of its own making in the Keychain | `ModuleHost.setSecret` |
| Say its status changed on its own | `ModuleHost.statusChanged()` |

The interface is in `mac/Sources/KeybowKit/Modules.swift`.

## The pieces

```
KeybowKit            the module interface, the registry, and the core
KeybowStopwatch      a module: depends on KeybowKit only
KeybowAI             a module: {{#ai}} blocks, and Claude for other modules
KeybowData           a module: data sources, using KeybowAI to write rules
KeybowLocation       a module: where the Mac is, from Location Services
KeybowQuotes         a module: {{quote}}, portions of a file
KeybowDisplay        modules: the display and ask actions
KeybowWindows        modules: the window action, and Exposé
KeybowHome           a module: Home Assistant
KeybowModules        the list of built-in modules
KeybowNotesApp       registers them at launch; shows their status
keybow               registers them too, so their keywords compile
```

`BuiltInModules.registerAll(host:)` in `KeybowModules` is the one list. Adding
a module is a new target, a line there, and a dependency in `Package.swift`.

The action types built in — Notes, Calendar, Copy and the rest — are described
the same way, as `ModuleActionType`s with their fields, in `BuiltInActions` in
KeybowKit, so the compiler, the tree editor, the overlay and the agents'
catalog treat both alike.

What reads the outline is handed an `ActionVocabulary`: every type, built in
and the modules', by name and keyword, with its fields — a snapshot of a
registry, `registry.vocabulary`. The planner, the summary, the runner and the
pipeline are handed the registry itself. Each defaults to `ModuleRegistry.shared`,
which the app and the command line fill; a test hands them a registry of its
own, with only the modules it needs.

## How the host uses a module

- **Outline.** A module's keywords work like the built-in ones: `[Stopwatch]`
  names the `stopwatch` type, and its field keys are action fields, not
  template values. `flag` fields read `true`/`false`, `number` fields numbers.
  The tree editor lists its types in the Type menu and shows its fields —
  a `choice` field as a menu — with each field's `help` as its tooltip: what
  it does, what can go in it, and an example.
- **Planning.** For a module's type, the planner fills in the placeholders of
  every text field and hands over a `ModuleRequest`: the type, the fields, and
  the labels chosen. If `problem(with:)` returns a reason, the action is
  refused before anything runs, and the overlay says why.
- **Timing.** A chosen leaf waits the time to cancel before it runs, unless
  `firesAtOnce(_:)` says otherwise — then it runs on the key press itself.
  `instant:` on a node overrides the module either way.
- **Running.** `run(_:now:)` returns an `ActionOutcome`, shown like any other.
  `now`, and the request's `time`, are when the key was pressed — before any
  time to cancel — so a module that measures time measures from the press.
- **Values.** `values(now:)` is asked whenever an action runs or is described,
  so any action can use them: `[Notes, title: "Worked {{stopwatch}}"]`. A
  module's names start with its id. The tree's own values win over a module's.
- **Status.** `status(now:)` is asked when the module calls `statusChanged()`,
  when the config changes, and at launch. A status shows as a row at the foot
  of the overlay whenever the overlay is up, and in the menu bar beside the
  icon. With `countingFrom` set, the host shows a clock running up from that
  moment, live, without asking again; `text` is shown otherwise. With
  `lightsKeys`, the idle keys that lead to the module's action types breathe
  in their own colours.
- **Menu.** Each time the menu bar's menu opens, `menuItems(now:)` is asked
  for commands; they're listed under the module's name, greyed out when not
  enabled. Choosing one calls `performMenuItem(_:now:)`, and its outcome is
  shown on the overlay.
  An item can hold a submenu, or, with an empty id, be a line that only
  shows something (`ModuleMenuItem.information`), set in digits that line up.
- **Blocks.** A module lists the block names it replies to. Before an action
  runs, the host finds its blocks, checks they're allowed where they are, and
  asks for replies innermost first — `TemplateBlocks.resolve`, which works in
  rounds, each asking for every block whose contents are ready at once — while
  the overlay shows a timer and a Cancel button. `reply(to:)` gets the block's
  name, attributes and finished contents; it runs off the main thread and is
  cancelled by task cancellation. Throw `ModuleError` with words to show.
  Previews use `standIn(for:)` instead, and never call `reply`.
- **Fetched values.** A module lists the prefixes it fetches — `api` — and
  `fetch(_:params:now:)` gets every name with that prefix an action uses
  (`api.weather`, `api.news.raw`), with the action's values, and returns
  theirs. Unlike `values(now:)`, it's asked only when an action uses the names,
  and may take time: the host fetches before any blocks, since a block may read
  a fetched value, under the same timer and Cancel. `valuesNeeded(toFetch:)`
  names the values a fetch needs first — a URL's `{{city}}` — so the host reads
  `{{selection}}` for it if need be. A needed value may be another module's
  fetched value — a data source's URL using `{{location.latitude}}` — so the
  registry fetches in rounds (`fetchRounds`), each needing only what came
  before, and hands each round's values to the next; values that need each
  other are refused. A name the tree gives a value itself isn't fetched.
  `fetchSubject(for:)` names what's fetched for the overlay: *Fetching your
  location and sunset…* — shown only if the wait passes a third of a second.
  A fetched name can carry **attributes**, like a block's opening tag:
  `{{quote file="q.md" order=sequential}}` is the name `quote file="q.md"
  order=sequential`, found by its first word; `Template.operatorCall` reads
  the attributes back. Fetched values aren't blocks: they may go in fields
  that steer an action. Previews use `standIn(forValue:)`.
- **Settings.** A module describes its settings — text, a secret, a choice, a
  flag — and the host draws them on a page of its own in the Settings window,
  listed in the sidebar under its name and `manifest.symbol`, an SF Symbol. The
  module reads them with `setting(_:for:)`, and secrets with `secret(_:for:)`,
  which the host keeps in the Keychain. A module never draws or stores them.
- **Refusing a block.** Before a key's action reads or fetches anything, the
  host asks each module that replies to a block in it,
  `refusal(forBlock:using:)`, with the names of the placeholders inside the
  block at any depth — "selection", "location.latitude" — as
  `TemplateBlocks.names(insideBlocks:in:)` finds them. A reason refuses the
  key, and the overlay shows it. Claude refuses what Settings → Privacy keeps
  from it.
- **State.** `load` and `save` keep data per module between runs. In the app
  they're the module's part of `state.json`, beside `tree.md`, under
  `modules.<id>.<key>`: the app reads and writes the file for every module,
  whole and atomically, and a module never touches it. Data that's JSON is
  kept as JSON, so the file can be read. State once kept in the app's
  preferences is moved into it the first time it's loaded. A development build
  keeps `state-dev.json`. On the command line, state is in memory only.
  Settings aren't state: they stay in the preferences, with secrets in the Keychain.

A module is called from any thread, so it keeps its state behind a lock.

## Modules using modules

Modules find each other through the registry —
`ModuleRegistry.shared.module(id:)` — and may offer a Swift interface of their
own. The stopwatch offers `perform(_:at:)` and `reading(at:)`, so a module that
depends on `KeybowStopwatch` could start it or read it. Claude offers
`ask(system:prompt:schema:)`, with the model and effort from Settings, which
data sources use to write their rules. A looser way needs no
dependency at all: another module's values are in every action's placeholders.

## The stopwatch

`mac/Sources/KeybowStopwatch/StopwatchModule.swift`.

- One action type, `stopwatch`, keyword `Stopwatch`, with one field, `do`:
  `toggle`, `start`, `stop`, `lap` or `reset`. Without it, a leaf's label
  decides — *Start*, *Stop*, *Pause*, *Lap*, *Split*, *Reset* — and anything
  else toggles, so a lone `Stopwatch [Stopwatch]` key starts and stops it.
- Start, stop and lap run on the press and are timed from it; Reset keeps the
  time to cancel.
- The menu bar's menu has Stop, Lap and Reset under *Stopwatch*, usable while
  it runs (Reset while it has a time), so it can always be stopped — even when
  no key for that has been set up — and a *Laps* submenu listing each lap's
  length and the time since the start, with *Copy Lap Times* to paste them.
- Values: `{{stopwatch}}` (3:12), `{{stopwatch.seconds}}` (192),
  `{{stopwatch.laps}}` (1:05, 1:00 — each lap's length) and
  `{{stopwatch.splits}}` (1:05, 2:05 — the time since the start at each lap).
- Status: shown while it has a time — running, or stopped and not yet reset —
  with the last lap. Its key pulses while it runs.
- State: saved on every change, so it keeps running through a restart of the
  app, or of the Mac.

## Claude

`mac/Sources/KeybowAI/ClaudeModule.swift`, module id `ai`.

- One block, `{{#ai}}`, answered through the Messages API (`POST /v1/messages`,
  plain HTTPS: there's no Swift SDK). Attributes `model`, `effort` and `source`
  (`claude` only, for now).
- Settings: the API key (a secret), the model (Claude Opus 5.5 by default) and
  the effort (low by default).
- The request leaves thinking to the model — always on for Opus 5.5 — with
  `output_config.effort` as the control, `max_tokens` 16,000 for thinking and
  reply together, a system prompt asking for just the text wanted, and, on
  Opus 5.5 / Opus 5 / Fable 5.1, `fallbacks: "default"` so a classifier decline
  is retried on the recommended model.
- Images and PDFs: a block's text can hold media tokens (`Media.swift` in
  KeybowKit) — `{{clipboard}}` holding a screenshot, say. Then the message's
  content is a list of `text`, `image` and `document` blocks, base64, in the
  order written; without tokens it's the text alone, as before. Filling in a
  template describes tokens everywhere but inside a block's contents, so only
  Claude ever gets the bytes. The host reads clipboard media only when an
  action needs `{{clipboard}}`, scaling images to 1568 on the long edge; the
  store keeps the newest eight in memory, never on disk.
- The reply is the response's `text` blocks, after checking `stop_reason` for a
  refusal or a cut-off. HTTP errors become messages that say what to do.
- The transport is a protocol, so tests check the exact request and replay
  responses without calling the API.
- For other modules, `ask(system:prompt:schema:)` sends one request and returns
  the text; with a JSON schema it asks for structured output
  (`output_config.format`), so the reply is JSON matching it.
- `sharing` is what the person lets Claude see, from Settings → Privacy, kept
  with the module's settings under `share.…` and `send.…` keys — everything,
  until something's unticked. It refuses a block that would send the selected
  text, the clipboard or where they are when those are kept from it, and an
  image or PDF on the clipboard as the request is made. The app reads the
  rest — what goes with a drafting request, and how much of the Music library
  (`MusicSharing`) its tool and AppleScript may show.

## Data sources

`mac/Sources/KeybowData/`, module id `api`.

- Fetches `{{api.<name>}}` — the value a source's rule finds — and
  `{{api.<name>.raw}}`, the whole response. Attributes give the URL's
  placeholders values for that use, `{{api.wikipedia term={{selection}}}}`:
  filled in from the action's values, checked against the URL's placeholders,
  and named in `valuesNeeded(toFetch:)` so the host reads `{{selection}}`
  first. Each distinct URL a key needs is fetched once, all at the same time, through a transport that refuses redirects to
  another host, so a key never follows one. https only (plain http for
  `localhost`), 20 seconds, 5 MB at most.
- A **rule** (`Extraction.swift`) is a JSONPath (the parts of RFC 9535 rules
  need: names, indices, wildcards, descendants, filters), an XPath 1.0 through
  `XMLDocument` (tidying HTML first), or an ICU regular expression. Several
  matches are joined with commas.
- **RuleFinder** writes a rule with Claude once: the description and a sample
  of the response — keys taken out, cut at 60,000 characters — with a JSON
  schema for the answer (`found`, `kind`, `expression`, `expected_value`,
  `explanation`). The rule is run on the whole sample on the Mac; if it finds
  nothing, fails, or finds something other than Claude expected, Claude is told
  and asked again, three tries at most. `found: false` means the value isn't in
  the response, and Claude's explanation says what is.
- **When a rule stops working** the fetch throws, the source is marked broken
  with why, and the menu bar's menu says so, until a test or a key press finds
  the value again, or a new rule is written. For a source whose URL takes
  values, finding nothing at a key press isn't counted — a search can rightly
  find nothing — only a response the rule can't read, or nothing found for the
  sample values in a test.
- Its own window, from *Edit Data Sources…* in the menu: sources, keys (in the
  Keychain, as `api.key.<id>`), caching, the description, Find It with Claude,
  Test Now, and a rule of your own.
- Sources are kept with `ModuleHost.save`; responses only in memory, for as
  long as each source says.

## Location

`mac/Sources/KeybowLocation/`, module id `location`.

- Fetches `{{location}}` (latitude,longitude), `{{location.latitude}}`,
  `{{location.longitude}}`, `{{location.altitude}}` (empty when unknown, as it
  usually is on a Mac) and `{{location.accuracy}}` (metres).
- A setting, *Precision*, rounds the place to 5, 3, 2 or 1 decimal places of a
  degree; the accuracy widens to cover the rounding.
- `CoreLocationProvider` asks Location Services for one place at a time
  (`requestLocation`, to about 100 m) — it never tracks the Mac — and uses one
  up to five minutes old if the system has it. It asks for permission on first
  use, bringing the app forward so the prompt is seen, and waits up to two
  minutes for an answer and twenty seconds for a place. Callers waiting at the
  same time share one request; cancelling the task stops the wait.
- The provider is a protocol, so tests use a fixed place. The app needs
  `NSLocationUsageDescription` in its Info.plist; it isn't signed with the
  hardened runtime, which would also need the
  `com.apple.security.personal-information.location` entitlement.

## Display

`mac/Sources/KeybowDisplay/DisplayModule.swift`, action type `display`,
keywords `Display` and `Show`.

- `takesText`: the planner hands it the template, text or label whole, filled
  in and trimmed, as `text` — with values HTML-escaped when the text is an HTML
  document (`NotesHTML.isDocument`).
- `run` asks the host to `display` it — Markdown or an HTML document, with its
  buttons and a time to fade — and waits. OK or Cancel returns
  `.then("ok")` or `.then("cancel")`, with `displayed`; anything else is
  `.quiet`, so the overlay doesn't report a display that's been and gone.
- `ok` and `cancel` are fields of kind `.action`. The outline writes one as
  `ok: Copy` and `ok.text: …`, compiled to `"ok": {"type": "clipboard.copy",
  "text": …}`; the module never sees it. The host finds it with
  `ActionSpec.nestedAction("ok")` and fires it for the same selection
  (`ResolvedSelection.with(action:)`), adding the outcome's values — `{{displayed}}`,
  and `text: {{displayed}}` when it has no text or template. Until then its
  fields aren't the node's: `ActionPlanner.ownFields` leaves them out, so their
  blocks aren't asked and their values not fetched when the key is pressed,
  only when the follow-up runs. The editor draws a
  Type menu and fields for each, shown once the buttons include it.
- In the app, `DisplayController` draws it: a non-activating HUD panel with a
  WebKit view, scripts off, links out to the browser, sized by measuring the
  page (without a scroll bar, which would take width), and holding Esc as a
  hot key while it's up (`EscapeKey`), which needs no permission — watching
  keys typed into other apps would need Accessibility or Input Monitoring. A development build can answer OK or Cancel by itself
  with `KEYBOW_DEBUG_DISPLAY_ANSWER`.

## Windows

`mac/Sources/KeybowWindows/`, action type `window`, keywords `Window` and
`Arrange`.

- `WindowGeometry` does the arithmetic, from screens' frames and visible frames
  alone, so it's tested without windows: the rectangle for each place, the
  screens in order from the left, the one a window is on, the one a `screen:`
  names, a window's share carried from one screen to another, and the flip
  between AppKit's rectangles (from the bottom-left of the main screen) and
  Accessibility's (from its top-left).
- `WindowMover` uses Accessibility on the app in front: its focused window, else
  its main, else its first. It turns off `AXEnhancedUserInterface` while it
  works — apps animate and fight a resize with it on — then sizes, moves and
  sizes again, and reads the frame back, putting it right if a window moved to
  another screen was held to the old one's size.
- `KEYBOW_DEBUG_WINDOW_PID` limits it to one process's window, whatever's in
  front, for testing without moving anyone's work. It only narrows what's moved,
  so the app honours it too.

`ExposeModule`, beside it: action type `expose`, keywords `Exposé`, `Expose`
and `Mission Control`. It asks the Dock as macOS's Mission Control launcher
(`com.apple.exposelauncher`) does: `CoreDockSendNotification`, from
ApplicationServices, with `com.apple.expose.awake`, `.expose.front.awake` or
`.showdesktop.awake`. Each toggles, as the keyboard shortcuts do. The call is
made in the app: running the launcher as a child process does nothing, since
it exits before the Dock hears it. Should the function go, the launcher is
opened as an app instead — no argument for Mission Control, `1` for the
desktop, `2` for the app's windows. It fires at once and answers quietly: what
it did is on the screen, and the overlay steps aside.

## Ask

`mac/Sources/KeybowDisplay/AskModule.swift`, action type `ask`, keywords
`Ask` and `Prompt`.

- A display with a `ModuleDisplay.Field` — its starting text, a hint, one line
  or several — and OK and Cancel. The host's panel takes the keyboard: it's a
  non-activating panel, so it can without the app in use leaving the front, and
  that app has the keyboard back once it goes. OK waits for text, and answers
  `.entered(text)`.
- It returns `.then("ok", values: ["answer": text], text: "{{answer}}")`: the
  follow-up gets `{{answer}}`, and `{{answer}}` as its text if it has none.
  Cancel is `.then("cancel")`; anything else `.quiet`.
- `ok: append` and `ok: new` name note actions, as the words do in brackets.

## Quotes

`mac/Sources/KeybowQuotes/`, module id `quote`.

- Fetches `{{quote file="…" heading="…" order=random|sequential}}`.
  `TextPortions` splits a file into portions: paragraphs of plain text (or
  lines, or `fortune` entries), items of Markdown lists, items of HTML lists —
  tidied from the text, since tidying bytes without a charset garbles them —
  and narrows Markdown and HTML to the items under a heading.
- In sequence, `positions` in its state holds each list's next place, keyed by
  file path and heading; at random, the last one given, which isn't given again
  next time. Picks within one fetch are shared by list and order.
- Attribute values are templates, filled in from the action's values;
  `valuesNeeded(toFetch:)` names what's in them, so `{{selection}}` is read
  first if they use it.

## Home Assistant

`mac/Sources/KeybowHome/`, module id `home`.

- Fetches `{{home.<domain>.<object_id>}}` — an entity's state — and
  `{{home.<entity>.<part>}}`: `name`, `unit`, `text`, `changed`, or any
  attribute. Up to four entities are asked for one at a time, side by side;
  more, in one request for every state.
- Runs `home`: works out the service from the entity's domain and the fields
  given, and says what changed from the states Home Assistant sends back.
- `HomeAssistant` is the REST API — `GET /api/states/<entity>`,
  `POST /api/services/<domain>/<service>`, `GET /api/config` — with the token
  as a bearer header, behind `HomeTransport` so tests use a made-up Home
  Assistant. Redirects to another host aren't followed.
- Plain http is allowed only to local hosts, checked in code; the app's
  Info.plist lets URLSession make those connections: `NSAllowsLocalNetworking`
  for `.local` names, and `NSExceptionDomains` for the private address ranges,
  since a bare IP address isn't local networking to App Transport Security.
- Menu: *Check the Connection* and *Copy the Entity List*, answered in a
  display. Settings: *Address*, and *Access token*, kept in the Keychain.
- In the tree editor, *Entity* lists what Home Assistant has to control —
  sensors and the like left out — and *Service*, *Mode*, *Value* and *Colour
  temperature* follow the entity chosen: its domain's services, a
  thermostat's modes, a select's options or a number's range, the warmth a
  lamp can do. States and services are kept for 30 seconds, since the editor
  asks each time a field is drawn. Only the fields the entity's domain takes
  are shown — a lamp's brightness, a thermostat's temperature — and *Colour*
  has a colour picker.

## Not yet

- **Loading modules at run time.** They're compiled in. A plugin system would
  load bundles against this same interface.
- **A module's own settings view**, beyond the rows its settings describe, and
  **its own overlay layout**. A status is text and a clock; anything richer
  would need the interface to grow.
- **Default fields per type** from a module, as the built-in types have.
