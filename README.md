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

Dottie updates itself: once a day it checks GitHub for a newer release and offers to install it and relaunch
(turn that off in Settings ▸ General, or use Dottie ▸ Check for Updates… any time). Updates are notarized and
checked against a signing key built into the app. To try new features before they ship, turn on Get beta
versions in the same place. With Homebrew, `brew upgrade --greedy --cask dottie` also works.

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

To teach your assistant Dottie's tools and command line, and how to write extensions, install the skills too (for
Claude Code, Codex, Cursor and other assistants that read skills):

```sh
npx skills add phin-tech/dottie
```

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
| N | Note | | H | Highlighter |
| | | | X | Redact |

Double-click a shape to give it a label. Connectors stay attached when you move shapes around. To route one
around something, select it and drag the small circle halfway along it to add a bend (on an elbow line, drag a
segment sideways); double-click a bend to remove it. **Hop over crossings**, in the inspector, draws a little arc
where the line crosses another, so crossing lines don't look joined. The arrow keys nudge the selection a point at
a time (⇧ for ten); holding one down is a single undo step.

- **Flowcharts from the keyboard.** Select a rectangle, ellipse or diamond and hold ⌘ while you press an arrow
  key: a copy appears that way, joined to it by an arrow. Press the arrow again (still holding ⌘) for another
  beside it, and let go of ⌘ to keep them (Escape, before you let go, drops them). The newest is selected, so
  Return names it. ⌥-arrow walks from shape to shape along the arrows (press it again to step through a
  decision's branches), Tab turns the selected shapes into the next kind (rectangle, diamond, ellipse), and ⇧1
  zooms to fit the whole page.

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
  links to the details. A shape can also open a web page, an email, or another drawing: type an address in
  **Opens**, or click **Choose Drawing…** and pick where in it to land under **At** (one of its anchors, or a
  page). Give a shape an anchor and it shows up in the **Anchors** tab, a table of contents for the drawing.
  Exported PDFs and SVGs keep the links clickable.
- **Pictures.** Paste a screenshot or a copied image (⌘V), drop image files on the canvas, or use
  File ▸ Insert Image… (⌥⌘I). Pictures are saved inside the drawing; give one a stroke color in the inspector
  for a sketchy border. Screenshots (PNG and other lossless pictures) keep their full resolution, up to 8192
  pixels across, so small text stays sharp when you zoom in; photos are trimmed to 2048.
- **Mark up screenshots.** The Highlighter (H) draws a wide, see-through yellow stroke; change its color or
  width or opacity in the inspector afterwards. Redact (X): drag a box over a picture and the part it covers is pixelated
  in the picture itself, so the original pixels are gone from the file and every export. Only the copy you
  drag over changes, and ⌘Z brings it back while the drawing is open.
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

Any page can be animated. File ▸ Export Animation saves it as a GIF, an animated PNG (like a GIF, in full color),
an MP4 ([this one](Design/animation.mp4)), a web page with a play button, or Lottie: vector animation for websites
and iOS and Android apps, smooth (tweened by the player) or exact (every frame as Dottie draws it).
The Animate menu does the common things in one go:

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
- **Symbols**, like Flash's movie clips: select some shapes and choose Arrange ▸ Convert to Symbol (F8). They
  become one drawing, defined once with its own animation, which you can place again and again. Every copy plays
  that animation on its own clock: over and over, once, or standing still, and from any point in it, so a row of
  status lights can blink out of step. Double-click a copy (or Arrange ▸ Edit Symbol) to change the symbol itself,
  and every copy follows; Break Apart (⌘B) turns a copy back into plain shapes. A symbol added to a library plays
  wherever it is placed. Tick **Button** in its inspector section to make a Flash-style button: draw its up, over
  and down looks as scenes inside it (and a hit scene for where it takes clicks), and on the web it changes under
  the pointer and while pressed. A plain symbol's copy can instead play its animation when clicked, in
  `<dottie-player>`.
- **When Clicked on the Web**, in the inspector, makes a shape a button in the web page export and in
  `<dottie-player>`: a click plays a scene on to the next one, or opens a link. Give it a hover color too.
  A diagram can then wait for the reader to pick which request to follow.

The timeline under the canvas shows every animated shape with its keyframes. Press play to watch, or drag
along it to scrub. Stop on any moment and change the drawing there, moving, resizing or recoloring a
shape, and Dottie remembers that pose for that moment and moves smoothly between poses. Drag a keyframe to
retime it, ⌥-drag to copy it, and pick its easing from the bar above: smooth in and out, or a spring, a
bounce or an elastic snap that overshoots and settles. **Onion Skin** shows the moments just
before and after, faintly.

Assistants can animate too: ask for *"a version of this diagram that builds itself, with a request moving
through it"*, *"send a POST /orders packet from the client every second"*, or *"zoom in on each service in turn,
as scenes"*, then *"export it as a GIF"*.

**[Play the demos in your browser](https://dottie.phin.tech/demos/)**: a camera that
[zooms through a checkout flow](Design/demos/zoom.gif), a [click-through tour](Design/demos/tour.gif) of the
diagram above, [labelled requests and events](Design/demos/labels.gif) (`POST /orders`, `order.created`),
[traffic that never stops](Design/demos/live.gif), a sprint board whose notes
[pop in one after another](Design/demos/stagger.gif), the same board two days on by
[Magic Move](Design/demos/board.gif), an event stream whose arrows [march](Design/demos/stream.gif), a diagram that plays
[the request you click](Design/demos/flows.dottie), and heartbeat lights and cogs placed as
[symbols](Design/demos/symbols.gif), each on its own clock. Each is made by a short script in
[scripts/demos](scripts/demos).

## Extras for power users

- **Scripting.** Script ▸ Script Console… (⌥⌘J) runs JavaScript to draw or change many things at once, such as
  a grid of boxes or restyling everything labelled "TODO". The console includes a full reference. The scripts
  folder has TypeScript declarations (`dottie.d.ts`) for completion in an editor, and with TypeScript installed
  (`npm install -g typescript`) the console and the MCP server's `run_script` point out misspelled options.
- **Extensions.** An extension adds shapes drawn by JavaScript (with handles to adjust them), commands in the
  Extensions menu, and drawing tools in the toolbar. Put a `.dottieext` folder in the extensions folder
  (Settings ▸ Extensions ▸ Show in Finder, then Reload), or have your assistant install one over MCP. Extensions
  can't read files or use the network, and the shapes they draw are saved as ordinary paths, so a drawing opens the
  same without them. Start from [extension-template](extension-template), whose Ribbon pen is a drawing tool; its
  `dottie-extension` skill walks an assistant through writing one.
- **Command line.** Homebrew installs a `dottie` command; otherwise Settings ▸ Command Line does, so you can turn drawings into images
  from Terminal: `dottie render diagram.dottie -o diagram.png`, or `-o diagram.gif` (or `.apng`,
  `.mp4`, or `.json` for Lottie) for an animated page. Run `dottie --help` for more.

## Help and feedback

Found a bug or have an idea? [Open an issue](https://github.com/phin-tech/dottie/issues). Want to build Dottie
yourself or contribute? See [DEVELOPMENT.md](DEVELOPMENT.md).

## License

Dottie is free and open source under the [Apache License 2.0](LICENSE).
