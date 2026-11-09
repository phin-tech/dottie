---
status: accepted
---

# Palette colors are stored by name, with the color they resolve to

A page picks one of six built-in themes, which set only its page color and the color automatic ink takes. Every other
color is a hex value on the element, so a diagram can't follow a house palette. An agent building one has to repeat
the same hex everywhere, and changing "the accent color" means finding every shape that used it.

## Decision

- **Every theme has a palette** of named colors. The built-ins share six names (`accent`, `muted`, `danger`, `warning`,
  `success`, `info`), lighter on dark pages. A page can also have a **theme of its own** (`customTheme`: name, page
  color, ink, palette, and the built-in it was made from). It takes the place of `theme`, and its palette can add names.
- **An element stores the name and the color.** `style.named` says which of `fill`, `stroke` and `textColor` are
  palette colors, by name; the colors themselves stay in the style as usual, holding what the name resolved to when
  written. So every renderer, export and older version draws plain colors, and nothing on the render path changes.
- **Names are resolved whenever they could have moved.** That happens when a file is read (Swift `DottieFile.decode`,
  dottie.js `parseDottie`, the same function in each, so the goldens prove they agree), when the theme or a palette
  color changes, and on every app commit (`reconcilingColorNames`). A name the palette lacks keeps the stored color.
- **A color changed by hand stops being a palette color.** In the app, a commit that changes a named color to anything
  but its palette color drops the name. Over MCP and in scripts, a hex argument drops it and a name sets it.
- **Names are accepted wherever a color is**, in MCP tools and scripts: hover looks, overrides, keys, packets and flows
  too. Only an element's own fill, stroke and text color remember the name; elsewhere the name picks the color once.

## Considered

- **Store only the name and resolve while drawing.** It is cleaner on disk, but it touches every renderer (Swift,
  dottie.js, the SVG, PDF, Lottie and movie exports, QuickLook), and older versions would draw a missing color.
- **Store only the hex (names as input shorthand).** It is simplest, but changing the theme wouldn't recolor anything,
  which is the point.

## Consequences

- A hand-edited file whose stored color disagrees with its name is drawn in the palette's color. That is intended.
- Overrides, hover looks, keys and flow colors given by name don't follow later palette changes.
