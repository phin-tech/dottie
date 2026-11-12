---
status: accepted
---

# Scenarios unfold with the timeline's `time`; crossing a condition on it is a state change

> Amends [ADR 0003](0003-capacity-metrics-gauges.md) and [ADR 0007](0007-expressions-and-click-logic.md).

Interactive pages change when the reader clicks. Many of the scenarios people draw also change by themselves as the
page plays: a daily run landing at 13:05, traffic ramping up over the morning, a batch tapering off. Before this, the
only way to show that was a click per step, or extra flows and elements switched by the timeline's keys, which can't
change volumes, capacities or conditions.

## Decision

- **`time` is a built-in name.** On a page with a timeline, conditions, flows' volumes and `{...}` text read `time`, the
  timeline's time in seconds (`DottieDocument.timed`, `timed` in `web/src/state.ts`). A page variable called `time`
  takes its place, so old pages mean what they did. A frame is still a pure function of its inputs: `t` was already
  one, and `time` is `t` handed to expressions.
- **A flow's volume can be an expression** of the variables and `time`, in the flow or an override:
  `"clamp((time - 15) * 180, 0, 3400)"`. It's saved as a string where a number would be. One that can't be read, or
  reads a metric, is 0. Expression volumes and overrides whose condition reads `time` change as the page plays. Such a
  flow sends packet k when the packets it has sent since the start reach k (summed in 0.05-second steps and kept),
  so the packets on their way stay where they are as its rate changes. Packet spacing still comes from the page's
  biggest flow, with an expression measured at `time` 0, so the other flows don't respace either.
- **A flow override can set `to`**, so "the router sends this caller elsewhere" is one flow. Its queue then drains to
  where it goes now, not to a destination it no longer uses.
- **Crossing a condition on `time` is a state change.** When the set of conditions that read `time` and hold changes
  between frames (`timeRegime`), the player and `simulate` carry the queues and gauge readings over and restart
  `since`, as they do for a click. So gauges ease, queues drain and backlog counts from the moment the scenario
  changed. A volume expression that changes continuously isn't a state change. Exports of stills and goldens carry
  nothing, as before.
- **`clock(seconds)`** is a function that returns its argument. Text showing `{clock(...)}` shows a time of day,
  `13:05:00`, round the clock.
- **A slots gauge** shows a metric as a grid of squares, one per unit of its `max` (the target's capacity by
  default; for load, the capacity). It's filled in each flow's color for what that flow delivers through the target
  (`FrameMetrics.byFlow`), in a fixed scattered order so a growing flow takes new squares and the others keep
  theirs. Squares the reading is still easing toward are pale. Past 2,400 squares, or squares under 3 points, each
  square stands for more and the label says so.
- **The player has a speed** (`speed` attribute and a button: 0.5×, 1×, 2×, 4×, 8×), which scales the page's time
  and `since` together.

## Considered

- **Integrating backlog over a time-varying rate**, so depth is exact as volumes ramp. Depth stays backlog × `since`,
  as ADR 0003 has it. Crossings restart `since`, which keeps stepped scenarios right. Continuous ramps are only
  approximately right, which is enough to illustrate.
- **A separate scenario clock** with a start time and rate. The timeline already is the scenario's clock, with
  pause, seeking, looping and exports. `clock(time * 20 + 13 * 3600)` maps it onto a time of day.
- **Timeline keys that set variables.** That would mean a second way to change state, with its own editor. A
  condition on `time` says the same thing where the reader looks for it.
