# dottie.js

**Play any Dottie drawing on any web page, straight from the `.dottie` file.**

dottie.js draws and animates `.dottie` files in the browser, with nothing rendered ahead of time. What you get
is what Dottie draws: the same sketchy strokes, connectors, notes, timing, camera moves and scenes. Every demo on
this site is played this way.

<dottie-player class="player" src="../drawings/tour.dottie" label="A click-through tour"></dottie-player>

## Put a drawing on your page

Add the script once, then a `<dottie-player>` for each drawing:

```html
<script type="module" src="https://cdn.jsdelivr.net/npm/@phin-tech/dottie/dist/dottie-player.js"></script>

<dottie-player src="tour.dottie"></dottie-player>
```

Or install it with npm and import it in your own build:

```sh
npm install @phin-tech/dottie
```

```js
import "@phin-tech/dottie/player";   // registers <dottie-player>
```

An animation plays with the controls you see above: play and pause, a scrubber, scene back and next for a
click-through, and the keyboard (space, ← →, and `,` `.` to step a frame). It pauses while scrolled out of
view, and shows its finished state to people who prefer reduced motion. A drawing without animation is just the
picture.

| Attribute | |
|---|---|
| `src` | The `.dottie` file. Or put the file inside: `<dottie-player><script type="application/json">{…}</script></dottie-player>` |
| `page` | Which page to show, by name or number; the first by default |
| `at` | Show this moment (in seconds) as a still |
| `clean` | Draw precisely instead of sketchy |
| `no-controls`, `no-autoplay`, `no-loop` | |
| `label` | What screen readers announce; the page name by default |

The same drawing, still and clean, three seconds in:

```html
<dottie-player src="tour.dottie" at="3.2" clean></dottie-player>
```

<dottie-player class="player" src="../drawings/tour.dottie" at="3.2" clean label="The tour, still and clean"></dottie-player>

From script, the element has `play()`, `pause()`, `nextScene()`, `prevScene()`, `currentTime`, `duration` and
`paused`, and fires `load`, `frame` and `error` events.

## Render SVG in code

The library also runs in Node, to make SVG on a server or at build time:

```js
import { render } from "@phin-tech/dottie";
import { readFileSync, writeFileSync } from "node:fs";

const svg = render(readFileSync("tour.dottie", "utf8"), { at: 3.2, clean: true });
writeFileSync("tour.svg", svg);
```

## What it covers

Everything Dottie draws and animates, checked against Dottie itself on every change: see
[PARITY.md](https://github.com/phin-tech/dottie/blob/main/web/PARITY.md) for the list, and the
[dottie.js README](https://github.com/phin-tech/dottie/tree/main/web#readme) for the full API.
