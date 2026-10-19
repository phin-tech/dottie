// The .dottie format, read the way DottieKit reads it: the same defaults, clamps, filters and sorting, so a
// damaged or hand-written file means the same thing in both. Anything dottie.js doesn't know (a newer kind,
// fill or field) is kept and reported through `warnings` instead of failing the whole file.

export interface RGBA { r: number; g: number; b: number; a: number }
export type FillStyle = "solid" | "hachure" | "crossHatch" | "grid";
export type DashStyle = "solid" | "dashed" | "dotted";
export type ElementKind = "rectangle" | "ellipse" | "diamond" | "text" | "connector" | "freehand" | "path" | "note" | "image" | "symbol";
export type SymbolPlayback = "loop" | "once" | "still" | "click";
export type Port = "top" | "right" | "bottom" | "left";
export type Routing = "straight" | "curved" | "elbow";
export type Arrowhead = "none" | "arrow" | "triangle" | "dot" | "bar";
export type Ease = "linear" | "easeIn" | "easeOut" | "easeInOut" | "hold" | "spring" | "bounce" | "elastic";

export interface Style {
  stroke: RGBA;
  fill: RGBA;
  fillStyle: FillStyle;
  strokeWidth: number;
  dash: DashStyle;
  roughness: number;
  bowing: number;
  fontSize: number;
  /** The font text is set in: null is Helvetica Neue, else a bundled handwriting font or one of the viewer's own. */
  font: string | null;
  gridSize: number | null;
  opacity: number | null;
  /** How far into its dash pattern a dashed or dotted line starts; marching ants set it on every frame. */
  dashOffset: number | null;
}

/** `portIndex` pins the end to one of the bound element's `ports`, and wins over `port`. */
export interface Endpoint { elementID: string | null; port: Port | null; portIndex?: number | null; x: number; y: number }
/** The shape an extension generated a path with. Read-only here: nothing runs in dottie.js. */
export interface ExtensionRef { id: string; shape: string; version: string; params: Record<string, number | boolean | string> }

export interface ConnectorData {
  start: Endpoint;
  end: Endpoint;
  routing: Routing;
  startHead: Arrowhead;
  endHead: Arrowhead;
}

export interface PathSubpath { closed: boolean; coords: number[] }
export interface StrokePoint { x: number; y: number }
export interface EmbeddedImage { data: string; format: string }
/** What clicking an element does in a played drawing: a scene to jump to and play on from, or a link. */
export interface ClickAction { scene: string | null; url: string | null }
/** How a clickable element looks under the pointer or with keyboard focus; null keeps its own. */
export interface HoverLook { stroke: RGBA | null; fill: RGBA | null; opacity: number | null }

export interface Element {
  id: string;
  /** A kind dottie.js doesn't know is kept as written and drawn as a labelled placeholder. */
  kind: ElementKind | string;
  x: number; y: number; width: number; height: number;
  style: Style;
  seed: number;
  layerID: string;
  text: string | null;
  connector: ConnectorData | null;
  groupID: string | null;
  points: StrokePoint[] | null;
  path: number[] | null;
  subpaths: PathSubpath[] | null;
  evenOdd: boolean | null;
  rotation: number | null;
  link: string | null;
  /** Where the element links outside the drawing (Element.url): a web address, or another drawing. Only web
   * addresses are followed here (`webLink`). */
  url: string | null;
  anchor: string | null;
  click: ClickAction | null;
  hover: HoverLook | null;
  /** For a `symbol` element: the page's symbol it shows, how it plays it, and from how far in. */
  symbol: string | null;
  playback: SymbolPlayback | null;
  offset: number | null;
  /** For a `symbol` element: its values for the symbol's parameters (Element.args). */
  args: Record<string, string> | null;
  /** Base64 bytes; an empty `data` is a picture that couldn't be found (drawn crossed out). */
  image: EmbeddedImage | null;
  reveal: number | null;
  /** For an extension shape: connection points and label box, normalized to the frame. */
  ports?: { x: number; y: number }[] | null;
  labelRect?: { x: number; y: number; width: number; height: number } | null;
  extension?: ExtensionRef | null;
}

export interface Layer { id: string; name: string; visible: boolean; locked: boolean }

export interface Keyframe {
  t: number;
  x?: number; y?: number; width?: number; height?: number;
  rotation?: number;
  strokeWidth?: number;
  stroke?: RGBA; fill?: RGBA;
  visible?: boolean;
  reveal?: number;
  opacity?: number;
  ease?: Ease;
}

export interface Follow {
  path: string;
  start: number; end: number;
  ease: Ease | null;
  reverse: boolean | null;
  orient: boolean | null;
  laps: number | null;
}

export interface Repeat { start: number; end: number; count: number | null }

export interface Track {
  element: string;
  keys: Keyframe[];
  boil: boolean | null;
  follow: Follow[] | null;
  repeats: Repeat[] | null;
  /** Marching ants: points per second the dashes travel (Track.march). */
  march: number | null;
}

export interface CameraKey { t: number; x: number; y: number; width: number; height: number; ease: Ease | null }
export interface Marker { t: number; name: string }

export interface Timeline {
  fps: number;
  duration: number;
  boil: number | null;
  settle: boolean | null;
  poster: number | null;
  tracks: Track[];
  camera: CameraKey[] | null;
  markers: Marker[] | null;
}

export interface Page {
  id: string;
  name: string;
  layers: Layer[];
  elements: Element[];
  theme: string | null;
  timeline: Timeline | null;
  symbols: Symbol[] | null;
}

/** A drawing defined once on a page and placed by `symbol` elements, with its own timeline (Symbol). */
export interface Symbol {
  id: string;
  name: string;
  width: number;
  height: number;
  layers: Layer[];
  elements: Element[];
  timeline: Timeline | null;
  /** A Flash-style button: copies show its up scene; on the web, over, down and hit (Symbol.button). */
  button: boolean | null;
  /** What each copy can fill in, by name, with defaults; `{{name}}` in its text (Symbol.params). */
  params: Record<string, string> | null;
}

export interface DottieFile {
  version: number;
  pages: Page[];
  /** What was skipped or guessed while reading. Empty for a file Dottie wrote. */
  warnings: string[];
}

/** The newest file version this library was written for. Newer files still load, with a warning. */
export const SUPPORTED_VERSION = 2;
export const KINDS: readonly string[] = ["rectangle", "ellipse", "diamond", "text", "connector", "freehand", "path", "note", "image", "symbol"];
const EASES: readonly string[] = ["linear", "easeIn", "easeOut", "easeInOut", "hold", "spring", "bounce", "elastic"];

/** The fields dottie.js reads, per object; the schema test checks they're exactly the schema's. Anything else
 * in a file is newer than this version and is reported in `warnings`. */
export const KNOWN_FIELDS: Record<string, readonly string[]> = {
  file: ["version", "pages", "images"],
  page: ["id", "name", "layers", "elements", "theme", "guidesX", "guidesY", "guidesLocked", "timeline", "symbols"],
  symbol: ["id", "name", "width", "height", "layers", "elements", "timeline", "button", "params"],
  layer: ["id", "name", "visible", "locked"],
  rgba: ["r", "g", "b", "a"],
  style: ["stroke", "fill", "fillStyle", "strokeWidth", "dash", "roughness", "bowing", "fontSize", "font", "gridSize", "opacity", "dashOffset"],
  element: ["id", "kind", "x", "y", "width", "height", "style", "seed", "layerID", "text", "connector", "groupID", "points",
    "path", "subpaths", "evenOdd", "rotation", "link", "url", "anchor", "click", "hover", "symbol", "playback", "offset", "args", "image", "reveal",
    "ports", "labelRect", "extension"],
  strokePoint: ["x", "y"],
  subpath: ["closed", "coords"],
  inlineImage: ["data", "format"],
  endpoint: ["elementID", "port", "portIndex", "x", "y"],
  extensionRef: ["id", "shape", "version", "params"],
  normalizedPoint: ["x", "y"],
  normalizedRect: ["x", "y", "width", "height"],
  connector: ["start", "end", "routing", "startHead", "endHead"],
  timeline: ["fps", "duration", "boil", "settle", "poster", "tracks", "camera", "markers"],
  track: ["element", "keys", "boil", "follow", "repeats", "march"],
  keyframe: ["t", "x", "y", "width", "height", "rotation", "strokeWidth", "stroke", "fill", "visible", "reveal", "opacity", "ease"],
  follow: ["path", "start", "end", "ease", "reverse", "orient", "laps"],
  repeat: ["start", "end", "count"],
  cameraKey: ["t", "x", "y", "width", "height", "ease"],
  marker: ["t", "name"],
  click: ["scene", "url"],
  hover: ["stroke", "fill", "opacity"],
};

export const MAX_DURATION = 3600;
/** The fastest march, points per second (Track.maxMarch). */
export const MAX_MARCH = 10_000;
export const clampMarch = (v: number | undefined): number | null =>
  v === undefined || !Number.isFinite(v) || v === 0 ? null : Math.min(Math.max(v, -MAX_MARCH), MAX_MARCH);
export const BOIL_DRAWINGS = 3;

export const black: RGBA = { r: 0.12, g: 0.12, b: 0.13, a: 1 };
export const clear: RGBA = { r: 0, g: 0, b: 0, a: 0 };
export const inkOnDark: RGBA = { r: 0.93, g: 0.93, b: 0.94, a: 1 };

export class DottieFormatError extends Error {}

type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
const num = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? v : undefined);
const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);
/** A map of strings, as Swift's [String: String]; anything else in it makes it nil. */
const strings = (v: unknown): Record<string, string> | null =>
  isObj(v) && Object.values(v).every((x) => typeof x === "string") ? { ...(v as Record<string, string>) } : null;
const bool = (v: unknown): boolean | undefined => (typeof v === "boolean" ? v : undefined);
/** UUIDs compare by value in Swift; uppercase them so string comparison agrees. */
const uuid = (v: unknown): string | undefined => (typeof v === "string" ? v.toUpperCase() : undefined);

export function clampTime(t: number): number {
  if (!Number.isFinite(t)) return t === Infinity ? MAX_DURATION : 0;
  return Math.min(Math.max(t, 0), MAX_DURATION);
}

export function clampFPS(f: number): number {
  return Number.isFinite(f) ? Math.min(Math.max(f, 1), 60) : 12;
}

/** `url` trimmed, if it is a link a page may open: http, https or mailto, as ClickAction.allowed. A drawing can
 * play on someone else's site, so nothing else (javascript:, data:) is ever followed. */
export function allowedURL(url: string): string | null {
  const u = url.trim();
  // eslint-disable-next-line no-control-regex
  if (!/^(https?:\/\/|mailto:)/i.test(u) || [...u].length <= 7 || /[\u0000-\u001f\u007f-\u009f]/.test(u)) return null;
  return u;
}

/** An element's `url`, if it is a web address (OutsideLink.webAddress); a link to another drawing gives null. */
export function webLink(url: string | null | undefined): string | null {
  return url ? allowedURL(url) : null;
}

function rgba(v: unknown): RGBA | undefined {
  if (!isObj(v)) return undefined;
  const r = num(v.r), g = num(v.g), b = num(v.b);
  if (r === undefined || g === undefined || b === undefined) return undefined;
  return { r, g, b, a: num(v.a) ?? 1 };
}

class Reader {
  warnings: string[] = [];
  private seen = new Set<string>();
  warn(message: string): void {
    if (!this.seen.has(message)) { this.seen.add(message); this.warnings.push(message); }
  }

  /** Reports fields this version doesn't read (they're ignored, as Dottie ignores them). */
  fields(v: Obj, kind: string): void {
    const known = KNOWN_FIELDS[kind];
    for (const k of Object.keys(v)) if (!known.includes(k)) this.warn(`Unknown field "${k}" on ${kind}, ignored`);
  }

  style(v: unknown): Style {
    const s = isObj(v) ? v : {};
    this.fields(s, "style");
    const fillStyle = str(s.fillStyle) ?? "solid";
    const dash = str(s.dash) ?? "solid";
    if (!["solid", "hachure", "crossHatch", "grid"].includes(fillStyle)) this.warn(`Unknown fill style "${fillStyle}", drawn solid`);
    if (!["solid", "dashed", "dotted"].includes(dash)) this.warn(`Unknown dash "${dash}", drawn solid`);
    return {
      stroke: rgba(s.stroke) ?? { ...black },
      fill: rgba(s.fill) ?? { ...clear },
      fillStyle: (["solid", "hachure", "crossHatch", "grid"].includes(fillStyle) ? fillStyle : "solid") as FillStyle,
      strokeWidth: num(s.strokeWidth) ?? 2,
      dash: (["solid", "dashed", "dotted"].includes(dash) ? dash : "solid") as DashStyle,
      roughness: num(s.roughness) ?? 1,
      bowing: num(s.bowing) ?? 1,
      fontSize: num(s.fontSize) ?? 18,
      font: str(s.font) || null,
      gridSize: num(s.gridSize) ?? null,
      opacity: num(s.opacity) ?? null,
      dashOffset: num(s.dashOffset) ?? null,
    };
  }

  endpoint(v: unknown): Endpoint {
    const e = isObj(v) ? v : {};
    const port = str(e.port);
    const portIndex = num(e.portIndex);
    return {
      elementID: uuid(e.elementID) ?? null,
      port: port && ["top", "right", "bottom", "left"].includes(port) ? (port as Port) : null,
      portIndex: portIndex !== undefined && Number.isInteger(portIndex) && portIndex >= 0 ? portIndex : null,
      x: num(e.x) ?? 0,
      y: num(e.y) ?? 0,
    };
  }

  connector(v: unknown): ConnectorData | null {
    if (!isObj(v)) return null;
    this.fields(v, "connector");
    const head = (h: unknown, d: Arrowhead): Arrowhead => {
      const s = str(h);
      return s && ["none", "arrow", "triangle", "dot", "bar"].includes(s) ? (s as Arrowhead) : d;
    };
    const routing = str(v.routing);
    return {
      start: this.endpoint(v.start),
      end: this.endpoint(v.end),
      routing: routing && ["straight", "curved", "elbow"].includes(routing) ? (routing as Routing) : "straight",
      startHead: head(v.startHead, "none"),
      endHead: head(v.endHead, "arrow"),
    };
  }

  image(v: unknown, table: Record<string, EmbeddedImage>): EmbeddedImage | null {
    if (!isObj(v)) return null;
    const ref = str(v.ref);
    if (ref !== undefined) return table[ref] ?? { data: "", format: "png" };
    const data = str(v.data);
    return data === undefined ? null : this.picture(data, str(v.format));
  }

  /** A picture's bytes, only if they really are base64: they go into an attribute of the drawn SVG. */
  picture(data: string, format: string | undefined): EmbeddedImage {
    if (!BASE64.test(data)) {
      this.warn("Skipped a picture whose data isn't base64");
      return { data: "", format: "png" };
    }
    return { data: data.replace(/\s+/g, ""), format: format === "jpeg" ? "jpeg" : "png" };
  }

  element(v: unknown, images: Record<string, EmbeddedImage>): Element | null {
    if (!isObj(v)) return null;
    this.fields(v, "element");
    const id = uuid(v.id), kind = str(v.kind), layerID = uuid(v.layerID);
    if (!id || !kind || !layerID) { this.warn("Skipped an element without an id, kind or layer"); return null; }
    if (!KINDS.includes(kind)) this.warn(`Unknown element kind "${kind}", drawn as a placeholder`);
    const subpaths = Array.isArray(v.subpaths)
      ? v.subpaths.filter(isObj).map((s) => ({ closed: bool(s.closed) ?? false, coords: Array.isArray(s.coords) ? s.coords.filter((c): c is number => typeof c === "number") : [] }))
      : null;
    return {
      id, kind, layerID,
      x: num(v.x) ?? 0, y: num(v.y) ?? 0, width: num(v.width) ?? 0, height: num(v.height) ?? 0,
      style: this.style(v.style),
      seed: (num(v.seed) ?? 1) >>> 0,
      text: str(v.text) ?? null,
      connector: this.connector(v.connector),
      groupID: uuid(v.groupID) ?? null,
      points: Array.isArray(v.points) ? v.points.filter(isObj).map((p) => ({ x: num(p.x) ?? 0, y: num(p.y) ?? 0 })) : null,
      path: Array.isArray(v.path) ? v.path.filter((c): c is number => typeof c === "number") : null,
      subpaths,
      evenOdd: bool(v.evenOdd) ?? null,
      rotation: num(v.rotation) ?? null,
      link: uuid(v.link) ?? null,
      url: str(v.url) ?? null,
      anchor: str(v.anchor) ?? null,
      click: this.click(v.click),
      hover: this.hover(v.hover),
      symbol: uuid(v.symbol) ?? null,
      playback: this.playback(v.playback),
      offset: num(v.offset) ?? null,
      args: strings(v.args),
      image: this.image(v.image, images),
      reveal: num(v.reveal) ?? null,
      ports: Array.isArray(v.ports) ? v.ports.map((p) => { const o: Obj = isObj(p) ? p : {}; return { x: num(o.x) ?? 0, y: num(o.y) ?? 0 }; }) : null,
      labelRect: this.labelRect(v.labelRect),
      extension: this.extension(v.extension),
    };
  }

  labelRect(v: unknown): { x: number; y: number; width: number; height: number } | null {
    if (!isObj(v)) return null;
    this.fields(v, "normalizedRect");
    return { x: num(v.x) ?? 0, y: num(v.y) ?? 0, width: num(v.width) ?? 0, height: num(v.height) ?? 0 };
  }

  extension(v: unknown): ExtensionRef | null {
    if (!isObj(v)) return null;
    this.fields(v, "extensionRef");
    const id = str(v.id), shape = str(v.shape), version = str(v.version);
    if (id === undefined || shape === undefined || version === undefined) {
      this.warn("Skipped an extension without an id, shape or version");
      return null;
    }
    const params: ExtensionRef["params"] = {};
    if (isObj(v.params)) {
      for (const [k, p] of Object.entries(v.params)) {
        if (typeof p === "number" || typeof p === "boolean" || typeof p === "string") params[k] = p;
      }
    }
    return { id, shape, version, params };
  }

  click(v: unknown): ClickAction | null {
    if (!isObj(v)) return null;
    this.fields(v, "click");
    const url = str(v.url);
    const safe = url === undefined ? null : allowedURL(url);
    if (url !== undefined && safe === null) this.warn("Skipped a click link that isn't http, https or mailto");
    return { scene: str(v.scene) ?? null, url: safe };
  }

  playback(v: unknown): SymbolPlayback | null {
    const s = str(v);
    if (s === undefined) return null;
    return (["loop", "once", "still", "click"].includes(s) ? s : "loop") as SymbolPlayback;
  }

  symbol(v: unknown, images: Record<string, EmbeddedImage>): Symbol | null {
    if (!isObj(v)) return null;
    this.fields(v, "symbol");
    const id = uuid(v.id);
    if (!id) { this.warn("Skipped a symbol without an id"); return null; }
    const size = (x: unknown): number => { const n = num(x); return Math.max(1, n ?? 100); };
    const layers = (Array.isArray(v.layers) ? v.layers : []).filter(isObj).flatMap((l): Layer[] => {
      const lid = uuid(l.id);
      return lid ? [{ id: lid, name: str(l.name) ?? "", visible: bool(l.visible) ?? true, locked: bool(l.locked) ?? false }] : [];
    });
    if (layers.length === 0) layers.push({ id: `${id}-LAYER`, name: "Layer 1", visible: true, locked: false });
    return {
      id, name: str(v.name) ?? "Symbol", width: size(v.width), height: size(v.height), layers,
      elements: (Array.isArray(v.elements) ? v.elements : []).map((e) => this.element(e, images)).filter((e): e is Element => e !== null),
      timeline: this.timeline(v.timeline),
      button: bool(v.button) ?? null,
      params: strings(v.params),
    };
  }

  hover(v: unknown): HoverLook | null {
    if (!isObj(v)) return null;
    this.fields(v, "hover");
    return { stroke: rgba(v.stroke) ?? null, fill: rgba(v.fill) ?? null, opacity: num(v.opacity) ?? null };
  }

  ease(v: unknown): Ease | null {
    const s = str(v);
    if (s === undefined) return null;
    if (!EASES.includes(s)) { this.warn(`Unknown ease "${s}", played linear`); return null; }
    return s as Ease;
  }

  keyframe(v: unknown): Keyframe | null {
    if (!isObj(v)) return null;
    this.fields(v, "keyframe");
    const t = num(v.t);
    if (t === undefined) return null;
    const k: Keyframe = { t };
    for (const p of ["x", "y", "width", "height", "rotation", "strokeWidth", "reveal", "opacity"] as const) {
      const n = num(v[p]);
      if (n !== undefined) k[p] = n;
    }
    const stroke = rgba(v.stroke), fill = rgba(v.fill), visible = bool(v.visible), ease = this.ease(v.ease);
    if (stroke) k.stroke = stroke;
    if (fill) k.fill = fill;
    if (visible !== undefined) k.visible = visible;
    if (ease) k.ease = ease;
    return k;
  }

  track(v: unknown): Track | null {
    if (!isObj(v)) return null;
    this.fields(v, "track");
    const element = uuid(v.element);
    if (!element) return null;
    const keys = (Array.isArray(v.keys) ? v.keys : []).map((k) => this.keyframe(k))
      .filter((k): k is Keyframe => k !== null && k.t >= 0 && k.t <= MAX_DURATION);
    stableSortBy(keys, (k) => k.t);
    const follow = Array.isArray(v.follow)
      ? v.follow.filter(isObj).flatMap((f): Follow[] => {
        const path = uuid(f.path), start = num(f.start), end = num(f.end);
        if (!path || start === undefined || end === undefined || start < 0 || end > MAX_DURATION) return [];
        return [{ path, start, end, ease: this.ease(f.ease), reverse: bool(f.reverse) ?? null, orient: bool(f.orient) ?? null, laps: num(f.laps) ?? null }];
      })
      : null;
    const repeats = Array.isArray(v.repeats)
      ? v.repeats.filter(isObj).flatMap((r): Repeat[] => {
        const start = num(r.start), end = num(r.end);
        if (start === undefined || end === undefined) return [];
        const count = num(r.count);
        const rep: Repeat = { start, end, count: count === undefined ? null : Math.trunc(count) };
        return repeatIsValid(rep) ? [rep] : [];
      })
      : null;
    return { element, keys, boil: bool(v.boil) ?? null, follow, repeats, march: clampMarch(num(v.march)) };
  }

  timeline(v: unknown): Timeline | null {
    if (!isObj(v)) return null;
    this.fields(v, "timeline");
    const boil = num(v.boil);
    const camera = Array.isArray(v.camera)
      ? v.camera.filter(isObj).flatMap((c): CameraKey[] => {
        const t = num(c.t), x = num(c.x), y = num(c.y), width = num(c.width), height = num(c.height);
        if (t === undefined || x === undefined || y === undefined || width === undefined || height === undefined) return [];
        if (!(width > 1 && height > 1 && t >= 0)) return [];
        return [{ t, x, y, width, height, ease: this.ease(c.ease) }];
      })
      : null;
    if (camera) stableSortBy(camera, (c) => c.t);
    const markers = Array.isArray(v.markers)
      ? v.markers.filter(isObj).flatMap((m): Marker[] => {
        const t = num(m.t);
        return t !== undefined && t >= 0 ? [{ t, name: str(m.name) ?? "" }] : [];
      })
      : null;
    if (markers) stableSortBy(markers, (m) => m.t);
    const poster = num(v.poster);
    return {
      fps: clampFPS(num(v.fps) ?? 12),
      duration: clampTime(num(v.duration) ?? 0),
      boil: boil !== undefined && Number.isInteger(boil) && boil > 0 ? Math.min(boil, 10_000) : null,
      settle: bool(v.settle) ?? null,
      poster: poster === undefined ? null : clampTime(poster),
      tracks: (Array.isArray(v.tracks) ? v.tracks : []).map((t) => this.track(t)).filter((t): t is Track => t !== null),
      camera,
      markers,
    };
  }

  page(v: unknown, images: Record<string, EmbeddedImage>, n: number): Page {
    if (!isObj(v)) throw new DottieFormatError(`Page ${n} is not an object`);
    this.fields(v, "page");
    const layers = (Array.isArray(v.layers) ? v.layers : []).filter(isObj).flatMap((l): Layer[] => {
      const id = uuid(l.id);
      return id ? [{ id, name: str(l.name) ?? "", visible: bool(l.visible) ?? true, locked: bool(l.locked) ?? false }] : [];
    });
    if (layers.length === 0) { this.warn(`Page ${n} has no layers`); layers.push({ id: "LAYER", name: "Layer 1", visible: true, locked: false }); }
    return {
      id: uuid(v.id) ?? `PAGE-${n}`,
      name: str(v.name) ?? `Page ${n}`,
      layers,
      elements: (Array.isArray(v.elements) ? v.elements : []).map((e) => this.element(e, images)).filter((e): e is Element => e !== null),
      theme: str(v.theme) ?? null,
      timeline: this.timeline(v.timeline),
      symbols: Array.isArray(v.symbols) ? v.symbols.map((x) => this.symbol(x, images)).filter((x): x is Symbol => x !== null) : null,
    };
  }
}

const BASE64 = /^[A-Za-z0-9+/=\s]*$/;

export function repeatIsValid(r: Repeat): boolean {
  return Number.isFinite(r.start) && Number.isFinite(r.end) && r.start >= 0 && r.end - r.start > 1e-3 && r.end <= MAX_DURATION
    && (r.count === null || (r.count >= 1 && r.count <= 10_000));
}

/** Sorts in place by `key`, keeping equal keys in their original order (as Swift's sort happens to for these). */
export function stableSortBy<T>(a: T[], key: (v: T) => number): void {
  const indexed = a.map((v, i) => [v, i] as const);
  indexed.sort((p, q) => key(p[0]) - key(q[0]) || p[1] - q[1]);
  for (let i = 0; i < a.length; i++) a[i] = indexed[i][0];
}

/** Reads a .dottie file from its JSON text (or the parsed object). Throws `DottieFormatError` when it isn't one. */
export function parseDottie(source: string | unknown): DottieFile {
  let json: unknown = source;
  if (typeof source === "string") {
    try { json = JSON.parse(source); } catch (e) { throw new DottieFormatError(`Not JSON: ${(e as Error).message}`); }
  }
  if (!isObj(json)) throw new DottieFormatError("Not a Dottie drawing");
  const version = num(json.version);
  if (version === undefined) throw new DottieFormatError("Not a Dottie drawing (no version)");
  if (!Array.isArray(json.pages) || json.pages.length === 0) throw new DottieFormatError("A drawing needs at least one page");
  const reader = new Reader();
  reader.fields(json, "file");
  if (version > SUPPORTED_VERSION) reader.warn(`File version ${version} is newer than this player knows (${SUPPORTED_VERSION}); some things may not show`);
  const images: Record<string, EmbeddedImage> = {};
  if (isObj(json.images)) {
    for (const [k, v] of Object.entries(json.images)) {
      if (isObj(v) && typeof v.data === "string") images[k] = reader.picture(v.data, str(v.format));
    }
  }
  const pages = json.pages.map((p, i) => reader.page(p, images, i + 1));
  if (new Set(pages.map((p) => p.id)).size !== pages.length) throw new DottieFormatError("Two pages share an id");
  return { version, pages, warnings: reader.warnings };
}

// MARK: Small model helpers shared by the rest

export function luminance(c: RGBA): number { return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b; }
export function sameColor(a: RGBA, b: RGBA): boolean { return a.r === b.r && a.g === b.g && a.b === b.b && a.a === b.a; }
export function isAutomaticInk(c: RGBA): boolean { return sameColor(c, black) || sameColor(c, inkOnDark); }

export function cloneElement(e: Element): Element {
  return {
    ...e,
    style: { ...e.style, stroke: { ...e.style.stroke }, fill: { ...e.style.fill } },
    connector: e.connector ? { ...e.connector, start: { ...e.connector.start }, end: { ...e.connector.end } } : null,
  };
}

/** Elements back to front: lower layers first, array order within a layer. */
export function orderedElements(page: Page): Element[] {
  if (page.layers.length <= 1) return page.elements;
  const rank = new Map<string, number>();
  page.layers.forEach((l, i) => { if (!rank.has(l.id)) rank.set(l.id, i); });
  const buckets: Element[][] = page.layers.map(() => []);
  for (const e of page.elements) buckets[rank.get(e.layerID) ?? 0].push(e);
  return buckets.flat();
}

/** Elements by id; with duplicate ids the first one wins, as in Dottie. */
export function elementIndex(page: Page): Map<string, Element> {
  const m = new Map<string, Element>();
  for (const e of page.elements) if (!m.has(e.id)) m.set(e.id, e);
  return m;
}
