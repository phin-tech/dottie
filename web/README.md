# dottie.js

`npm install @phin-tech/dottie` · [Live demos](https://dottie.phin.tech/dottie-js/)

Render and play [Dottie](https://github.com/phin-tech/dottie) drawings in the browser, straight from the
`.dottie` file: stills or animations, sketchy or clean, with no pre-rendered frames. It draws what Dottie draws:
the same sketchy strokes from the same seeds, the same routing, timing, camera and scenes (see
[PARITY.md](PARITY.md)).

## Embed a drawing

```html
<script type="module" src="https://cdn.jsdelivr.net/npm/@phin-tech/dottie/dist/dottie-player.js"></script>

<dottie-player src="tour.dottie"></dottie-player>
```

An animated page plays with Dottie's controls: play and pause, a scrubber, scene back and next for a
click-through, and the keyboard (space, ← →, and `,` `.` to step a frame). It plays at the drawing's frame rate,
loops (or stops at each scene), pauses while scrolled out of view, and rests on its poster frame for people who
prefer reduced motion. A still page is just the drawing.

| Attribute | |
|---|---|
| `src` | The `.dottie` file's URL. Or put the file inside: `<dottie-player><script type="application/json">{…}</script></dottie-player>` |
| `page` | Page name or 1-based number; the first page by default |
| `at` | Show this moment (seconds) as a still |
| `clean` | Draw precisely instead of sketchy |
| `no-controls`, `no-autoplay`, `no-loop` | |
| `label` | The accessible name; the page name by default |
| `history` | Each page a link shows gets its own address (`#` and the page's name), so Back and Forward go between pages and a link can open any of them. One such player to a page |
| `links` | JSON from the id of an element a link points at to the web page that shows it (`{"…": "details.html"}`), for a drawing exported one page per file: a link to another page goes there. Only relative `.html` paths are followed |

Elements the drawing makes clickable work with the mouse and the keyboard (Tab, then Enter or Space). A click plays
a named scene on to the next one, opens a link in a new tab (only `http`, `https` and `mailto`), or shows the page a
shape's link points at. Each shows its hover look under the pointer; button symbols show their over and down looks
and take clicks on their hit area, and a symbol's copy set to play when clicked plays its animation through. Every
click first fires a cancelable `action` event whose `detail` is `{element, scene | url | page | state, set?, toggle?,
replay?}`; call `preventDefault()` to handle it yourself.

A click can also set or toggle the page's variables, which show and hide the elements with a `when` while the
animation keeps playing: a diagram you leave running that people poke. Elements can restyle themselves under a
condition (`overrides`), and a page's `flows` send traffic over whatever connectors are drawn, so it goes round a
region a click took down. A looping scene plays round until a click or next leaves it, instead of stopping.

The element has `play()`, `pause()`, `nextScene()`, `prevScene()`, `activate(elementId)`, `currentTime`
(settable), `duration`, `paused`, `variables` and `setState({name: value})`, and fires `load`, `frame`, `action`,
`state` (with `{variables}`, after a change), `page` (with `{index, name, first}`, when the page shown changes) and
`error` events. Its page color comes from the drawing's theme; set
`--dottie-radius` to round it, and style its parts with `::part(stage)` and `::part(controls)`.

Without modules, `dist/dottie-player.min.js` is a classic script that registers the element and sets
`window.Dottie`.

**Big animations.** Before it shows an animation without a camera, the player works out the view of every frame,
which for a long, busy one takes long enough to hold up the page. So it does that in a worker, and the drawing
appears, exactly as it would have, when the worker is done; `setFile()` returns at once, and the `load` event fires
when it is showing. The classic script starts the worker from its own source (a `blob:` URL); the module player
loads `dottie-player.min.js` from beside itself, so host the two together. Where a worker can't start, as under a
`worker-src` policy that refuses it, the player works it out in place as before. Small drawings always do.

**Click logic.** Variables can be numbers, and conditions and clicks are small expressions (`count >= 3`,
`"count + 1"`, `{count}` in a label). For more, a page can carry `logic`: JavaScript handlers a click `run`s, each
getting the variables and the click and returning new values. The player runs them only with `allow-logic`:

```html
<dottie-player src="game.dottie" allow-logic></dottie-player>
```

Each click's handler runs in a fresh QuickJS sandbox compiled to WebAssembly, never in your page's JavaScript: it has
no `window`, `document`, network, timers, `Date` or `Math.random`, and a time and memory limit, so the same click on
the same state gives the same result everywhere. A handler that fails leaves the state as it was and fires
`logicerror` (with `{element, handler, error}`). Without `allow-logic`, a click does its own `set` and `toggle`
instead. The engine (`dottie-logic.min.js`, about 850 KB) is loaded from beside the player only when a page with
logic is clicked, so host it with the player; `dottie-compile --allow-logic` puts it in the compiled script instead.

**Fonts.** Text in Dottie's handwriting fonts (Caveat, Patrick Hand, Architects Daughter; SIL Open Font License)
is drawn in them: the player loads the ones a drawing uses from `fonts/` beside its own script, as `dist/fonts` on
npm and the CDNs. If you host the player yourself, copy that folder with it, or call `Dottie.setFontBase(url)`
before the player loads a drawing. A font of the drawing's own is named, not shipped: viewers who have it see it,
and the rest see Helvetica Neue or its stand-ins.

## Compile a drawing into one script

```sh
npx -p @phin-tech/dottie dottie-compile tour.dottie        # writes tour.js
```

`tour.js` holds the player and the drawing (about 110 KB plus the drawing; around 38 KB gzipped), and the
handwriting fonts the drawing uses (15 to 30 KB each), so one file shows it anywhere you can put a script tag:

```html
<script src="tour.js"></script>                            <!-- a player right here -->
<script src="tour.js" data-target="#demo"></script>        <!-- a player inside #demo -->
<script src="tour.js" data-clean data-no-loop></script>    <!-- data-* set the player's attributes -->
```

`dottie-compile` takes `--page`, `--at`, `--clean`, `--no-controls`, `--no-autoplay`, `--no-loop` and `--label`;
only the chosen page (and its pictures) goes in. With `--all-pages` every page goes in, for a drawing people drill
into: a link to a shape on another page shows that page, each page gets its own address (`tour.html#Details`), and
Back goes back (`--page` is then the page to start on). The Dottie Mac app's command-line tool writes the same file:
`dottie render tour.dottie -f js`. From code: `import { compile } from "@phin-tech/dottie/compile"`.

## Use the library

```js
import { parseDottie, render, resolved, svg, plan } from "@phin-tech/dottie";

const file = parseDottie(await (await fetch("tour.dottie")).text());
const still = render(file, { page: 1, at: 3.2, clean: true });   // an SVG document, as a string
```

It runs in Node too, to render SVG on a server or at build time. `parseDottie` reads a file as Dottie does
(defaults, clamps, sorting) and lists what it skipped in `file.warnings`; `resolved(page, t)` is the page posed at
`t` seconds; `svg(page)` draws a page; `plan(page)` gives an animation's frame times and views; `Playback` drives
an SVG element frame by frame, for players of your own.

## Developing

```sh
npm ci
npm test               # types, unit tests, the geometry contract and the SVG goldens
npm run visual         # every golden rasterized next to dottie.js's render, compared pixel by pixel
npm run test:browser   # <dottie-player> in headless Chromium (npx playwright install chromium first)
npm run build          # dist/: dottie.js, dottie-player.js, dottie-player.min.js and types
```

The goldens in `../fixtures/goldens` are written by Dottie itself (`just goldens`, on a Mac); see "dottie.js" in
[DEVELOPMENT.md](../DEVELOPMENT.md) for how the two renderers are kept in step.
