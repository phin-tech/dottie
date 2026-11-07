---
status: accepted
---

# Traffic flows are routed by the players from the page's state at each frame

A page can declare **flows**: traffic from one shape to one of a list of destinations, preferred first. Packets aren't
stored as elements. Every renderer works them out while it poses a frame (`DottieDocument.posed`, `posed` in
`web/src/timeline.ts`). At time `t`, with the page's variable values, it finds the cheapest route over the
connectors still drawn to the first destination that can be reached, and places a dot every `every` seconds along that
route at `speed` points per second. When a click takes a region down, its shapes and connectors go, the route changes,
and the traffic flows round the survivors. Nobody drew that state. This turns "draw each state" into "describe the
system and let people poke it", which a slide tool can't do.

## Decision

- **Model.** `DottieDocument.flows: [Flow]?`. A `Flow` has `id`, `from` (a shape), `to` (shapes in order of
  preference), `every` (seconds between packets, default 0.5), `speed` (points per second, default 160), `color`,
  `size` and `when`. A flow whose `when` fails sends nothing.
- **The graph.** It's built from the connectors in the posed frame, after timeline visibility and state have removed
  what they remove. Both ends must be bound to shapes still drawn. A connector runs from its start to its end, and
  also backwards when its start has an arrowhead. Each connector has a `cost` (1 unless set, clamped to 0…1,000,000)
  and the route is the cheapest (Dijkstra). With no costs set that's the fewest hops, which is often not the path a
  reader calls the main one: give the main path a lower cost, or the backup a higher one. Ties go to the shape
  reached first, earlier connectors in z-order first, so Swift and TypeScript pick the same route.
- **Packets are a pure function of (t, values).** Packet `k` leaves at `k × every` for every whole `k`, negative
  ones included, so the page starts with traffic already in flight. It sits `(t − k × every) × speed` along the route
  and is drawn while that's within the route's length. Nothing is carried between frames. So the frame at any `t`
  is the same in the app, the CLI, QuickLook, the drawn-ahead HTML player and dottie.js, and the goldens prove it. The
  pattern repeats every `every` seconds, so a timeline whose length is a multiple of it loops seamlessly;
  `add_flow` / `dottie.flow` round `every` to make that so.
- **Flows from the same shape take turns.** The i-th of m flows leaving a shape (in page order, conditions ignored)
  sends its packets `i/m × every` later, so flows split across regions interleave instead of drawing on top of each
  other, and a flow's color says where it was meant to go even after it fails over.
- **Packets are plain ellipses** with ids derived from the flow's id and `k`, so the web player's per-element SVG groups
  stay put from frame to frame. They're drawn above everything, on `from`'s layer, clean (roughness 0).
- **The editor** shows flows as it shows packets from `send_packet`: while playing.

## Considered and rejected

- **Simulated state carried between frames** (in-flight packets that finish their old route when a link goes down).
  It looks better at the moment of change, but no frame can be drawn without replaying everything before it. Exports,
  scrubbing and goldens all depend on drawing any frame from scratch. Today a packet in flight jumps to the new route.
- **Click handlers in JavaScript at play time.** That's the most flexible option, but drawings play on other people's
  sites, and ADR 0001 keeps extension code out of every renderer. Flows, variables and overrides stay declarative.
- **Weights, capacities, queues and drops.** Not yet. Flows say where traffic goes, not how much. `every` and `speed`
  are presentation.
