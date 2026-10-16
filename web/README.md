# dottie.js

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

The element has `play()`, `pause()`, `nextScene()`, `prevScene()`, `currentTime` (settable), `duration`,
`paused`, and fires `load`, `frame` and `error` events. Its page color comes from the drawing's theme; set
`--dottie-radius` to round it, and style its parts with `::part(stage)` and `::part(controls)`.

Without modules, `dist/dottie-player.min.js` is a classic script that registers the element and sets
`window.Dottie`.

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
