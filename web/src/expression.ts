// Conditions and computed values (Expression.swift, ADR 0007), operation for operation, so dottie.js and Dottie
// agree: numbers and true/false, variable names, metrics (`load(workers)`, or `load` for the element's own),
// parentheses, `!` and `-`, `* / %`, `+ -`, comparisons, `&&` and `||`, and min, max, abs, floor, ceil, round, clamp.

/** A page variable's value: true or false, or a number. */
export type Var = boolean | number;

export type Expr =
  | { k: "lit"; v: Var }
  | { k: "name"; name: string }
  | { k: "metric"; metric: string; target: string }
  | { k: "not"; e: Expr }
  | { k: "neg"; e: Expr }
  | { k: "bin"; op: string; l: Expr; r: Expr }
  | { k: "call"; fn: string; args: Expr[] };

/** The metrics an expression can read (PageState.metricNames). */
export const METRIC_NAMES = ["throughput", "load", "delay", "backlog", "depth", "inFlight", "transit", "backup"];
const FUNCTIONS: Record<string, number | null> = { min: null, max: null, abs: 1, floor: 1, ceil: 1, round: 1, clamp: 3 };
const MAX_NAME = 64;

/** As a condition reads it: a number holds unless it is 0 (or not a number). */
export const truthy = (v: Var): boolean => typeof v === "boolean" ? v : v !== 0 && !Number.isNaN(v);
/** As arithmetic reads it: true is 1, false 0. */
export const num = (v: Var): number => typeof v === "boolean" ? (v ? 1 : 0) : v;

const parsed = new Map<string, Expr | null>();

/** `text` parsed, or null when it isn't an expression. Remembered, since a frame reads the same conditions often. */
export function parseExpr(text: string): Expr | null {
  const hit = parsed.get(text);
  if (hit !== undefined) return hit;
  const p = new Parser(text);
  let e = p.or();
  if (e && !p.atEnd()) e = null;
  if (parsed.size > 4096) parsed.clear();
  parsed.set(text, e);
  return e;
}

/** What a metric reads; null when it can't be had (every comparison with it then fails). */
export type MetricRead = (metric: string, target: string) => number | null;

/** The value with these variables (a missing one is false). */
export function evaluate(e: Expr, state: Record<string, Var>, metric: MetricRead | null = null): Var {
  switch (e.k) {
    case "lit": return e.v;
    case "name": return state[e.name] ?? false;
    case "metric": return metric?.(e.metric, e.target) ?? NaN;
    case "not": return !truthy(evaluate(e.e, state, metric));
    case "neg": return -num(evaluate(e.e, state, metric));
    case "call": {
      const xs = e.args.map((a) => num(evaluate(a, state, metric)));
      const fold = (better: (a: number, b: number) => boolean): number => {
        if (xs.some(Number.isNaN)) return NaN;
        let out = xs[0];
        for (const x of xs.slice(1)) if (better(x, out)) out = x;
        return out;
      };
      switch (e.fn) {
        case "min": return fold((a, b) => a < b);
        case "max": return fold((a, b) => a > b);
        case "abs": return Math.abs(xs[0]);
        case "floor": return Math.floor(xs[0]);
        case "ceil": return Math.ceil(xs[0]);
        case "round": return Math.floor(xs[0] + 0.5);
        default:
          if (xs.some(Number.isNaN)) return NaN;
          return xs[0] < xs[1] ? xs[1] : xs[0] > xs[2] ? xs[2] : xs[0];
      }
    }
    case "bin": {
      if (e.op === "&&") return truthy(evaluate(e.l, state, metric)) && truthy(evaluate(e.r, state, metric));
      if (e.op === "||") return truthy(evaluate(e.l, state, metric)) || truthy(evaluate(e.r, state, metric));
      const a = evaluate(e.l, state, metric), b = evaluate(e.r, state, metric);
      const x = num(a), y = num(b);
      switch (e.op) {
        case "+": return x + y;
        case "-": return x - y;
        case "*": return x * y;
        case "/": return x / y;
        case "%": return x % y;
      }
      // A comparison with something unknown fails, whichever way round.
      if (Number.isNaN(x) || Number.isNaN(y)) return false;
      switch (e.op) {
        case "<": return x < y;
        case "<=": return x <= y;
        case ">": return x > y;
        case ">=": return x >= y;
        case "==": return typeof a === "boolean" && typeof b === "boolean" ? a === b : x === y;
        default: return typeof a === "boolean" && typeof b === "boolean" ? a !== b : x !== y;
      }
    }
  }
}

/** The variable names it reads, in order, each once. */
export function exprNames(e: Expr): string[] {
  const out: string[] = [];
  const walk = (x: Expr): void => {
    switch (x.k) {
      case "name": if (!out.includes(x.name)) out.push(x.name); break;
      case "not": case "neg": walk(x.e); break;
      case "bin": walk(x.l); walk(x.r); break;
      case "call": x.args.forEach(walk); break;
    }
  };
  walk(e);
  return out;
}

/** The metrics it reads. */
export function exprMetrics(e: Expr): { metric: string; target: string }[] {
  const out: { metric: string; target: string }[] = [];
  const walk = (x: Expr): void => {
    switch (x.k) {
      case "metric": out.push({ metric: x.metric, target: x.target }); break;
      case "not": case "neg": walk(x.e); break;
      case "bin": walk(x.l); walk(x.r); break;
      case "call": x.args.forEach(walk); break;
    }
  };
  walk(e);
  return out;
}

const isDigit = (c: string | undefined) => c !== undefined && c >= "0" && c <= "9";
const isLetter = (c: string | undefined) => c !== undefined && (c === "_" || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z"));

/** Recursive descent over the grammar, loosest first (ExprParser). */
class Parser {
  private s: string[];
  private i = 0;
  constructor(text: string) { this.s = [...text]; }

  atEnd(): boolean { this.skip(); return this.i === this.s.length; }
  private skip(): void { while (this.i < this.s.length && " \t\n\r".includes(this.s[this.i])) this.i++; }

  private eat(token: string): boolean {
    this.skip();
    const t = [...token];
    if (this.i + t.length > this.s.length) return false;
    for (let k = 0; k < t.length; k++) if (this.s[this.i + k] !== t[k]) return false;
    // `<` isn't `<=`, `!` isn't `!=`.
    if (t.length === 1 && this.s[this.i + 1] === "=" && "<>!=".includes(t[0])) return false;
    this.i += t.length;
    return true;
  }

  or(): Expr | null {
    let l = this.and();
    if (!l) return null;
    while (this.eat("||")) { const r = this.and(); if (!r) return null; l = { k: "bin", op: "||", l, r }; }
    return l;
  }

  private and(): Expr | null {
    let l = this.compare();
    if (!l) return null;
    while (this.eat("&&")) { const r = this.compare(); if (!r) return null; l = { k: "bin", op: "&&", l, r }; }
    return l;
  }

  private compare(): Expr | null {
    const l = this.sum();
    if (!l) return null;
    for (const op of ["<=", ">=", "==", "!=", "<", ">"]) {
      if (this.eat(op)) { const r = this.sum(); return r ? { k: "bin", op, l, r } : null; }
    }
    return l;
  }

  private sum(): Expr | null {
    let l = this.product();
    if (!l) return null;
    for (;;) {
      const op = this.eat("+") ? "+" : this.eat("-") ? "-" : null;
      if (!op) return l;
      const r = this.product();
      if (!r) return null;
      l = { k: "bin", op, l, r };
    }
  }

  private product(): Expr | null {
    let l = this.unary();
    if (!l) return null;
    for (;;) {
      const op = ["*", "/", "%"].find((o) => this.eat(o));
      if (!op) return l;
      const r = this.unary();
      if (!r) return null;
      l = { k: "bin", op, l, r };
    }
  }

  private unary(): Expr | null {
    if (this.eat("!")) { const e = this.unary(); return e ? { k: "not", e } : null; }
    if (this.eat("-")) { const e = this.unary(); return e ? { k: "neg", e } : null; }
    return this.primary();
  }

  private primary(): Expr | null {
    this.skip();
    if (this.i >= this.s.length) return null;
    if (this.eat("(")) {
      const e = this.or();
      return e && this.eat(")") ? e : null;
    }
    const s = this.s;
    const c = s[this.i];
    if (isDigit(c)) {
      const start = this.i;
      while (isDigit(s[this.i])) this.i++;
      if (s[this.i] === "." && isDigit(s[this.i + 1])) { this.i++; while (isDigit(s[this.i])) this.i++; }
      return { k: "lit", v: Number(s.slice(start, this.i).join("")) };
    }
    if (!isLetter(c)) return null;
    const start = this.i;
    while (isLetter(s[this.i]) || isDigit(s[this.i])) this.i++;
    const name = s.slice(start, this.i).join("");
    if (name.length > MAX_NAME) return null;
    let j = this.i;
    while (s[j] === " " || s[j] === "\t") j++;
    const called = s[j] === "(";
    if (METRIC_NAMES.includes(name)) {
      if (!called) return { k: "metric", metric: name, target: "" };
      this.eat("(");
      // The target is everything up to the closing parenthesis: an anchor or an id.
      const from = this.i;
      while (this.i < s.length && s[this.i] !== ")" && s[this.i] !== "(") this.i++;
      if (s[this.i] !== ")") return null;
      const target = s.slice(from, this.i).join("").replace(/^[ \t]+|[ \t]+$/g, "");
      this.i++;
      return { k: "metric", metric: name, target };
    }
    if (name in FUNCTIONS) {
      if (!called || !this.eat("(")) return null;
      const args: Expr[] = [];
      if (!this.eat(")")) {
        do { const a = this.or(); if (!a) return null; args.push(a); } while (this.eat(","));
        if (!this.eat(")")) return null;
      }
      const arity = FUNCTIONS[name];
      if (arity !== null ? args.length !== arity : args.length === 0) return null;
      return { k: "call", fn: name, args };
    }
    if (called) return null;
    if (name === "true") return { k: "lit", v: true };
    if (name === "false") return { k: "lit", v: false };
    return { k: "name", name };
  }
}

/** A variable's value as text shows it (Var.description): true or false, a number to two places. */
export function describeVar(v: Var): string {
  return typeof v === "boolean" ? (v ? "true" : "false") : formatTwo(v);
}

/** formatNumber(v, 2) (measure.ts, DottieDocument.number), here to keep this file free of imports. */
function formatTwo(v: number): string {
  const n = Math.floor(Math.abs(v) * 100 + 0.5);
  if (!(n < 1e15)) return v < 0 ? "-∞" : "∞";
  const whole = Math.floor(n / 100), part = n - whole * 100;
  let s = String(whole);
  if (part > 0) s += "." + String(part).padStart(2, "0").replace(/0+$/, "");
  return (v < 0 && n > 0 ? "-" : "") + s;
}

/** `text` with each `{expression}` that reads only the page's variables replaced by its value (PageState.filling). */
export function filling(text: string, values: Record<string, Var>): string {
  if (!text.includes("{")) return text;
  let out = "", rest = text;
  for (let open = rest.indexOf("{"); open >= 0; open = rest.indexOf("{")) {
    out += rest.slice(0, open);
    const close = rest.indexOf("}", open);
    if (close < 0) { out += rest.slice(open); rest = ""; break; }
    const inner = rest.slice(open + 1, close);
    const e = inner.includes("{") ? null : parseExpr(inner);
    const names = e ? exprNames(e) : [];
    if (e && exprMetrics(e).length === 0 && names.length > 0 && names.every((n) => values[n] !== undefined)) out += describeVar(evaluate(e, values));
    else out += rest.slice(open, close + 1);
    rest = rest.slice(close + 1);
  }
  return out + rest;
}
