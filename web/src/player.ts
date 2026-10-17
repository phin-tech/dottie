// <dottie-player>: plays a .dottie file in the page, drawn live from its source, with the controls of Dottie's
// HTML export (play, scrub, scenes, keys, reduced motion).
//
//   <script type="module" src="https://…/dottie-player.js"></script>
//   <dottie-player src="tour.dottie"></dottie-player>
//
// Attributes: src (a .dottie URL), page (name or 1-based number, default the first), at (seconds: show that
// moment as a still), clean (draw without the sketchy look), no-controls, no-autoplay, no-loop, label (the
// accessible name). The file can also be inline: <dottie-player><script type="application/json">{…}</script>.
//
// Clickable elements (`click` in the file, or a `link` to another page) play their scene, open their link or show
// that page, by mouse or keyboard. Each click first fires a cancelable `action` event with the element and what it
// does, so a page can handle it itself.

import { CLICK_STYLE, type Click, buttonLabel, clickTargets, hasHover, hovered } from "./clicks.ts";
import { type DottieFile, type Page, type RGBA, luminance, parseDottie } from "./model.ts";
import { fmt } from "./path.ts";
import { type Plan, plan, svgParts } from "./svg.ts";
import { color } from "./svg-util.ts";
import { themeNamed } from "./theme.ts";
import { posterTime, resolved } from "./timeline.ts";

const WHITE: RGBA = { r: 1, g: 1, b: 1, a: 1 };

/** Finds a page by name (any case) or 1-based number; the first page when `spec` is empty or matches nothing. */
export function pageIndex(file: DottieFile, spec: string | null | undefined): number {
  const s = (spec ?? "").trim();
  if (!s) return 0;
  const byName = file.pages.findIndex((p) => p.name.toLowerCase() === s.toLowerCase());
  if (byName >= 0) return byName;
  const n = Number(s);
  return Number.isInteger(n) && n >= 1 && n <= file.pages.length ? n - 1 : 0;
}

export function withRoughness(page: Page, roughness: number): Page {
  return { ...page, elements: page.elements.map((e) => ({ ...e, style: { ...e.style, roughness } })) };
}

const STYLE = `
:host { display: block; position: relative; color: var(--dottie-ink); background: var(--dottie-page);
  font: 14px -apple-system, system-ui, sans-serif; border-radius: var(--dottie-radius, 0); }
:host([hidden]) { display: none; }
.stage { display: block; width: 100%; height: auto; }
.stage svg { display: block; width: 100%; height: auto; margin: 0 auto; }
.bar { display: flex; align-items: center; gap: 12px; padding: 8px 12px 12px; max-width: 560px; margin: 0 auto; box-sizing: border-box; }
.bar[hidden] { display: none; }
button { font: inherit; color: inherit; background: none; border: 1.5px solid currentColor; border-radius: 6px;
  width: 34px; height: 30px; cursor: pointer; flex: none; padding: 0; }
button:focus-visible, input:focus-visible { outline: 2px solid currentColor; outline-offset: 2px; }
input[type=range] { flex: 1; min-width: 60px; accent-color: currentColor; }
output { font-variant-numeric: tabular-nums; min-width: 4.5em; text-align: right; }
.scene { min-width: 0; flex: 0 1 auto; text-align: center; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.error { padding: 16px; font-family: ui-monospace, Menlo, monospace; white-space: pre-wrap; }
${CLICK_STYLE}`;

/** Plays one page of a Dottie file into an element: the engine behind <dottie-player>, usable on its own. */
export class Playback {
  readonly page: Page;
  readonly plan: Plan;
  readonly scenes: number[];
  readonly sceneNames: string[];
  readonly background: RGBA;
  readonly ink: RGBA;
  /** What clicking each clickable element does, by element id. */
  readonly clicks: Map<string, Click>;
  private hoverIDs: Set<string>;
  private labels = new Map<string, string>();
  private svg: SVGSVGElement;
  private groups = new Map<string, { g: SVGGElement; markup: string }>();
  private order: string[] = [];
  frame = -1;
  onFrame: ((frame: number) => void) | null = null;

  /** `file` is the drawing `page` belongs to, so links to its other pages are clickable. */
  constructor(page: Page, into: Element, options: { clean?: boolean; file?: DottieFile } = {}) {
    this.page = options.clean ? withRoughness(page, 0) : page;
    this.plan = plan(this.page);
    this.clicks = clickTargets(page, options.file);
    this.hoverIDs = new Set(this.page.elements.filter((e) => this.clicks.has(e.id) && hasHover(e)).map((e) => e.id));
    for (const e of this.page.elements) if (this.clicks.has(e.id)) this.labels.set(e.id, buttonLabel(e));
    const near = (t: number): number => {
      let best = 0;
      this.plan.times.forEach((x, i) => { if (Math.abs(x - t) < Math.abs(this.plan.times[best] - t)) best = i; });
      return best;
    };
    this.scenes = (page.timeline?.markers ?? []).map((m) => near(m.t));
    this.sceneNames = (page.timeline?.markers ?? []).map((m) => m.name);
    const theme = themeNamed(page.theme);
    this.background = theme?.background ?? WHITE;
    this.ink = theme?.ink ?? { r: 0.12, g: 0.12, b: 0.13, a: 1 };
    const ns = "http://www.w3.org/2000/svg";
    this.svg = document.createElementNS(ns, "svg");
    this.svg.setAttribute("width", fmt(this.plan.size.width));
    this.svg.setAttribute("height", fmt(this.plan.size.height));
    // As large as the drawing at 1:1, smaller to fit.
    this.svg.style.maxWidth = `${Math.ceil(this.plan.size.width)}px`;
    into.replaceChildren(this.svg);
  }

  get frameCount(): number { return this.plan.times.length; }
  get posterFrame(): number {
    const t = posterTime(this.page);
    let best = 0;
    this.plan.times.forEach((x, i) => { if (Math.abs(x - t) < Math.abs(this.plan.times[best] - t)) best = i; });
    return best;
  }

  /** Draws frame `i`, replacing only the pieces whose markup changed since the last frame. */
  show(i: number): void {
    const n = this.frameCount;
    i = ((i % n) + n) % n;
    this.drawAt(this.plan.times[i], i);
    this.frame = i;
    this.onFrame?.(i);
  }

  /** Draws the moment `t` (seconds) in the frame-`i` view. */
  drawAt(t: number, i = 0): void {
    const r = this.plan.rects[Math.min(i, this.plan.rects.length - 1)];
    const frame = resolved(this.page, t);
    const { parts } = svgParts(frame, this.background, r);
    // A clickable element with a hover look holds both, and the stylesheet shows one.
    const hover = this.hoverIDs.size === 0 ? null
      : new Map(svgParts(hovered(frame, this.hoverIDs), this.background, r).parts.filter((p) => this.hoverIDs.has(p.key)).map((p) => [p.key, p.markup]));
    this.svg.setAttribute("viewBox", `${fmt(r.x)} ${fmt(r.y)} ${fmt(r.width)} ${fmt(r.height)}`);
    const ns = "http://www.w3.org/2000/svg";
    const keys = parts.map((p) => p.key);
    for (const p of parts) {
      let markup = p.markup;
      const h = hover?.get(p.key);
      if (h !== undefined && h !== markup) markup = `<g class="dottie-n">\n${markup}</g>\n<g class="dottie-h">\n${h}</g>\n`;
      const have = this.groups.get(p.key);
      if (have) {
        if (have.markup !== markup) { have.g.innerHTML = markup; have.markup = markup; }
      } else {
        const g = document.createElementNS(ns, "g") as SVGGElement;
        g.innerHTML = markup;
        // The group stays from frame to frame, so keyboard focus on it does too.
        if (this.clicks.has(p.key)) {
          g.setAttribute("class", "dottie-a");
          g.setAttribute("data-a", p.key);
          g.setAttribute("tabindex", "0");
          g.setAttribute("role", "button");
          g.setAttribute("aria-label", this.labels.get(p.key) ?? "");
        }
        this.groups.set(p.key, { g, markup });
      }
    }
    const live = new Set(keys);
    for (const [k, v] of this.groups) if (!live.has(k)) { v.g.remove(); this.groups.delete(k); }
    if (keys.length !== this.order.length || keys.some((k, j) => k !== this.order[j])) {
      // Only what is new or out of place moves, so a group with keyboard focus keeps it while others come and go.
      let at: ChildNode | null = this.svg.firstChild;
      for (const k of keys) {
        const g = this.groups.get(k)!.g;
        if (g === at) at = at.nextSibling;
        else this.svg.insertBefore(g, at);
      }
      while (at) { const next: ChildNode | null = at.nextSibling; at.remove(); at = next; }
      this.order = keys;
    }
  }

  /** The scene frame `i` is in, or -1 before the first. */
  sceneAt(i: number): number {
    let s = -1;
    this.scenes.forEach((f, j) => { if (f <= i) s = j; });
    return s;
  }
}

/** HTMLElement where there is a DOM; a stand-in elsewhere, so the library still loads in Node (to render SVG). */
const ElementBase: typeof HTMLElement = typeof HTMLElement === "undefined" ? (class {} as unknown as typeof HTMLElement) : HTMLElement;

export class DottiePlayer extends ElementBase {
  static observedAttributes = ["src", "page", "at", "clean", "no-controls", "label"];

  file: DottieFile | null = null;
  playback: Playback | null = null;
  private root: ShadowRoot;
  private stage: HTMLDivElement;
  private bar: HTMLDivElement;
  private playButton: HTMLButtonElement;
  private scrub: HTMLInputElement;
  private time: HTMLOutputElement;
  private sceneLabel: HTMLOutputElement;
  private prev: HTMLButtonElement;
  private next: HTMLButtonElement;
  private playing = false;
  private last = 0;
  private acc = 0;
  private raf = 0;
  private loadToken = 0;
  private visible = true;
  private observer: IntersectionObserver | null = null;

  constructor() {
    super();
    this.root = this.attachShadow({ mode: "open" });
    this.root.innerHTML = `<style>${STYLE}</style><div class="stage" part="stage" role="img"></div>
<div class="bar" part="controls" hidden>
<button class="play" aria-label="Play">▶</button>
<button class="prev" aria-label="Previous scene" hidden>⏮</button>
<output class="scene" hidden></output>
<button class="next" aria-label="Next scene" hidden>⏭</button>
<input class="scrub" type="range" min="0" max="0" value="0" aria-label="Frame">
<output class="time">0.0s</output>
</div>`;
    const q = <T extends Element>(s: string) => this.root.querySelector(s) as T;
    this.stage = q(".stage");
    this.bar = q(".bar");
    this.playButton = q(".play");
    this.scrub = q(".scrub");
    this.time = q(".time");
    this.sceneLabel = q(".scene");
    this.prev = q(".prev");
    this.next = q(".next");
    this.playButton.onclick = () => {
      const p = this.playback;
      if (p && !this.playing && p.scenes.length && p.frame >= p.frameCount - 1) p.show(0);
      this.setPlaying(!this.playing);
    };
    this.scrub.oninput = () => { this.setPlaying(false); this.playback?.show(Number(this.scrub.value)); };
    this.next.onclick = () => this.nextScene();
    this.prev.onclick = () => this.prevScene();
    this.stage.addEventListener("click", (e) => {
      const b = clickable(e.target);
      if (b) this.activate(b.getAttribute("data-a") ?? "");
    });
    this.addEventListener("keydown", (e) => this.key(e));
  }

  connectedCallback(): void {
    if (!this.hasAttribute("tabindex")) this.tabIndex = 0;
    if ("IntersectionObserver" in window) {
      this.observer = new IntersectionObserver((entries) => { this.visible = entries.some((e) => e.isIntersecting); this.schedule(); });
      this.observer.observe(this);
    }
    void this.load();
  }

  disconnectedCallback(): void {
    cancelAnimationFrame(this.raf);
    this.raf = 0;
    this.observer?.disconnect();
  }

  attributeChangedCallback(name: string, old: string | null, value: string | null): void {
    if (old === value || !this.isConnected) return;
    if (name === "src") void this.load();
    else if (name === "label") this.stage.setAttribute("aria-label", value ?? "");
    else if (this.file) this.mount();
  }

  /** Loads from `src`, or from an inline JSON script child. */
  async load(): Promise<void> {
    const token = ++this.loadToken;
    try {
      let text: string;
      const src = this.getAttribute("src");
      if (src) {
        const res = await fetch(src);
        if (!res.ok) throw new Error(`${src}: ${res.status} ${res.statusText}`);
        text = await res.text();
      } else {
        const inline = this.querySelector('script[type="application/json"], script[type="application/vnd.dottie+json"]');
        if (!inline) return;
        text = inline.textContent ?? "";
      }
      if (token !== this.loadToken) return;
      this.setFile(parseDottie(text));
    } catch (err) {
      if (token !== this.loadToken) return;
      this.stage.innerHTML = "";
      const box = document.createElement("div");
      box.className = "error";
      box.textContent = `Couldn't show this drawing: ${(err as Error).message}`;
      this.stage.append(box);
      this.dispatchEvent(new CustomEvent("error", { detail: err }));
    }
  }

  /** Shows an already-parsed file. */
  setFile(file: DottieFile): void {
    this.file = file;
    for (const w of file.warnings) console.warn(`dottie-player: ${w}`);
    this.mount();
    this.dispatchEvent(new CustomEvent("load", { detail: { file } }));
  }

  private mount(): void {
    const file = this.file!;
    const page = file.pages[pageIndex(file, this.getAttribute("page"))];
    const p = new Playback(page, this.stage, { clean: this.hasAttribute("clean"), file });
    this.playback = p;
    this.style.setProperty("--dottie-page", color(p.background));
    this.style.setProperty("--dottie-ink", color(p.ink));
    // Controls follow the drawing's page color, not the surrounding site's light or dark scheme.
    this.style.colorScheme = luminance(p.background) < 0.5 ? "dark" : "light";
    this.stage.setAttribute("aria-label", this.getAttribute("label") ?? page.name);
    const at = this.getAttribute("at");
    const animated = page.timeline !== null && p.frameCount > 1 && at === null;
    this.bar.hidden = !animated || this.hasAttribute("no-controls");
    const scenes = p.scenes.length > 0;
    this.prev.hidden = this.next.hidden = this.sceneLabel.hidden = !scenes;
    this.scrub.max = String(p.frameCount - 1);
    p.onFrame = (i) => {
      this.scrub.value = String(i);
      this.time.textContent = `${p.plan.times[i].toFixed(1)}s`;
      if (scenes) { const s = p.sceneAt(i); this.sceneLabel.textContent = s < 0 ? "" : p.sceneNames[s]; }
      this.dispatchEvent(new CustomEvent("frame", { detail: { frame: i, time: p.plan.times[i] } }));
    };
    if (!animated) {
      p.drawAt(at !== null ? Number(at) || 0 : posterTime(page), at !== null ? nearest(p, Number(at) || 0) : p.posterFrame);
      this.setPlaying(false);
      return;
    }
    p.show(0);
    const reduced = typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduced) { p.show(p.posterFrame); this.setPlaying(false); return; }
    this.setPlaying(!this.hasAttribute("no-autoplay") && !p.scenes.includes(0));
  }

  // MARK: Playback

  get paused(): boolean { return !this.playing; }
  get currentTime(): number { const p = this.playback; return p && p.frame >= 0 ? p.plan.times[p.frame] : 0; }
  set currentTime(t: number) { const p = this.playback; if (p) { this.setPlaying(false); p.show(nearest(p, t)); } }
  get duration(): number { return this.playback?.page.timeline?.duration ?? 0; }

  play(): void { this.setPlaying(true); }
  pause(): void { this.setPlaying(false); }

  /** Plays on to the next scene (from the start after the last). */
  nextScene(): void {
    const p = this.playback;
    if (!p) return;
    if (p.frame >= p.frameCount - 1) p.show(0);
    this.setPlaying(true);
  }

  /** Back to the start of this scene, or the one before if already there. */
  prevScene(): void {
    const p = this.playback;
    if (!p) return;
    let s = p.sceneAt(p.frame);
    if (s >= 0 && p.scenes[s] === p.frame) s -= 1;
    this.setPlaying(false);
    p.show(s >= 0 ? p.scenes[s] : 0);
  }

  /** Does what clicking element `id` does: jumps to its scene and plays on to the next (with reduced motion, or in a
   * still, straight to where that stops), opens its link in a new tab, or shows its page. */
  activate(id: string): void {
    const p = this.playback;
    const click = p?.clicks.get(id);
    if (!p || !click) return;
    if (!this.dispatchEvent(new CustomEvent("action", { detail: { element: id, ...click }, cancelable: true }))) return;
    if ("url" in click) {
      if (/^(https?:|mailto:)/i.test(click.url)) window.open(click.url, "_blank", "noopener");
    } else if ("page" in click) {
      this.setAttribute("page", String(click.page + 1));
    } else if (click.scene >= 0 && click.scene < p.scenes.length) {
      const reduced = typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
      if (reduced || this.hasAttribute("at") || p.frameCount < 2) {
        this.setPlaying(false);
        p.show(click.scene + 1 < p.scenes.length ? p.scenes[click.scene + 1] : p.frameCount - 1);
      } else {
        p.show(p.scenes[click.scene]);
        this.setPlaying(true);
      }
    }
  }

  private setPlaying(on: boolean): void {
    const p = this.playback;
    this.playing = on && !!p && p.frameCount > 1 && p.page.timeline !== null;
    this.playButton.textContent = this.playing ? "❚❚" : "▶";
    this.playButton.setAttribute("aria-label", this.playing ? "Pause" : "Play");
    this.last = 0;
    this.acc = 0;
    this.schedule();
  }

  private schedule(): void {
    if (this.playing && this.visible && !this.raf && this.isConnected) this.raf = requestAnimationFrame((now) => this.tick(now));
  }

  /** Steps whole frames at the timeline's rate; with scenes, playing stops at each one and at the end. */
  private tick(now: number): void {
    this.raf = 0;
    const p = this.playback;
    if (!this.playing || !p) return;
    const step = 1000 / (p.page.timeline?.fps ?? 12);
    if (this.last) this.acc += Math.min(now - this.last, 1000);
    this.last = now;
    let advanced = false;
    while (this.playing && this.acc >= step) {
      this.acc -= step;
      const next = p.frame + 1;
      if (next >= p.frameCount && (p.scenes.length || this.hasAttribute("no-loop"))) { this.setPlaying(false); break; }
      p.frame = next % p.frameCount;
      advanced = true;
      if (p.scenes.includes(p.frame)) { this.setPlaying(false); break; }
    }
    if (advanced) p.show(p.frame);
    if (this.playing && !this.visible) this.last = 0;
    this.schedule();
  }

  private key(e: KeyboardEvent): void {
    const p = this.playback;
    // From inside the shadow root the event's target is this element; the path has what really has focus.
    const target = e.composedPath()[0];
    const b = clickable(target);
    if (p && b && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); this.activate(b.getAttribute("data-a") ?? ""); return; }
    if (!p || p.page.timeline === null || p.frameCount <= 1 || this.hasAttribute("at")) return;
    if (target === this.scrub && e.key !== " ") return;
    const scenes = p.scenes.length > 0;
    let handled = true;
    if (e.key === " ") scenes ? (this.playing ? this.setPlaying(false) : this.nextScene()) : this.setPlaying(!this.playing);
    else if (e.key === "ArrowRight") { if (scenes) this.nextScene(); else { this.setPlaying(false); p.show(p.frame + 1); } }
    else if (e.key === "ArrowLeft") { if (scenes) this.prevScene(); else { this.setPlaying(false); p.show(p.frame - 1); } }
    else if (e.key === ".") { this.setPlaying(false); p.show(p.frame + 1); }
    else if (e.key === ",") { this.setPlaying(false); p.show(p.frame - 1); }
    else handled = false;
    if (handled) e.preventDefault();
  }
}

/** The clickable element an event happened in, if any. */
function clickable(target: EventTarget | null): globalThis.Element | null {
  const el = target as globalThis.Element | null;
  return el && typeof el.closest === "function" ? el.closest(".dottie-a") : null;
}

function nearest(p: Playback, t: number): number {
  let best = 0;
  p.plan.times.forEach((x, i) => { if (Math.abs(x - t) < Math.abs(p.plan.times[best] - t)) best = i; });
  return best;
}

/** Registers <dottie-player> (or another tag name) once. */
export function definePlayer(tag = "dottie-player"): void {
  if (typeof customElements !== "undefined" && !customElements.get(tag)) customElements.define(tag, class extends DottiePlayer {});
}
