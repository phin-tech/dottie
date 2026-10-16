# Dottie

<img src="Design/icon-1024.png" width="128" alt="Dottie">

**Diagrams that look hand-drawn, on your Mac, and your AI assistant can draw them for you.**

Sketch a flowchart, a system diagram or a whiteboard idea in seconds. Switch to a clean, precise look when it
needs to go in a document. Or just ask Claude to draw it, and watch the shapes appear.

![A signup flowchart drawn in Dottie's sketchy style](Design/example.png)

## Get Dottie

With [Homebrew](https://brew.sh):

```sh
brew install --cask phin-tech/tap/dottie
```

Or download the latest `Dottie-x.y.z.zip` from [Releases](https://github.com/phin-tech/dottie/releases), unzip
it, and drag **Dottie** into your Applications folder. You need macOS 14 Sonoma or later.

Dottie checks GitHub once a day and tells you when a new version is out (turn that off in Settings ▸ General,
or use Dottie ▸ Check for Updates… any time). It never updates itself: with Homebrew, run
`brew upgrade --cask dottie`; otherwise download the new version.

## Ask your AI assistant to draw

Dottie works with Claude and other assistants that support MCP (a standard way for assistants to use apps).
Once connected, you can say things like:

- *"Draw our deployment pipeline as a left-to-right diagram."*
- *"Add a staging step between build and deploy."*
- *"Make a second page with the database tables, and link the Database box to it."*
- *"Make it clean instead of sketchy and save it as an SVG."*

The assistant lays the diagram out, looks at the result, and tidies anything that reads badly.

### Connect it once

Open Dottie, then **Dottie ▸ Settings… ▸ MCP**. Under *Add to an MCP client*:

- **Claude Desktop** (and most other apps): click **Copy** next to the JSON snippet, paste it into the
  app's MCP settings file, and restart the app. In Claude Desktop that file is under
  Settings ▸ Developer ▸ Edit Config.
- **Claude Code:** click **Copy** next to the command, and run it once in Terminal.

If you move Dottie to a different folder later, copy the snippet again.

### Watch it draw

Keep the drawing open in Dottie while you chat, and every change appears in the window as the assistant makes
it. Each change can be undone with ⌘Z, like your own. Save when you like the result. You can tell the assistant
to work on "the drawing I have open", or give it a file path. If Dottie isn't running, the assistant edits the
file directly and you see the result next time you open it.

## Draw it yourself

Pick a tool from the toolbar or press its letter:

| Key | Tool | | Key | Tool |
|---|---|---|---|---|
| V | Select | | T | Text |
| R | Rectangle | | C | Connector |
| O | Ellipse | | P | Pencil |
| D | Diamond | | E | Eraser |
| N | Note | | | |

Double-click a shape to give it a label. Connectors stay attached when you move shapes around.

- **Sticky notes.** Click with the Note tool (or drag out a size) and type GitHub Flavored Markdown:
  headings, bullet, numbered and `- [ ]` task lists, tables, quotes, code, links, and **bold**, *italic*,
  `code` and ~~struck~~ text. A new line in the text is a new line in the note, as in GitHub comments. Return
  starts a new line and Tab / ⇧Tab indent or outdent it; ⇧Return, ⌘Return, Escape or clicking away finishes,
  and the note shows the rendered text. Click a ☐ to tick it off, and pick a note color from the swatches in the
  inspector.

- **Sketchy or clean.** The inspector on the right switches the look, and sets colors, fill patterns,
  dashed lines and arrowheads. Themes like Blueprint and Chalkboard change the whole page.
- **Dungeon maps.** The Grid fill pattern turns a shape into a dungeon room: the floor is ruled into squares
  (set the cell size in the inspector) and the rock around it gets Dyson-style hatching. Rooms on the same
  grid line up cell for cell, and rooms that touch don't hatch over each other.
- **Pages.** Big diagram? Split it into pages, shown as tabs along the bottom. Click **+** to add one,
  double-click a tab to rename it, drag tabs to reorder them.
- **Links.** Make a shape jump to another one, even on another page: select it and choose a target under
  **Jumps to**. Click the little arrow badge to go there, and ⌘[ to come back. Great for a summary page that
  links to the details.
- **Pictures.** Paste a screenshot or a copied image (⌘V), drop image files on the canvas, or use
  File ▸ Insert Image… (⌥⌘I). Pictures are saved inside the drawing; give one a stroke color in the inspector
  for a sketchy border.
- **Shape library.** The Library tab has flowchart symbols and common shapes ready to drag in. Add your own
  from SVG files or from shapes you've drawn.
- **Layers, rulers and guides** for when things need to line up exactly (⇧⌘R shows the rulers).
- **Bring diagrams in** from Excalidraw, draw.io or SVG files (File menu, or drop them on the canvas).
  Mermaid flowcharts come in laid out: File ▸ Import Mermaid…, drop a `.mmd` file, or copy the text
  (starting with `flowchart` or `graph`) and paste it with ⌘V. Subgraphs come in without their frames.
- **Send diagrams out** as PNG, SVG or PDF with File ▸ Export As, or as Mermaid text for a README or wiki
  (boxes, diamonds, circles and the arrows between them; freehand drawing and pictures are left out).
- **Peek without opening.** Select a drawing in Finder and press Space to see every page; Finder icons show the drawing itself.

## Make it move

![An architecture diagram drawing itself, arrows sketching out and dots running along them](Design/animation.gif)

Any page can be animated, and exported as a GIF, an animated PNG (full color, optionally transparent), an MP4
([this one](Design/animation.mp4)), a web page with a play button, or Lottie: vector animation for websites and
iOS and Android apps, either smooth (tweened by the player) or exact (every frame as Dottie draws it). The Animate menu does the common things in one go:

- **Build Diagram** reveals the shapes in the order the arrows connect them, sketching each one in, drawing
  the arrows out, or sending a dot along each arrow to the next shape.
- **Add Transition** gives the selected shapes an entrance, an exit or a bit of emphasis: pop, grow, wipe,
  drop, slide, draw or fade in, the same ways out, and pulse or wiggle.
- **Send Packet Along Arrow** runs a dot down the selected arrows, like a request on its way.
- **March Selected Lines** sets the dashes of the selected arrows travelling along them, like marching ants,
  for a live stream or the direction of a flow.
- **Magic Move to Next Page** works like Keynote's: draw the start and the end as two pages, and Dottie
  animates the first into the second. Shapes with the same anchor or text, or copies made by Duplicate Page,
  slide, resize and recolor into place; whatever is only on one page fades out or in.
- **Boil Lines** makes the sketchy lines jitter like hand-drawn animation; **Settle When Still** calms them
  once a shape stops moving.
- **Repeat Selection's Animation** plays a shape's animation over and over, like a light that keeps pulsing.
- **Frame Camera on Selection** points the export's view at the selected shapes from that moment on, so a big
  diagram can pan and zoom from one part to the next. While stopped on the timeline, drag the dashed camera
  frame's edge to move the view, or a corner to resize it. **Add Scene Marker** names a stop: the web page export
  then pauses at each scene and steps through them with its next and back buttons, like slides.

The timeline under the canvas shows every animated shape with its keyframes. Press play to watch, or drag
along it to scrub. Stop on any moment and change the drawing there, moving, resizing or recoloring a
shape, and Dottie remembers that pose for that moment and moves smoothly between poses. Drag a keyframe to
retime it, ⌥-drag to copy it, and pick its easing from the bar above: smooth in and out, or a spring, a
bounce or an elastic snap that overshoots and settles. **Onion Skin** shows the moments just
before and after, faintly.

Assistants can animate too: ask for *"a version of this diagram that builds itself, with a request moving
through it"*, *"send a POST /orders packet from the client every second"*, or *"zoom in on each service in turn,
as scenes"*, then *"export it as a GIF"*.

**[Play the demos in your browser](https://phin-tech.github.io/dottie/demos/)**: a camera that
[zooms through a checkout flow](Design/demos/zoom.gif), a [click-through tour](Design/demos/tour.gif) of the
diagram above, [labelled requests and events](Design/demos/labels.gif) (`POST /orders`, `order.created`),
[traffic that never stops](Design/demos/live.gif), and a sprint board whose notes
[pop in one after another](Design/demos/stagger.gif). Each is made by a short script in
[scripts/demos](scripts/demos).

## Extras for power users

- **Scripting.** Script ▸ Script Console… (⌥⌘J) runs JavaScript to draw or change many things at once, such as
  a grid of boxes or restyling everything labelled "TODO". The console includes a full reference.
- **Command line.** Homebrew installs a `dottie` command; otherwise Settings ▸ Command Line does, so you can turn drawings into images
  from Terminal: `dottie render diagram.dottie -o diagram.png`, or `-o diagram.gif` (or `.apng`,
  `.mp4`, or `.json` for Lottie) for an animated page. Run `dottie --help` for more.

## Help and feedback

Found a bug or have an idea? [Open an issue](https://github.com/phin-tech/dottie/issues). Want to build Dottie
yourself or contribute? See [DEVELOPMENT.md](DEVELOPMENT.md).

## License

Dottie is free and open source under the [Apache License 2.0](LICENSE).
