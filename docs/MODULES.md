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
| **Fetch values** when an action needs them — `{{api.weather}}` | `manifest.fetches`, `fetch(_:params:now:)`, `valuesNeeded(toFetch:)`, `standIn(forValue:)` |
| Add **settings** to the Settings window, secrets kept in the Keychain | `manifest.settings`, `ModuleHost.setting` / `secret` |
| Keep secrets of its own making in the Keychain | `ModuleHost.setSecret` |
| Say its status changed on its own | `ModuleHost.statusChanged()` |

The interface is in `mac/Sources/KeybowKit/Modules.swift`.

## The pieces

```
KeybowKit            the module interface, the registry, and the core
KeybowStopwatch      a module: depends on KeybowKit only
KeybowAI             a module: {{#ai}} blocks, and Claude for other modules
KeybowData           a module: data sources, using KeybowAI to write rules
KeybowModules        the list of built-in modules
KeybowNotesApp       registers them at launch; shows their status
keybow               registers them too, so their keywords compile
```

`BuiltInModules.registerAll(host:)` in `KeybowModules` is the one list. Adding
a module is a new target, a line there, and a dependency in `Package.swift`.

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
  `{{selection}}` for it if need be. Fetched values aren't blocks: they may go
  in fields that steer an action. Previews use `standIn(forValue:)`.
- **Settings.** A module describes its settings — text, a secret, a choice, a
  flag — and the host draws them in its own section of the Settings window. The
  module reads them with `setting(_:for:)`, and secrets with `secret(_:for:)`,
  which the host keeps in the Keychain. A module never draws or stores them.
- **State.** `load` and `save` keep data per module between runs: in the app,
  in its preferences; on the command line, in memory only.

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
- The reply is the response's `text` blocks, after checking `stop_reason` for a
  refusal or a cut-off. HTTP errors become messages that say what to do.
- The transport is a protocol, so tests check the exact request and replay
  responses without calling the API.
- For other modules, `ask(system:prompt:schema:)` sends one request and returns
  the text; with a JSON schema it asks for structured output
  (`output_config.format`), so the reply is JSON matching it.

## Data sources

`mac/Sources/KeybowData/`, module id `api`.

- Fetches `{{api.<name>}}` — the value a source's rule finds — and
  `{{api.<name>.raw}}`, the whole response. Each source a key uses is fetched
  once, all at the same time, through a transport that refuses redirects to
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
  the value again, or a new rule is written.
- Its own window, from *Edit Data Sources…* in the menu: sources, keys (in the
  Keychain, as `api.key.<id>`), caching, the description, Find It with Claude,
  Test Now, and a rule of your own.
- Sources are kept with `ModuleHost.save`; responses only in memory, for as
  long as each source says.

## Not yet

- **Loading modules at run time.** They're compiled in. A plugin system would
  load bundles against this same interface.
- **A module's own settings pane**, and **its own overlay layout**. A status
  is text and a clock; anything richer would need the interface to grow.
- **Default fields per type** from a module, as the built-in types have.
