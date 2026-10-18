// Types for a Dottie extension's main.ts. Dottie ships this file; main.ts references it. It is a global script (no
// imports or exports), so the `extension` global is visible everywhere in the bundle.
// An extension runs in JavaScriptCore with no file system, network or timers. Its shape functions are pure: plain
// data in, plain data out. Commands also get the `dottie` object; its types are in dottie.d.ts (`dottie script-types`).

/** A value a parameter can take. */
type ParameterValue = number | boolean | string;

/** One parameter of a shape or command. `default` is required. */
interface ParameterSpec {
  type: "number" | "integer" | "boolean" | "enum" | "string";
  label?: string;
  /** For number and integer. */
  min?: number;
  max?: number;
  /** For enum: the values it can take. */
  options?: string[];
  default: ParameterValue;
}

/** The frame a shape is generated for, in points. */
interface Frame {
  width: number;
  height: number;
}

/** A point in normalized coordinates (0...1 across the frame), or in points for a handle. */
interface Point {
  x: number;
  y: number;
}

/** A Bézier outline: start, then c1, c2, end for each segment, so 2 + 6n numbers. */
interface Subpath {
  closed: boolean;
  coords: number[];
}

/** What `generate` returns. Coordinates are normalized to the frame. */
interface GeneratedShape {
  subpaths: Subpath[];
  /** Connection points connectors can attach to. */
  ports?: Point[];
  /** Where the shape's label goes. */
  labelRect?: { x: number; y: number; width: number; height: number };
}

/** An adjustment handle: dragging it changes parameters (v1.1). */
interface HandleDefinition<P> {
  id: string;
  /** Where the handle sits, in points from the frame's top-left. */
  position(params: P, frame: Frame): Point;
  /** The parameters after dragging the handle to `point` (points from the frame's top-left). */
  drag(params: P, frame: Frame, point: Point): P;
}

interface ShapeDefinition<P> {
  id: string;
  name: string;
  parameters: { [K in keyof P]: ParameterSpec };
  generate(params: P, frame: Frame): GeneratedShape;
  handles?: HandleDefinition<P>[];
}

interface CommandDefinition<P> {
  id: string;
  name: string;
  /** Groups the command in the Extensions menu. */
  category?: string;
  /** "selection" puts it in the canvas context menu when something is selected. */
  when?: "selection";
  parameters?: { [K in keyof P]: ParameterSpec };
  /** Runs with the full `dottie` object; the whole run is one undo step. */
  run(params: P): unknown;
}

/** A press and drag with a tool so far. `draw` is called on the press, on every step of the drag, and on release. */
interface ToolGesture {
  /** Every point since the press, in canvas points (y down). The first is where the press began. */
  points: Point[];
  /** True on the last call, when the button has been let go; what `draw` returns then is added as one undo step. */
  done: boolean;
  shift: boolean;
  option: boolean;
}

/** A color: "#rrggbb" or "#rrggbbaa", or "none". */
type ToolColor = string;

/** What a drawn element may set; anything left out comes from the style new shapes get. */
interface DrawnStyle {
  fill?: ToolColor;
  stroke?: ToolColor;
  /** 0...24. */
  strokeWidth?: number;
  fillStyle?: "solid" | "hachure" | "crossHatch" | "grid";
  /** 0 is precise, 1 hand-drawn, 2 very sketchy. */
  roughness?: number;
}

/** An element a tool draws: a path in canvas points, or a box-shaped shape. They are plain elements, so the drawing
 * opens and renders without the extension. Points stay within 100000 of the origin, each element at most 20000
 * points wide and tall, and text at most 10000 characters; anything past that is refused. */
type DrawnElement =
  | (DrawnStyle & { kind: "path"; subpaths: Subpath[] })
  | (DrawnStyle & { kind: "rectangle" | "ellipse" | "diamond"; x: number; y: number; width: number; height: number; text?: string });

/** A drawing tool, shown in the toolbar and the Tools menu. Extensions can't assign it a key. */
interface ToolDefinition {
  /** Letters, digits, "-", "_" and ".". */
  id: string;
  name: string;
  /** An SF Symbol name for the toolbar, such as "paintbrush.pointed". */
  icon?: string;
  /** What the gesture draws so far. Pure: it gets the whole gesture each time and keeps nothing between calls. */
  draw(gesture: ToolGesture): { elements: DrawnElement[] };
}

/** Filled in when a parameter is migrated from an older version of this extension. */
type MigrateFunction = (
  fromVersion: string,
  params: Record<string, ParameterValue>,
  shape: string,
) => Record<string, ParameterValue>;

/** The global an extension's main.js declares its shapes, commands, tools and migration with. */
declare const extension: {
  shape<P>(definition: ShapeDefinition<P>): void;
  command<P>(definition: CommandDefinition<P>): void;
  tool(definition: ToolDefinition): void;
  migrate(fn: MigrateFunction): void;
};

/** Output goes to the Script Console in the app; a command's output is also in run_command's reply. */
declare const console: {
  log(...values: unknown[]): void;
  info(...values: unknown[]): void;
  warn(...values: unknown[]): void;
  error(...values: unknown[]): void;
};

/**
 * Loads a CommonJS module from this bundle ("./lib/geometry" is lib/geometry.js) or one bundled with Dottie
 * (lodash, d3-*, dagre, dayjs). Nothing outside the bundle can be loaded. Modules have no types here.
 */
declare function require(name: string): any;

/**
 * The `dottie` object commands run with. Typed loosely here; run `dottie script-types <dir>` to write the full
 * dottie.d.ts for it and replace this declaration with a reference to that file.
 */
declare const dottie: any;
