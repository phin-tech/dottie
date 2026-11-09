---
status: accepted
---

# Containers are rectangles that their children name

Diagrams of systems need boxes that hold things: a VPC, a subsystem, a team's lane. Groups (`groupID`) are flat and
invisible, `add_group` draws a frame once that doesn't follow what it framed, Mermaid subgraphs are flattened on
import, and `build_diagram` can't say "these live together".

## Decision

- **A container is a rectangle with `container` data** (`fixed`, `lanes`), titled by its text. Its title sits in a
  band at the top, which is its `labelRect`; the two renderers already place a label there, so they draw containers
  with no other change. Older versions draw a titled rectangle.
- **A child names its container** (`containerID`), the way an element names its layer or group, so nesting is a
  chain and moving something in or out edits only it. The container is drawn behind what it holds.
- **The rules live in one reconcile pass** (`reconcilingContainers(from:)`), run on every app commit, after each MCP
  tool and at the end of a script, as palette names are (ADR 0005):
  - a container that moved takes what it holds;
  - one resized by hand becomes `fixed` and keeps that size;
  - a shape moved, or a new one placed, joins the innermost container under its center, and one moved out leaves;
  - containers that aren't fixed fit round their contents, innermost first, with room for the title.
- **A swimlane is a container with `lanes`** (rows or columns) whose children are containers, its lanes. They are
  stacked across it and stretched to the widest or tallest, and each lane takes its contents along when it moves.
- **Connectors bind to a container like any shape.** Traffic flows treat it as a shape too.

## Considered

- **A new element kind.** Every renderer would need a case, and older versions would drop the element.
- **The container lists its children.** Every move in or out would edit two elements, and ids could dangle.

## Consequences

- Drawing needs only the stored frame and title band, so a file edited by hand outside Dottie can show a container
  that doesn't fit its contents until Dottie edits it.
- `add_group`'s frames stay as they were; they are drawn once and don't hold anything.
