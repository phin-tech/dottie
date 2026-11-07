---
name: dottie
description: Draw, edit, animate and export diagrams with Dottie, the Mac app for sketchy or clean diagrams stored as .dottie files, through its MCP server, its `dottie` command-line tool or its JavaScript scripting. Use when asked to draw a diagram or flowchart in Dottie, change or animate a .dottie file, render one to PNG, SVG, PDF, GIF, MP4, Lottie or HTML, or put one on a web page.
---

# Drawing with Dottie

Dottie draws diagrams that look hand-drawn (sketchy) or precise (clean), stored as `.dottie` JSON files. Agents work
on them three ways:

- **The MCP server** (`dottie` tools: `build_diagram`, `export_png`, …) edits drawings, live in the app's window when
  the file is open there. This is the main way.
- **The `dottie` command** renders drawings and Mermaid flowcharts to images, animations and web pages.
- **Scripts**: one JavaScript program, run by the MCP tool `run_script`, makes many computed edits in one step.

## Connecting the MCP server

If the `dottie` MCP tools are already available, skip this. Otherwise Dottie must be installed
(`brew install --cask phin-tech/tap/dottie`, macOS 14 or later), and the server is the `dottie-mcp` inside the app:

```sh
claude mcp add dottie -- /Applications/Dottie.app/Contents/Helpers/dottie-mcp
```

Other MCP clients take the JSON snippet in Dottie ▸ Settings ▸ MCP. The client loads servers when it starts, so the
user restarts their session before the tools appear. Until then, the command line still renders (below).

## Drawing a diagram

1. **Pick the file.** Every tool takes an absolute `path` ending in `.dottie`. When the user wants to watch, call
   `open_document` first: each change then appears in the window and is undoable with ⌘Z. Without the app open,
   the tools edit the file directly.
2. **Lay it out.** For a new diagram, `build_diagram` with nodes and edges: it ranks them and adds connectors that
   stay attached when shapes move. `sketchy: false` gives the clean look. `import_mermaid` takes a Mermaid flowchart
   instead.
3. **Look at it.** `export_png` returns the page as an image. Read it as the user would: overlapping labels, crossed
   or crowded arrows, text spilling out of shapes, a layout that runs the wrong way.
4. **Fix and look again.** `list_elements` gives the ids that `update_element`, `delete_element` and
   `add_connector` take; `auto_layout` re-ranks a page. An arrow that cuts through a shape can be routed around it
   with `waypoints` (canvas points it bends through, on `add_connector` or `update_element`), and `hops: true` puts
   a small arc where it crosses an arrow beneath it. The diagram is done when the latest PNG reads cleanly, with
   every label legible and every arrow's ends clear.

Loops, conditions and bulk edits (a grid of boxes, restyling everything labelled "TODO", a fan-out from one node)
go in one `run_script` program rather than many tool calls; it runs as one undo step and nothing applies if it
throws. `script_api` documents the `dottie` object it uses.

For handwritten text, pass `font` to `build_diagram`, `import_mermaid`, `add_shape`, `add_connector` or
`update_element` (with `font_size` for the size): Caveat (quick pen; it runs small, so give it 22 or more), Patrick Hand (neat print) or
Architects Daughter (draftsman's caps). Those three travel with every export. Any other name is a font installed on
the Mac, which exports name but don't carry, so prefer the bundled ones for anything shared.

A label takes its shape's or arrow's `stroke` color unless you give it `text_color` (hex; `""` follows the stroke
again). Setting `stroke` on `update_element` recolors the label too, so pass both to color them apart.

More of the MCP tools, by purpose:

| For | Tools |
| --- | --- |
| Pages | `list_pages`, `add_page`, `rename_page` |
| Stencils (flowchart symbols, icons, imported SVG sets) and pictures | `list_stencils`, `add_stencil`, `add_image` |
| Symbols, defined once and placed many times | `make_symbol`, `place_symbol` |
| Extension shapes and commands | `list_extensions`, `add_shape` with `extension`, `run_command` |
| Interactive pages: traffic and states | `add_flow`, `define_state`, `add_override`, `set_variable`, `add_gauge`; worked examples in `script_api` `example` |
| Controls for an interactive page | `add_button`, `add_choice`, `add_reset`, `add_legend` |
| Exports, and checking an interactive page | `export_svg`, `export_mermaid`, `export_animation`, `simulate` |

## Animating

Any page can move. Most animations come from a few tools:

- `animate_build`: the page builds itself in the order its arrows connect shapes.
- `add_transition`: an entrance, exit or emphasis for chosen shapes (pop, grow, wipe, draw, fade, pulse, …).
- `send_packet`: a dot, or a labelled pill such as `POST /orders`, travels along a connector.
- `set_camera` and `add_scene`: pan and zoom across a large diagram, and stop at named scenes; the HTML export then
  steps through the scenes like slides. `loop: true` makes a scene play round instead of stopping.
- `add_keyframe` and `set_timeline` for anything else, and `clear_animation` to start over.

### Showing how a system behaves

Dottie presents systems; it doesn't simulate them. A diagram that keeps looping and reacts to clicks ("take
us-east-1 down while traffic keeps flowing", "what happens to the queue in a traffic spike") is built from a few
pieces, each a picture of an idea rather than a forecast: pick numbers that make the story read clearly. The
quickest start is a worked example: `script_api` with `example` (`region-failover`, `queue-workers`, `aws-outage`),
or the resources `dottie://examples/<name>`. Run one with `run_script` on an empty page, then adapt it.

1. **Where traffic goes.** `add_flow` sends steady traffic from a shape to the first of its destinations it can reach
   (`to: [east, west]` fails over), routed afresh every frame over the connectors drawn. The route is the cheapest by
   connector `cost` (1 each, so fewest hops, unless set): give the main path a lower cost than a backup. To split
   traffic, add one flow per destination, each with its own `color`; with `spread: true`, a flow whose first
   destination is down shares its packets across the others, keeping its color so you can see where it went.
2. **How much.** `add_flow` `volume`, and `capacity` (and a shape's `delay`) on `update_element`. Flows fill their
   cheapest route in page order (earlier flows first); what doesn't fit takes the next route, and what fits nowhere is
   backlog, piled at the shape in front of the bottleneck (a queue in front of busy workers, a hub in front of a full
   lane). `add_gauge` shows a metric (load, throughput, backlog, transit, backup, …) as a number, bar or dial.
3. **States.** `define_state` describes one variable at once: what it takes `down` (faded, traffic goes round it),
   `hide`s, `show`s, `dim`s or `restyle`s (including `cost`, `capacity` and `delay`), connectors whose `send_packet`
   packets `reroute`, and which clicks flip it (`toggled_by`). `add_override` adds one change to one element under
   a condition; a condition can compare a metric by anchor, like `load(workers) >= 0.9`, to turn whatever is
   saturated red (such overrides change only looks).
4. **Controls.** `add_choice` for exclusive scenarios (one variable per option, named `<name>_<option>` with the
   option's capitals kept), `add_button` for one switch with a pressed look, `add_reset` to go back to the start, and
   `add_legend` to hide and show each flow. A row of choice buttons (1×, 2×, 3× traffic, each adding a flow with a
   `when`) stands in for a slider.
5. **Check it.** Edit tools end with **Warnings** when the wiring looks wrong: a condition reading a variable nothing
   sets (usually a typo; it suggests the right name), a metric comparison or gauge pointing at nothing.
   `list_elements` lists each variable with what reads it and which clicks change it. `simulate` with steps like
   `{"click": "spike"}`, `{"wait": 1}`, `{"metrics": true}` and `{"snapshot": true}` plays it as the player would.

Traps: `update_element`/`dottie.update` with `overrides` replaces the whole list (use `add_override` /
`dottie.addOverride` to add one); conditions are case-sensitive; flows are placed in page order, so the first flow
gets capacity first.

Lower level: `set_variable`, `update_element` with `click_toggle` / `click_set`, and `when` on shapes, connectors and
packets (`"down"`, `"!down"`). Exports show the starting values; the HTML export and `<dottie-player>` change them on
click without stopping.

Check an interactive page before calling it done; you can't click the HTML export yourself. `simulate` plays it as
the player would: give it steps like `{"click": "east"}`, `{"wait": 2}` and `{"snapshot": true}`, and it reports the
time, the scene, the variables and what their conditions hide after each, with a PNG per snapshot. `export_png` and
`export_svg` take `state: {"down": true}` to draw one state, and `export_animation` takes it as starting values.

`export_animation` writes a GIF, animated PNG, MP4, Lottie JSON or a playable HTML page, or with `.png` a still of
the poster frame. Watch the GIF before calling
an animation finished: timing that reads well in a description often runs too fast or overlaps.

## The command line

`dottie` comes with the app (Homebrew links it; otherwise Dottie ▸ Settings ▸ Command Line). `dottie --help` lists
everything. The common calls:

```sh
dottie render diagram.dottie -o diagram.png        # or .svg .pdf .gif .apng .mp4 .json (Lottie) .html .js .mmd
dottie render diagram.dottie --clean -p "Page 2"   # a precise look; a page by name or number
dottie render flow.mmd -o flow.svg                 # a Mermaid flowchart, laid out and drawn
dottie inspect diagram.dottie                      # every element's resolved frame and connector route, as JSON
dottie render diagram.dottie --state down -o down.png   # the page with variable down true
dottie simulate diagram.dottie --click east --wait 2 --snapshot after.png   # play it as the web player would
dottie script-types ./types                        # dottie.d.ts, the types of the scripting API
```

With the drawing open in the app, `render` and `inspect` read the app's copy, so MCP edits show up before the file
is saved; `--disk` reads the saved file instead.

## On a web page

`dottie render diagram.dottie -f js` writes one script holding the drawing and the player: `<script
src="diagram.js"></script>` plays it where the tag is. To play `.dottie` files directly, a page loads dottie.js and
uses `<dottie-player src="diagram.dottie">`; https://dottie.phin.tech/dottie-js/ has its attributes, events and the
npm package.

## Extensions

New shapes, commands and drawing tools written in JavaScript are extensions; the `dottie-extension` skill covers
writing one (`npx skills add phin-tech/dottie --skill dottie-extension`).
