---
status: accepted
---

# Richer conditions, then sandboxed click logic; frames stay a pure function of state

Interactive pages react through page variables: booleans that clicks `set`, `toggle` or `reset`, and that `when`
conditions and overrides read (`down`, `!down && east`, `load(workers) >= 0.9`). That covers "take a region down", but
not counting, cycling through options, thresholds on a value the reader changes, or logic of the author's own. The
obvious fix, letting a drawing carry JavaScript, collides with two things:

- **Determinism.** Every frame is a pure function of the time, the variables, the time since the state changed and
  what the queues held then (ADRs 0002 and 0004). That is what lets the player plan big animations in a worker, seek,
  precompute exports, and lets `simulate` and recordings play a page without a browser.
- **Safety.** dottie.js plays inside other people's pages, and QuickLook, the HTML export and `simulate` open files
  without asking. Code in a file would run with the host page's powers. ADR 0001 rules out code in documents for this
  reason.

## Decision

Two steps, the first useful on its own and the base for the second.

### 1. Conditions become a small expression language (no code)

- **Variables can be numbers** as well as booleans (`variables: {count: 0, down: false}`).
- **One grammar** for `when`, overrides and flows' `when`: number and boolean literals, variable names, the metric
  calls that exist today (`load(id)`, ...), parentheses, unary `!` and `-`, `* / %`, `+ -`, `< <= > >= == !=`, `&&`,
  `||`, and the functions `min`, `max`, `abs`, `floor`, `ceil`, `round`, `clamp`. Today's conditions mean what they did.
- **Clicks compute.** A `set` value is a literal or an expression over the state before the click:
  `set: {count: "count + 1", stage: "(stage + 1) % 3"}`. `toggle` and `reset` stay.
- **Labels can show values** (a later part of this step): `{count}` and `{load(workers)}` in text.
- **The same parser and evaluator in Swift and TypeScript.** Parsed once into a tree; numbers are doubles, evaluated
  in the same order. A shared table of expressions and their values, run by both test suites, proves it, as the
  goldens do for drawing. A condition that can't be read never holds, as now.

### 2. Click handlers in a sandbox

- **Logic runs on clicks, never while drawing.** A page may have `logic`: JavaScript defining handlers. A click can
  `run` one: `handler(state, click)` gets the variables and the click (the element's id, anchor and first line of
  text, the time, the scene) and returns new variable values. A click's own `scene` or link still applies with it;
  a handler doesn't move the playhead. The frame is still a pure function of the
  state, so planning, seeking, exports, `simulate` and recordings keep working: a recorded run replays its clicks.
- **One engine, sealed.** Handlers run in QuickJS compiled to WebAssembly, the same build in the browser and in
  Dottie's JavaScriptCore, never in the page's own JavaScript. They get an instruction and memory budget, and no
  DOM, network, timers, clock or randomness (`Math.random` and `Date` are absent); the same click on the same state
  gives the same result everywhere. A handler that throws or runs out of budget leaves the state as it was.
- **Off unless allowed.** `<dottie-player>` runs logic only with an `allow-logic` attribute. The app's HTML export
  asks whether to allow it, and `export_animation`, `dottie render` and `dottie-compile` take `allow_logic` /
  `--allow-logic`; only then does the export carry the engine and the attribute. QuickLook and the editor never run
  logic (Dottie plays no clicks there); `simulate` and recordings run it, in the same sandbox, so an agent can check
  a page. Where logic can't run, a click falls back to its own `set` / `toggle`, which is why a click with `run`
  keeps them. A handler that fails leaves the state as it was, and the player fires `logicerror`.
- **Paid for only when used.** The engine (`dottie-logic.min.js`, about 850 KB) loads only when a page with logic
  it may run is clicked, from beside the player (or from the page, when an export inlined it). Dottie carries it as
  base64 in `PlayerScript.logic`, since its minified source holds bytes a Swift string can't, and polyfills the
  `TextDecoder`, `TextEncoder` and `atob` JavaScriptCore lacks.
- **ADR 0001 is narrowed, not dropped:** extension code still never goes in documents; the only code a document may
  carry is this click logic, in this sandbox.

## Considered

- **JavaScript in the page's own context** (`new Function`). Fastest to build, and an XSS hole in every page that
  embeds a drawing.
- **Code that runs every frame.** It would give the most freedom, but breaks planning, seeking and exports, and makes
  each frame depend on how it was reached.
- **A browser sandbox (an iframe or a worker) for handlers.** Asynchronous and different from what Dottie can run
  natively, so Swift and the browser could disagree.

## Consequences

- Number variables are a format change: Dottie before this reads `variables` as booleans and would refuse a page
  that has numbers in them. The file version goes up with step 1.
- `simulate`, `define_state`, the controls (`add_button`, `add_choice`) and the dottie skill learn numbers, and later
  `run`.
- Step 2 adds a dependency (the QuickJS build) and a permission prompt to the app.
