// Animation (Timeline.swift, Motion.swift): a page posed at a moment. `resolved(page, t)` is the still drawing
// every renderer draws, exactly as DottieDocument.resolved(at:) works it out.

import { endpoints, indexOf, routePoints, route } from "./connector.ts";
import { angle, rotated } from "./element.ts";
import {
  BOIL_DRAWINGS, type CameraKey, type Ease, type Element, type Follow, type Keyframe, type Page, type RGBA, type Timeline,
  type Track, clampFPS, clampTime, cloneElement, repeatIsValid, sameColor,
} from "./model.ts";
import { Polyline, roundHalfAway, type Point, type Rect } from "./path.ts";
import { boiled } from "./rng.ts";
import { dashPattern, outline } from "./shapes.ts";

export function applyEase(ease: Ease, u: number): number {
  switch (ease) {
    case "linear": return u;
    case "easeIn": return u * u * u;
    case "easeOut": return 1 - Math.pow(1 - u, 3);
    case "easeInOut": return u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2;
    case "hold": return 0;
    case "spring": return spring(u);
    case "bounce": return bounce(u);
    case "elastic": return elastic(u);
  }
}

/** A damped spring released from rest, nudged so it is exactly 1 at the end. */
function spring(u: number): number {
  if (u <= 0) return 0;
  if (u >= 1) return 1;
  const s = (u: number): number => 1 - Math.exp(-6 * u) * (Math.cos(3 * Math.PI * u) + (6 / (3 * Math.PI)) * Math.sin(3 * Math.PI * u));
  return s(u) + u * (1 - s(1));
}

/** Robert Penner's ease-out bounce: four arcs, each landing on 1. */
function bounce(u: number): number {
  if (u <= 0) return 0;
  if (u >= 1) return 1;
  const n = 7.5625, d = 2.75;
  if (u < 1 / d) return n * u * u;
  if (u < 2 / d) { const v = u - 1.5 / d; return n * v * v + 0.75; }
  if (u < 2.5 / d) { const v = u - 2.25 / d; return n * v * v + 0.9375; }
  const v = u - 2.625 / d;
  return n * v * v + 0.984375;
}

/** Robert Penner's ease-out elastic. */
function elastic(u: number): number {
  if (u <= 0) return 0;
  if (u >= 1) return 1;
  return Math.pow(2, -10 * u) * Math.sin((u * 10 - 0.75) * ((2 * Math.PI) / 3)) + 1;
}

/** Swift's truncatingRemainder. */
const rem = (a: number, b: number): number => a % b;

/** The time inside the track's own keys that `t` plays (repeats folded back). */
export function localTime(track: Track, t: number): number {
  const reps = (track.repeats ?? []).filter(repeatIsValid).slice().sort((a, b) => a.start - b.start);
  if (reps.length === 0) return t;
  for (const r of reps) {
    if (!(t >= r.end)) continue;
    const length = r.end - r.start;
    if (r.count === null) return r.start + rem(t - r.start, length);
    const played = length * r.count;
    if (t < r.start + played) return r.start + rem(t - r.start, length);
    t -= played - length;
  }
  return t;
}

type Prop = "x" | "y" | "width" | "height" | "rotation" | "strokeWidth" | "reveal" | "opacity";

function value<V>(track: Track, t: number, get: (k: Keyframe) => V | undefined, base: V, lerp: (a: V, b: V, u: number) => V): V {
  t = localTime(track, t);
  let before: Keyframe | undefined, after: Keyframe | undefined;
  for (const k of track.keys) {
    if (get(k) === undefined) continue;
    if (k.t <= t) before = k; else { after = k; break; }
  }
  if (!before && !after) return base;
  if (before && !after) return get(before)!;
  if (!before && after) return get(after)!;
  const b = before!, a = after!;
  const u = a.t - b.t > 0 ? (t - b.t) / (a.t - b.t) : 1;
  return lerp(get(b)!, get(a)!, applyEase(b.ease ?? "linear", u));
}

const lerpNum = (a: number, b: number, u: number): number => a + (b - a) * u;
// Springy eases overshoot: a color can't go past white or black.
const mix01 = (a: number, b: number, u: number): number => Math.min(Math.max(a + (b - a) * u, 0), 1);
const lerpColor = (a: RGBA, b: RGBA, u: number): RGBA => ({
  r: mix01(a.r, b.r, u), g: mix01(a.g, b.g, u), b: mix01(a.b, b.b, u), a: mix01(a.a, b.a, u),
});

function num(track: Track, t: number, p: Prop, base: number): number {
  return value(track, t, (k) => k[p], base, lerpNum);
}

/** Whether some property is tweening at `t`: between two keys that set it to different values, not held. */
export function isChanging(track: Track, t: number): boolean {
  t = localTime(track, t);
  const changing = <V>(get: (k: Keyframe) => V | undefined, eq: (a: V, b: V) => boolean): boolean => {
    let b: Keyframe | undefined;
    for (const k of track.keys) if (k.t <= t && get(k) !== undefined) b = k;
    const a = track.keys.find((k) => k.t > t && get(k) !== undefined);
    if (!b || !a) return false;
    return b.ease !== "hold" && !eq(get(b)!, get(a)!);
  };
  const n = (p: Prop) => changing((k) => k[p], (a, b) => a === b);
  return n("x") || n("y") || n("width") || n("height") || n("rotation") || n("strokeWidth")
    || changing((k) => k.stroke, sameColor) || changing((k) => k.fill, sameColor) || n("reveal") || n("opacity");
}

/** Whether the element is shown at `t`. */
export function isVisible(track: Track, t: number): boolean {
  t = localTime(track, t);
  const keyed = track.keys.filter((k) => k.visible !== undefined);
  if (keyed.length === 0) return true;
  let last: Keyframe | undefined;
  for (const k of keyed) if (k.t <= t) last = k;
  return last ? last.visible! : !keyed[0].visible!;
}

/** `e` posed at `t` (returns a copy). */
export function applyTrack(track: Track, e: Element, t: number): Element {
  e = cloneElement(e);
  if (track.keys.some((k) => k.reveal !== undefined)) {
    const r = num(track, t, "reveal", e.reveal ?? 1);
    e.reveal = r >= 1 ? null : Math.max(0, r);
  }
  if (track.keys.some((k) => k.opacity !== undefined)) {
    const o = Math.min(Math.max(num(track, t, "opacity", e.style.opacity ?? 1), 0), 1);
    e.style.opacity = o >= 1 ? null : o;
  }
  if (e.kind === "connector") return e;
  e.x = num(track, t, "x", e.x); e.y = num(track, t, "y", e.y);
  // Nor can a size or a line width go below nothing.
  e.width = Math.max(0, num(track, t, "width", e.width)); e.height = Math.max(0, num(track, t, "height", e.height));
  if (track.keys.some((k) => k.rotation !== undefined)) e.rotation = num(track, t, "rotation", angle(e));
  e.style.strokeWidth = Math.max(0, num(track, t, "strokeWidth", e.style.strokeWidth));
  e.style.stroke = value(track, t, (k) => k.stroke, e.style.stroke, lerpColor);
  e.style.fill = value(track, t, (k) => k.fill, e.style.fill, lerpColor);
  return e;
}

/** The path span placing the element at `t`, unless an x or y key after it has taken the element back. */
export function followSpan(track: Track, t: number): Follow | null {
  t = localTime(track, t);
  let f: Follow | null = null;
  for (const s of track.follow ?? []) if (s.start <= t && (f === null || s.start > f.start)) f = s;
  if (!f) return null;
  const span = f;
  if (track.keys.some((k) => k.t >= span.end && k.t <= t && (k.x !== undefined || k.y !== undefined))) return null;
  return f;
}

/** The clean route of a connector, or the clean, rotated outline of any other element. */
export function tracing(e: Element, page: Page): Polyline {
  if (e.kind === "connector") return new Polyline(routePoints(route(e, indexOf(page))));
  const clean = cloneElement(e);
  clean.style.roughness = 0;
  const pts = outline(clean).contours()[0] ?? [];
  return new Polyline(angle(e) === 0 ? pts : pts.map((p) => rotated(e, p)));
}

/** `e` moved onto the path it is following at `t`, if any. `page` has every key applied. */
export function following(track: Track, e: Element, t: number, page: Page): Element {
  const f = followSpan(track, t);
  if (!f) return e;
  t = localTime(track, t);
  const pathElement = page.elements.find((x) => x.id === f.path);
  if (!pathElement || pathElement.id === e.id) return e;
  const line = tracing(pathElement, page);
  const span = f.end - f.start;
  // An overshooting ease stops at the end of the path rather than wrapping round to its start.
  let u = Math.min(Math.max(applyEase(f.ease ?? "easeInOut", span > 0 ? Math.min(1, (t - f.start) / span) : 1), 0), 1) * (f.laps ?? 1);
  if (u > 1) u = rem(u, 1) === 0 ? 1 : rem(u, 1);
  if (f.reverse === true) u = 1 - u;
  const p = line.point(u);
  const moved = cloneElement(e);
  moved.x = p.x - e.width / 2;
  moved.y = p.y - e.height / 2;
  if (f.orient === true) {
    const step = f.reverse === true ? -0.01 : 0.01;
    const a = line.point(u - step / 2), b = line.point(u + step / 2);
    if (a.x !== b.x || a.y !== b.y) moved.rotation = Math.atan2(b.y - a.y, b.x - a.x);
  }
  return moved;
}

/** Where the dashes of a line marching at `speed` stand at `t`, within one pattern `period` (Timeline.marchOffset):
 * the speed is rounded to a whole number of patterns over the timeline, so a loop is seamless. */
export function marchOffset(tl: Timeline, speed: number, period: number, t: number): number {
  if (!(period > 0)) return 0;
  const d = clampTime(tl.duration);
  if (d > 0) {
    const laps = roundHalfAway((speed * d) / period);
    if (laps !== 0) speed = (laps * period) / d;
  }
  const r = rem(speed * t, period);
  // Positive phase pulls the pattern back towards the start, so going forward is a falling phase.
  return r < 0 ? -r : r === 0 ? 0 : period - r;
}

/** Tracks by element; when two name the same element the first wins. */
function trackMap(tl: Timeline): Map<string, Track> {
  const m = new Map<string, Track>();
  for (const t of tl.tracks) if (!m.has(t.element)) m.set(t.element, t);
  return m;
}

/** The page as a still drawing at `t` seconds (DottieDocument.resolved(at:)). A page without a timeline is returned as is. */
export function resolved(page: Page, t: number): Page {
  const timeline = page.timeline;
  if (!timeline) return page;
  t = clampTime(t);
  const tracks = trackMap(timeline);
  const reseed = timeline.boil === null ? null
    : (Math.trunc(Math.floor(t * clampFPS(timeline.fps) + 1e-9) / Math.max(1, timeline.boil)) % BOIL_DRAWINGS) >>> 0;
  const hidden = new Set<string>();
  for (const tr of tracks.values()) if (!isVisible(tr, t)) hidden.add(tr.element);
  let moving: Set<string> | null = null;
  if (timeline.settle === true) {
    moving = new Set();
    for (const tr of tracks.values()) if (isChanging(tr, t)) moving.add(tr.element);
  }
  const boils = (e: Element): boolean => {
    const override = tracks.get(e.id)?.boil;
    if (override !== undefined && override !== null) return override;
    if (!moving) return true;
    if (e.connector) return [e.connector.start.elementID, e.connector.end.elementID].some((id) => id !== null && moving!.has(id));
    return moving.has(e.id);
  };
  let elements = page.elements.map((e) => {
    const track = tracks.get(e.id);
    let out = track ? applyTrack(track, e, t) : e;
    if (reseed !== null && reseed > 0 && boils(e)) {
      if (out === e) out = cloneElement(e);
      out.seed = boiled(e.seed, reseed);
    }
    const pattern = track?.march != null ? dashPattern(out.style.dash, out.style.strokeWidth) : null;
    if (track?.march != null && pattern) {
      if (out === e) out = cloneElement(e);
      out.style.dashOffset = marchOffset(timeline, track.march, pattern.reduce((a, b) => a + b, 0), t);
    }
    return out;
  });
  // A hidden shape waits at its resting place, not at the start of the entrance it is about to make.
  elements = elements.map((e, i) => (hidden.has(e.id) ? page.elements[i] : e));
  // Paths are traced where their shapes are posed at `t`, so follows go after every key is applied.
  const posed: Page = { ...page, elements, timeline: null };
  elements = elements.map((e) => {
    const track = tracks.get(e.id);
    return track ? following(track, e, t, posed) : e;
  });
  // A connector goes with either shape it is attached to, unless it has visible keys of its own; then both its
  // ends are pinned where they are now.
  const current: Page = { ...page, elements, timeline: null };
  const index = indexOf(current);
  const gone = new Set(hidden);
  elements = elements.map((e) => {
    const c = e.connector;
    if (!c || ![c.start.elementID, c.end.elementID].some((id) => id !== null && hidden.has(id))) return e;
    if (!(tracks.get(e.id)?.keys.some((k) => k.visible !== undefined) ?? false)) { gone.add(e.id); return e; }
    const [a, b] = endpoints(e, index);
    const pinned = cloneElement(e);
    pinned.connector!.start = { elementID: null, port: c.start.port, x: a.x, y: a.y };
    pinned.connector!.end = { elementID: null, port: c.end.port, x: b.x, y: b.y };
    return pinned;
  });
  return { ...page, elements: elements.filter((e) => !gone.has(e.id)), timeline: null };
}

/** The moment a still picture of the page shows: its poster, else the end. */
export function posterTime(page: Page): number {
  return page.timeline ? (page.timeline.poster ?? page.timeline.duration) : 0;
}

/** The page as a still picture (its poster frame when animated). */
export function still(page: Page): Page {
  return page.timeline ? resolved(page, posterTime(page)) : page;
}

// MARK: Camera, frames and scenes

export function cameraRect(tl: Timeline, t: number): Rect | null {
  const keys = tl.camera ?? [];
  if (keys.length === 0) return null;
  let before: CameraKey | undefined;
  for (const k of keys) if (k.t <= t) before = k;
  const after = keys.find((k) => k.t > t);
  if (!before) return rectOf(keys[0]);
  if (!after) return rectOf(before);
  const u = applyEase(before.ease ?? "easeInOut", (t - before.t) / Math.max(after.t - before.t, 1e-9));
  const mix = (p: number, q: number) => p + (q - p) * u;
  // A springy ease can overshoot a zoom past nothing.
  return { x: mix(before.x, after.x), y: mix(before.y, after.y), width: Math.max(1, mix(before.width, after.width)), height: Math.max(1, mix(before.height, after.height)) };
}

const rectOf = (k: CameraKey): Rect => ({ x: k.x, y: k.y, width: k.width, height: k.height });

/** What exports show at `t`: the camera's view widened (never cropped) to the first key's shape. */
export function cameraView(tl: Timeline, t: number): Rect | null {
  const first = tl.camera?.[0];
  const r = cameraRect(tl, t);
  if (!first || !r || !(r.width > 0 && r.height > 0)) return null;
  return fit(r, first.width / first.height);
}

/** `r` widened about its center to the width-to-height ratio `aspect`. */
export function fit(r: Rect, aspect: number): Rect {
  if (!(r.width > 0 && r.height > 0 && aspect > 0)) return r;
  let w = r.width, h = r.height;
  if (r.width / r.height < aspect) w = r.height * aspect; else h = r.width / aspect;
  return { x: r.x + r.width / 2 - w / 2, y: r.y + r.height / 2 - h / 2, width: w, height: h };
}

export function frameCount(tl: Timeline): number {
  return Math.max(1, Math.ceil(clampTime(tl.duration) * clampFPS(tl.fps)));
}

/** The times exports and playback draw: every frame, plus the end when it falls between frames. */
export function frameTimes(tl: Timeline): number[] {
  const fps = clampFPS(tl.fps);
  const times: number[] = [];
  for (let i = 0; i < frameCount(tl); i++) times.push(i / fps);
  const last = times[times.length - 1];
  if (tl.duration - last > 1e-6) times.push(tl.duration);
  return times;
}

/** The index of the last scene marker at or before `t`, or -1. */
export function sceneAt(tl: Timeline, t: number): number {
  let s = -1;
  (tl.markers ?? []).forEach((m, i) => { if (m.t <= t) s = i; });
  return s;
}

/** Elements that only exist in motion: hidden at the start and in the still (packets, mostly). */
export function transientElements(page: Page): Set<string> {
  const tl = page.timeline;
  if (!tl) return new Set();
  const end = tl.poster ?? tl.duration;
  return new Set(tl.tracks.filter((tr) => !isVisible(tr, 0) && !isVisible(tr, end)).map((tr) => tr.element));
}

export type { Point };
