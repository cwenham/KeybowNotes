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
| Say its status changed on its own | `ModuleHost.statusChanged()` |

The interface is in `mac/Sources/KeybowKit/Modules.swift`.

## The pieces

```
KeybowKit            the module interface, the registry, and the core
KeybowStopwatch      a module: depends on KeybowKit only
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
- **State.** `load` and `save` keep data per module between runs: in the app,
  in its preferences; on the command line, in memory only.

A module is called from any thread, so it keeps its state behind a lock.

## Modules using modules

Modules find each other through the registry —
`ModuleRegistry.shared.module(id:)` — and may offer a Swift interface of their
own. The stopwatch offers `perform(_:at:)` and `reading(at:)`, so a module that
depends on `KeybowStopwatch` could start it or read it. A looser way needs no
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

## Not yet

- **Loading modules at run time.** They're compiled in. A plugin system would
  load bundles against this same interface.
- **A module's own settings pane**, and **its own overlay layout**. A status
  is text and a clock; anything richer would need the interface to grow.
- **Default fields per type** from a module, as the built-in types have.
