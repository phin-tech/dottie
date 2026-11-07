---
status: accepted
---

# Capacity, metrics and gauges are worked out per frame, and drawn as plain elements

Flows (ADR 0002) say where traffic goes. People draw systems that carry things (requests through services,
messages through queues, freight through hubs) to answer three more questions: how much goes each way, what
happens when something is full, and how long it takes. The model stays generic: the same fields describe an SQS
queue in front of a worker pool and a sort center in front of a linehaul lane. This ADR adds **volume**, **capacity** and
**delay** to the model; one **metrics** function that works out, for any frame, the load and transit time they
imply; and **gauges**, which show a metric. All of it follows ADR 0002's rule: each frame is a pure function of
the page, the time and the variables. So exports, scrubbing and goldens keep working, and Swift and TypeScript
have to agree exactly.

**This is presentation, not a modelling language.** Dottie draws and plays diagrams. Volume, capacity and delay are
there so a diagram can *show* a scenario (a region going down, a queue backing up, a lane filling) with numbers
that make the story legible; they're illustrative, chosen by whoever draws it. Nothing here predicts how a real
system behaves, and features are judged by whether they make a diagram clearer, not more realistic: steady rates
rather than queueing theory, a greedy assignment a reader can follow rather than an optimal one.

## Decision

### The model

- **Volume** (`Flow.volume`, default 1): how much a flow carries, in whatever unit the page uses (requests a
  second, messages a minute, trucks a day). Packets stay a picture of it. Packet spacing is `every / volume`,
  clamped as `every` is, so a flow with three times the volume draws three times the packets.
- **Capacity** (`capacity` on a connector or a shape; absent means unlimited): the most volume it carries: a
  worker pool's throughput, a rate limit, a lane's trucks a day. A shape's capacity counts traffic arriving at it
  as well as passing through: a saturated service or a full warehouse turns work away either way.
- **Delay** (`delay` seconds on a shape, default 0): how long traffic stays inside a shape it passes through:
  processing time, time in a queue, time on a dock. Packets already vanish inside such a shape. With a delay they
  stay hidden that much longer, so a slow step is visibly slow. A flow's source and destinations have no delay.
  Delay is fixed: it doesn't grow with load (an override can raise it).
- **Overrides** may set `capacity` and `delay`, as they already set `cost`: "half the workers down" or "lane at
  half capacity" is one `defineState`. A "traffic spike" or "peak season" is an extra flow with `when: spike`.

### Assignment: where the volume goes

Each frame, after state has been applied, the page's flows are assigned to routes:

1. Flows are taken in page order. **Page order is priority.**
2. A flow's volume goes onto its cheapest route (ADR 0002's routing), as much as the route has room for. The room
   is the smallest leftover capacity of any connector or shape on it, ends included.
3. Any connector or shape that is now full is treated as offline for the rest of this flow, and the remainder goes
   onto the next cheapest route. This repeats until the volume is placed or nothing has room.
4. Volume that can't be placed is **backlog**. It waits at the shape just before the first full connector or
   shape on the flow's cheapest route: messages pile up in the queue in front of busy consumers, freight at the
   hub in front of a full lane. Since volume is a rate, backlog is too: how fast that queue grows (40 messages a second
   more than the consumers take). It's counted at that shape and drawn as packets bunched there. Nothing is
   carried over to the next frame, so the frame shows the growth rate, not a depth that has built up.
5. `spread` fits the same scheme: while the first destination is down, the volume is shared equally across the
   others that can be reached, each share placed as in 2 and 3.

The result is a list of (route, fraction of the flow) pairs per flow. Packets are dealt across them by fraction
with a deterministic dealing on the packet number `k`: route `r` takes the packets for which
`floor((k + 1) × f_r) − floor(k × f_r) = 1` over the cumulative fractions. That's the same arithmetic in both
languages, and with one route it's every packet.

### Metrics

`metrics(page, t, values)` is one function in each language (`Metrics.swift`, `web/src/measure.ts`). It returns,
from the assignment:

- per connector and shape: **throughput** (volume through it), **load** (throughput ÷ capacity) and **delay**,
  and per shape the **backlog** growing at it;
- per flow: **placed** and **backlog** volume, **share via backup** (the fraction not reaching its first
  destination) and **transit** (route length ÷ speed plus the delays on the way, weighted by fraction);
- per connector: **in flight**, the packets on it at `t`. This is the only metric counted from the frame rather than
  from the steady state.

Metrics are **steady-state**: they come from configured volumes, not from counting packets drawn in a window. So
they're exact, they don't flicker, and they only change when the state does.

### Conditions on metrics, for looks only

Conditions gain comparisons against metrics: `load(workers) > 0.9`, `backlog(orders) > 0` and so on. An element
is named by its `anchor`, the hidden label that already exists for linking. That's how a saturated service or a full lane turns red: an
override with that condition and a red stroke.

To avoid a loop (a metric depends on what's drawn and routed, and the condition would change what's drawn and
routed), **a condition that mentions a metric may only change looks**: `stroke`, `fill`, `textColor`,
`opacity`, `strokeWidth`, `dash` and `text`. It can't drive `when`, `offline`, `cost`, `capacity`, `delay`,
`reroute` or flows. Posing runs in two passes:

1. variables only: visibility, routing, assignment, metrics;
2. the metric-conditioned look overrides.

A file that breaks this rule loads, and the offending override does nothing. Variables stay booleans.

### Gauges

A gauge is a rectangle with a `gauge` field: `{metric, of, max?, warn?, alarm?, style: number | bar | dial,
label?}`. When the page is posed, it's replaced by plain elements: a frame, a bar or an arc and needle as clean
paths, and a text with the value. The fill is green, amber at `warn` and red at `alarm`.

No renderer learns to draw a gauge. The app, QuickLook, the CLI and dottie.js keep drawing rectangles, paths and
text, which is the same reason extension shapes store their path (ADR 0001). A renderer that predates gauges draws
the plain rectangle.

### Exposure

- Script: `dottie.metrics()` and `dottie.gauge(target, {metric, …})`, plus `volume`, `capacity` and `delay` where
  look fields go.
- MCP: `add_gauge`, the same fields on `add_flow` and `update_element`, and the metrics in `list_elements` and in
  each step of `simulate`.

These are data. Reports, imports (lane tables, queue configs) and maps are for agents and scripts to build from them.

### What sits on top, with no format change

Buttons, exclusive choices, reset and the flow legend are authoring helpers. Each writes ordinary elements, clicks
and overrides:

- **Button:** a pill, a click that toggles a variable, and an override for its pressed look and label.
- **Choice:** one boolean variable per option, and each option's click `set`s its own on and the others off.
- **Reset:** a click `set`ting every variable to its starting value. It's rewritten when variables change.
- **Legend:** one swatch per flow, toggling a variable joined onto that flow's `when`.

None of them depends on this ADR. A legend or a button can show a gauge's metric in its label once gauges exist.

## Considered and rejected

- **Optimal assignment (min-cost flow, LP).** Better routing on paper, but it's opaque to someone reading the
  diagram ("why did 12% go to the backup region?"), small changes can swing the answer, and it's much harder to keep
  identical across two languages. A greedy assignment in page order is explainable: earlier flows have priority.
- **Sampled metrics (counting packets drawn in a window).** These flicker, depend on frame rate, and disagree
  between a 30 fps export and a 60 fps player.
- **Queues and backlog carried between frames.** That's realistic, but any frame would depend on every frame
  before it, which ADR 0002 already rejected for packets. Backlog is reported as the rate a queue grows at, which is
  steady; a depth that builds up while you watch would need history.
- **Numeric variables and sliders.** These would need numeric conditions on variables, arithmetic in state, and a
  slider control. Metric comparisons cover the visual cases. A slider can be faked as a row of choice buttons.
- **A gauge element kind.** Every renderer, the app's canvas and hit-testing included, would need to learn it.
  Expanding gauges into plain elements while posing keeps them as data.
