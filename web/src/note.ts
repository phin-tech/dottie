// Sticky notes (Note.swift): GitHub Flavored Markdown laid out from the top left the way Dottie's CoreText layout
// does it — the same fonts, indents, list hangs, paragraph spacing and rounded line metrics — and written out as
// positioned SVG text. A small Markdown parser covers what notes use: headings, paragraphs (a single newline is a
// line break), nested bullet, numbered and task lists, quotes, code, rules, tables, and inline bold, italic,
// `code`, ~~strikethrough~~ and links.

import type { Element } from "./model.ts";
import {
  ascent, boldAscent, boldDescent, boldItalicAscent, boldItalicDescent, boldItalicLeading, boldLeading, descent, fallbackMetrics, fonts,
  italicAscent, italicDescent, italicLeading, leading, monoAdvance, monoAscent, monoDescent,
} from "./metrics.ts";
import { type Rect, fmt } from "./path.ts";
import { color, escapeXML } from "./svg-util.ts";

export const PADDING = 12;
const SEP = "\u2028";

/** Where the text goes inside a note's frame. */
export function textRect(f: Rect): Rect {
  const dx = Math.min(PADDING, f.width / 2), dy = Math.min(PADDING, f.height / 2);
  return { x: f.x + dx, y: f.y + dy, width: f.width - 2 * dx, height: f.height - 2 * dy };
}

// MARK: Markdown

type Inline = { text: string; bold?: boolean; italic?: boolean; mono?: boolean; strike?: boolean; link?: boolean };

type Block =
  | { kind: "heading"; level: number; inline: Inline[] }
  | { kind: "paragraph"; inline: Inline[] }
  | { kind: "list"; ordered: number | null; items: { checkbox: boolean | null; children: Block[] }[] }
  | { kind: "quote"; children: Block[] }
  | { kind: "code"; text: string }
  | { kind: "rule" }
  | { kind: "table"; align: (string | null)[]; head: Inline[][]; rows: Inline[][][] };

const reHeading = /^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$/;
const reRule = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
const reFence = /^ {0,3}(`{3,}|~{3,})/;
const reItem = /^( *)([-*+]|\d{1,9}[.)])([ \t]+|$)(.*)$/;
const reQuote = /^ {0,3}> ?(.*)$/;
const reTableSep = /^ *\|? *:?-+:? *(\| *:?-+:? *)*\|? *$/;

function splitRow(line: string): string[] {
  let s = line.trim();
  if (s.startsWith("|")) s = s.slice(1);
  if (s.endsWith("|") && !s.endsWith("\\|")) s = s.slice(0, -1);
  return s.split(/(?<!\\)\|/).map((c) => c.trim());
}

export function parseBlocks(source: string): Block[] {
  return blocks(source.replace(/\r\n?/g, "\n").split("\n"));
}

function blocks(lines: string[]): Block[] {
  const out: Block[] = [];
  let i = 0;
  let para: string[] | null = null;
  const flush = () => { if (para) { out.push({ kind: "paragraph", inline: inline(para.join("\n")) }); para = null; } };
  while (i < lines.length) {
    const line = lines[i];
    if (line.trim() === "") { flush(); i++; continue; }
    const fence = reFence.exec(line);
    if (fence) {
      flush();
      const close = new RegExp(`^ {0,3}${fence[1][0] === "`" ? "`" : "~"}{${fence[1].length},}[ \\t]*$`);
      const body: string[] = [];
      i++;
      while (i < lines.length && !close.test(lines[i])) body.push(lines[i++]);
      i++;
      out.push({ kind: "code", text: body.join("\n") });
      continue;
    }
    const h = reHeading.exec(line);
    if (h) { flush(); out.push({ kind: "heading", level: h[1].length, inline: inline(h[2] ?? "") }); i++; continue; }
    // Setext headings: a paragraph underlined with = or -.
    if (para && /^ {0,3}(=+|-+)[ \t]*$/.test(line)) {
      const level = line.trim()[0] === "=" ? 1 : 2;
      out.push({ kind: "heading", level, inline: inline((para as string[]).join("\n")) });
      para = null; i++; continue;
    }
    if (reRule.test(line)) { flush(); out.push({ kind: "rule" }); i++; continue; }
    if (reQuote.test(line)) {
      flush();
      const inner: string[] = [];
      while (i < lines.length && lines[i].trim() !== "") {
        const q = reQuote.exec(lines[i]);
        inner.push(q ? q[1] : lines[i]);
        i++;
      }
      out.push({ kind: "quote", children: blocks(inner) });
      continue;
    }
    const item = reItem.exec(line);
    if (item && (!para || item[4].trim() !== "")) {
      flush();
      const list = parseList(lines, i);
      out.push(list.block);
      i = list.next;
      continue;
    }
    if (!para && line.includes("|") && i + 1 < lines.length && reTableSep.test(lines[i + 1]) && lines[i + 1].includes("-")) {
      const head = splitRow(line);
      const align = splitRow(lines[i + 1]).map((c) => (c.startsWith(":") && c.endsWith(":") ? "center" : c.endsWith(":") ? "right" : c.startsWith(":") ? "left" : null));
      const rows: Inline[][][] = [];
      i += 2;
      while (i < lines.length && lines[i].trim() !== "" && !reHeading.test(lines[i]) && !reQuote.test(lines[i]) && !reFence.test(lines[i])) {
        rows.push(splitRow(lines[i]).slice(0, head.length).map((c) => inline(c)));
        i++;
      }
      out.push({ kind: "table", align, head: head.map((c) => inline(c)), rows });
      continue;
    }
    if (!para) para = [];
    para.push(line.replace(/^ +/, ""));
    i++;
  }
  flush();
  return out;
}

function parseList(lines: string[], start: number): { block: Block; next: number } {
  const first = reItem.exec(lines[start])!;
  const indent = first[1].length;
  const bullet = /^\d/.test(first[2]) ? null : first[2];
  const ordered = bullet === null ? parseInt(first[2], 10) : null;
  const items: { checkbox: boolean | null; children: Block[] }[] = [];
  let i = start;
  while (i < lines.length) {
    const m = reItem.exec(lines[i]);
    if (!m || m[1].length !== indent || (bullet === null) !== /^\d/.test(m[2]) || (bullet !== null && m[2] !== bullet)) break;
    const contentIndent = m[1].length + m[2].length + Math.max(1, Math.min(m[3].length, 4));
    const body: string[] = [m[4]];
    i++;
    let blank = false;
    while (i < lines.length) {
      const l = lines[i];
      if (l.trim() === "") { blank = true; body.push(""); i++; continue; }
      const lead = l.length - l.trimStart().length;
      if (lead >= contentIndent) { body.push(l.slice(contentIndent)); blank = false; i++; continue; }
      if (!blank && !reItem.test(l) && !reHeading.test(l) && !reQuote.test(l) && !reFence.test(l) && !reRule.test(l)) {
        body.push(l.trimStart()); i++; continue;   // a lazy continuation line
      }
      break;
    }
    while (body.length && body[body.length - 1].trim() === "") body.pop();
    let checkbox: boolean | null = null;
    const task = /^\[([ xX])\](?:[ \t]+|$)/.exec(body[0] ?? "");
    if (task) { checkbox = task[1] !== " "; body[0] = body[0].slice(task[0].length); }
    items.push({ checkbox, children: blocks(body) });
    if (blank && i < lines.length && lines[i - 1]?.trim() === "") {
      const next = reItem.exec(lines[i]);
      if (!next || next[1].length !== indent) break;
    }
  }
  return { block: { kind: "list", ordered, items }, next: i };
}

/** Inline Markdown into styled runs; soft and hard breaks become line separators. */
export function inline(src: string, style: Omit<Inline, "text"> = {}): Inline[] {
  const out: Inline[] = [];
  const push = (text: string, s: Omit<Inline, "text">) => { if (text) out.push({ ...s, text }); };
  let i = 0, buf = "";
  const emit = () => { push(buf, style); buf = ""; };
  while (i < src.length) {
    const rest = src.slice(i);
    let m: RegExpExecArray | null;
    if (rest[0] === "\\" && /^\\[\\`*_{}[\]()#+\-.!|~>]/.test(rest)) { buf += rest[1]; i += 2; continue; }
    if (rest.startsWith("\\\n")) { buf += SEP; i += 2; while (src[i] === " ") i++; continue; }   // a hard break
    if (rest[0] === "\n") { buf = buf.replace(/ +$/, ""); buf += SEP; i++; while (src[i] === " ") i++; continue; }
    if ((m = /^(`+)([\s\S]*?[^`])\1(?!`)/.exec(rest))) {
      emit();
      let code = m[2].replace(/\n/g, " ");
      if (/^ .* $/.test(code)) code = code.slice(1, -1);
      push(code, { ...style, mono: true });
      i += m[0].length; continue;
    }
    if ((m = /^!\[([^\]]*)\]\([^)]*\)/.exec(rest))) { emit(); out.push(...inline(m[1], style)); i += m[0].length; continue; }
    if ((m = /^\[([^\]]+)\]\([^)]*\)/.exec(rest))) { emit(); out.push(...inline(m[1], { ...style, link: true })); i += m[0].length; continue; }
    if ((m = /^<((?:https?|ftp|mailto):[^>\s]+)>/.exec(rest))) { emit(); push(m[1], { ...style, link: true }); i += m[0].length; continue; }
    if ((m = /^~~(?=\S)([\s\S]*?\S)~~/.exec(rest))) { emit(); out.push(...inline(m[1], { ...style, strike: true })); i += m[0].length; continue; }
    if ((m = /^(\*\*|__)(?=\S)([\s\S]*?\S)\1/.exec(rest))) { emit(); out.push(...inline(m[2], { ...style, bold: true })); i += m[0].length; continue; }
    if ((m = /^(\*|_)(?=\S)([\s\S]*?\S)\1(?!\1)/.exec(rest)) && (m[1] === "*" || !/\w/.test(src[i - 1] ?? ""))) {
      emit(); out.push(...inline(m[2], { ...style, italic: true })); i += m[0].length; continue;
    }
    buf += rest[0];
    i++;
  }
  emit();
  return underlineBareURLs(out);
}

/** cmark's autolink extension is off in Dottie, which underlines bare URLs itself. */
function underlineBareURLs(runs: Inline[]): Inline[] {
  const url = /\b(?:(?:https?|ftp):\/\/|www\.)[^\s<]*[^\s<.,:;"')\]!?]/g;
  return runs.flatMap((r) => {
    if (r.link || r.mono || !(r.text.includes("://") || r.text.includes("www."))) return [r];
    const out: Inline[] = [];
    let last = 0;
    for (const m of r.text.matchAll(url)) {
      if (m.index > last) out.push({ ...r, text: r.text.slice(last, m.index) });
      out.push({ ...r, text: m[0], link: true });
      last = m.index + m[0].length;
    }
    if (last < r.text.length) out.push({ ...r, text: r.text.slice(last) });
    return out;
  });
}

// MARK: Layout

interface Run { text: string; size: number; bold: boolean; italic: boolean; mono: boolean; strike: boolean; underline: boolean; alpha: number }

interface Tab { align: "left" | "center" | "right"; x: number }

interface Para {
  runs: Run[];
  spacing: number;
  firstIndent: number;
  indent: number;
  tabs: Tab[];
  quote: number | null;
  rule: number | null;
  tableRule: [number, number] | null;
}

function face(r: { bold: boolean; italic: boolean }): "regular" | "bold" | "italic" | "boldItalic" {
  return r.bold ? (r.italic ? "boldItalic" : "bold") : r.italic ? "italic" : "regular";
}

function charWidth(ch: string, r: Run): number {
  if (r.mono && fallbackMetrics[ch] === undefined) return monoAdvance * r.size;
  const f = fonts[face(r)];
  return ((f.w[ch] ?? fonts.regular.w[ch] ?? f.w["n"]) * r.size) / 1000;
}

function kern(a: string, b: string, r: Run): number {
  if (r.mono) return 0;
  return ((fonts[face(r)].k[a + b] ?? 0) * r.size) / 1000;
}

/** Ascent, descent and leading of a character in a run (a fallback font's for characters Helvetica Neue lacks). */
function metrics(ch: string, r: Run): [number, number, number] {
  const fb = fallbackMetrics[ch];
  if (fb) return [fb[0] * r.size, fb[1] * r.size, fb[2] * r.size];
  if (r.mono) return [monoAscent * r.size, monoDescent * r.size, 0];
  if (r.bold && r.italic) return [boldItalicAscent * r.size, boldItalicDescent * r.size, boldItalicLeading * r.size];
  if (r.bold) return [boldAscent * r.size, boldDescent * r.size, boldLeading * r.size];
  if (r.italic) return [italicAscent * r.size, italicDescent * r.size, italicLeading * r.size];
  return [ascent * r.size, descent * r.size, leading * r.size];
}

interface Glyph { ch: string; run: number; x: number; w: number }
interface Line { glyphs: Glyph[]; asc: number; desc: number; lead: number; baseline: number; para: Para; first: boolean }

class Builder {
  paras: Para[] = [];
  nextSpacing: number | null = null;
  readonly fontSize: number;
  readonly width: number;
  constructor(fontSize: number, width: number) { this.fontSize = fontSize; this.width = width; }
  get gap(): number { return this.fontSize * 0.5; }
  spacing(normal: number): number { return this.paras.length === 0 ? 0 : (this.nextSpacing ?? normal); }

  run(i: Inline, size: number, alpha: number, base: { bold?: boolean; italic?: boolean } = {}): Run {
    const mono = !!i.mono;
    return {
      text: i.text, size: mono ? size * 0.9 : size, bold: !!(i.bold || base.bold), italic: !!(i.italic || base.italic), mono,
      strike: !!i.strike, underline: !!i.link, alpha,
    };
  }

  paragraph(p: Omit<Para, "tabs" | "rule" | "tableRule" | "quote"> & Partial<Para>, quote: number | null): void {
    this.paras.push({ tabs: [], rule: null, tableRule: null, ...p, quote });
    this.nextSpacing = null;
  }

  text(runs: Run[], ctx: Ctx, spacing: number, extra: Partial<Para> = {}): void {
    if (ctx.marker) {
      const lead: Run = { text: ctx.marker.text + "\t", size: this.fontSize, bold: false, italic: false, mono: false, strike: false, underline: false, alpha: 1 };
      this.paragraph({ runs: [lead, ...runs], spacing, firstIndent: ctx.marker.start, indent: ctx.marker.hang, tabs: [{ align: "left", x: ctx.marker.hang }], ...extra }, ctx.quote);
    } else {
      this.paragraph({ runs, spacing, firstIndent: ctx.indent, indent: ctx.indent, ...extra }, ctx.quote);
    }
  }

  block(b: Block, ctx: Ctx): void {
    const quoted = ctx.quote !== null;
    const alpha = quoted ? 0.7 : 1;
    switch (b.kind) {
      case "heading": {
        const scale = [1.5, 1.3, 1.15, 1.05, 1, 1][Math.min(Math.max(b.level, 1), 6) - 1];
        this.text(b.inline.map((i) => this.run(i, this.fontSize * scale, alpha, { bold: true, italic: quoted })), ctx, this.spacing(this.gap * 1.4));
        break;
      }
      case "paragraph":
        this.text(b.inline.map((i) => this.run(i, this.fontSize, alpha, { italic: quoted })), ctx, this.spacing(this.gap));
        break;
      case "list": {
        const markers = b.items.map((it, i) => (it.checkbox === true ? "☑" : it.checkbox === false ? "☐"
          : b.ordered !== null ? `${b.ordered + i}.` : ctx.listDepth % 2 === 0 ? "•" : "◦"));
        const plain = (s: string): number => measureRun({ text: s, size: this.fontSize, bold: false, italic: false, mono: false, strike: false, underline: false, alpha: 1 });
        const widest = Math.max(0, ...markers.map(plain));
        const hang = ctx.indent + Math.max(widest + this.fontSize * 0.45, this.fontSize * 1.2);
        b.items.forEach((item, i) => {
          if (i > 0 || ctx.listDepth > 0 || ctx.marker) this.nextSpacing = this.fontSize * 0.15;
          const inner: Ctx = { ...ctx, marker: { text: markers[i], start: ctx.indent, hang }, indent: hang, listDepth: ctx.listDepth + 1 };
          if (item.children.length === 0) this.text([], inner, this.spacing(this.gap));
          for (const child of item.children) {
            this.block(child, inner);
            inner.marker = null;
            this.nextSpacing = this.fontSize * 0.3;
          }
          this.nextSpacing = null;
        });
        break;
      }
      case "quote": {
        const inner: Ctx = { ...ctx, quote: ctx.indent + 3, indent: ctx.indent + this.fontSize };
        for (const child of b.children) this.block(child, inner);
        break;
      }
      case "code": {
        const body = b.text === "" ? " " : b.text.replace(/\n/g, SEP);
        const run: Run = { text: body, size: this.fontSize * 0.85, bold: false, italic: false, mono: true, strike: false, underline: false, alpha };
        this.text([run], { ...ctx, indent: ctx.indent + this.fontSize * 0.5 }, this.spacing(this.gap));
        break;
      }
      case "rule": {
        const run: Run = { text: " ", size: this.fontSize * 0.6, bold: false, italic: false, mono: false, strike: false, underline: false, alpha: 1 };
        this.text([run], ctx, this.spacing(this.gap), { rule: ctx.indent });
        break;
      }
      case "table":
        this.table(b, ctx);
        break;
    }
  }

  table(t: Extract<Block, { kind: "table" }>, ctx: Ctx): void {
    const rows = [{ cells: t.head, header: true }, ...t.rows.map((r) => ({ cells: r, header: false }))];
    const columns = Math.max(1, ...rows.map((r) => r.cells.length));
    const quoted = ctx.quote !== null;
    const cell = (c: Inline[], header: boolean, size: number): Run[] =>
      c.map((i) => ({ ...this.run({ ...i, text: i.text.replaceAll(SEP, " ") }, size, quoted ? 0.7 : 1, { bold: header, italic: quoted }) }));
    const widths = (size: number): number[] => {
      const w = new Array<number>(columns).fill(0);
      for (const row of rows) row.cells.forEach((c, i) => { if (i < columns) w[i] = Math.max(w[i], cell(c, row.header, size).reduce((s, r) => s + measureRun(r), 0)); });
      return w;
    };
    const available = Math.max(this.width - ctx.indent, 1);
    let size = this.fontSize;
    let w = widths(size);
    let gutter = size * 1.2;
    const natural = w.reduce((a, b) => a + b, 0) + gutter * (columns - 1);
    if (natural > available) {
      size = Math.max((this.fontSize * available) / natural, Math.min(this.fontSize, 9));
      w = widths(size);
      gutter = size * 1.2;
    }
    const starts: number[] = [];
    let x = ctx.indent;
    for (const wi of w) { starts.push(x); x += wi + gutter; }
    const total = x - gutter - ctx.indent;
    const tabs: Tab[] = [];
    let leadingTab = false;
    for (let i = 0; i < columns; i++) {
      const align = t.align[i] ?? null;
      if (align === "center") tabs.push({ align: "center", x: starts[i] + w[i] / 2 });
      else if (align === "right") tabs.push({ align: "right", x: starts[i] + w[i] });
      else if (i > 0) tabs.push({ align: "left", x: starts[i] });
      if (i === 0 && (align === "center" || align === "right")) leadingTab = true;
    }
    const plain = (s: string): Run => ({ text: s, size, bold: false, italic: false, mono: false, strike: false, underline: false, alpha: 1 });
    rows.forEach((row, n) => {
      const runs: Run[] = [];
      if (leadingTab) runs.push(plain("\t"));
      for (let i = 0; i < columns; i++) {
        if (i > 0) runs.push(plain("\t"));
        if (i < row.cells.length) runs.push(...cell(row.cells[i], row.header, size));
      }
      if (runs.length === 0) runs.push(plain(" "));
      const before = n === 0 ? this.spacing(this.gap) : n === 1 ? size * 0.45 : size * 0.2;
      this.paragraph({ runs, spacing: before, firstIndent: ctx.indent, indent: ctx.indent, tabs, tableRule: row.header ? [ctx.indent, total] : null }, ctx.quote);
    });
  }
}

interface Ctx { indent: number; marker: { text: string; start: number; hang: number } | null; quote: number | null; listDepth: number }

function measureRun(r: Run): number {
  let w = 0, prev = "";
  for (const ch of r.text) { w += charWidth(ch, r); if (prev) w += kern(prev, ch, r); prev = ch; }
  return w;
}

/** CoreText's default tab interval after the paragraph's own stops. */
const TAB_INTERVAL = 28;

/** Lays paragraphs out into lines with baselines, top-down from y = 0, within `width` and `height`. */
function layoutLines(paras: Para[], width: number, height: number, fontSize: number): Line[] {
  const lines: Line[] = [];
  let baseline = 0;
  let prev: Line | null = null;
  paras.forEach((p, pi) => {
    // The newline joining two blocks belongs to the earlier paragraph, in the note's plain font.
    const runs = pi < paras.length - 1 ? [...p.runs, { text: "\n", size: fontSize, bold: false, italic: false, mono: false, strike: false, underline: false, alpha: 1 }] : p.runs;
    const chars: { ch: string; run: number }[] = [];
    runs.forEach((r, ri) => { for (const ch of r.text) chars.push({ ch, run: ri }); });
    let k = 0;
    let firstLine = true;
    while (k < chars.length || (firstLine && chars.length === 0)) {
      const start = firstLine ? p.firstIndent : p.indent;
      const maxX = width;
      // Fill a line: break at a separator, or at the last space before the text runs past the edge.
      const glyphs: Glyph[] = [];
      let x = start, lastSpace = -1, end = k;
      for (; end < chars.length; end++) {
        const { ch, run } = chars[end];
        const r = runs[run];
        if (ch === SEP || ch === "\n") { glyphs.push({ ch, run, x, w: 0 }); end++; break; }
        if (ch === "\t") {
          const stop = p.tabs.find((t) => t.x > x + 0.01);
          let tx: number;
          if (stop) {
            if (stop.align === "left") tx = stop.x;
            else {
              // Center or right: the text up to the next tab ends at (or centers on) the stop.
              let seg = 0, prevCh = "";
              for (let q = end + 1; q < chars.length && chars[q].ch !== "\t" && chars[q].ch !== "\n" && chars[q].ch !== SEP; q++) {
                const rr = runs[chars[q].run];
                seg += charWidth(chars[q].ch, rr) + (prevCh ? kern(prevCh, chars[q].ch, rr) : 0);
                prevCh = chars[q].ch;
              }
              tx = Math.max(x, stop.align === "right" ? stop.x - seg : stop.x - seg / 2);
            }
          } else tx = (Math.floor(x / TAB_INTERVAL) + 1) * TAB_INTERVAL;
          glyphs.push({ ch, run, x, w: tx - x });
          x = tx;
          continue;
        }
        const prevGlyph = glyphs[glyphs.length - 1];
        const kx = prevGlyph && prevGlyph.run === run && prevGlyph.ch !== "\t" ? kern(prevGlyph.ch, ch, r) : 0;
        if (prevGlyph) { prevGlyph.w += kx; x += kx; }
        const w = charWidth(ch, r);
        if (ch !== " " && x + w > maxX + 0.01 && glyphs.some((g) => g.ch !== "\t")) {
          if (lastSpace >= 0) { glyphs.length = lastSpace + 1; end = k + lastSpace + 1; }
          if (prevGlyph) prevGlyph.w -= kx;
          break;
        }
        glyphs.push({ ch, run, x, w });
        x += w;
        // Break opportunities (Unicode line breaking, as CoreText does it): after a space, and after a slash
        // or hyphen that isn't followed by a digit or another of itself.
        const next = chars[end + 1]?.ch ?? "";
        if (ch === " " || ((ch === "/" || ch === "-") && next !== "" && !/[\d\s/-]/.test(next))) lastSpace = glyphs.length - 1;
      }
      if (glyphs.length === 0 && end === k && k < chars.length) { // a single character wider than the line
        const { ch, run } = chars[k];
        glyphs.push({ ch, run, x: start, w: charWidth(ch, runs[run]) });
        end = k + 1;
      }
      let asc = 0, desc = 0, lead = 0;
      for (const g of glyphs) {
        const [a, d, l] = metrics(g.ch, runs[g.run]);
        asc = Math.max(asc, a); desc = Math.max(desc, d); lead = Math.max(lead, l);
      }
      if (glyphs.length === 0) [asc, desc, lead] = metrics(" ", runs[0] ?? { text: " ", size: fontSize, bold: false, italic: false, mono: false, strike: false, underline: false, alpha: 1 });
      baseline = prev ? baseline + Math.round(prev.desc) + Math.round(prev.lead) + (firstLine ? p.spacing : 0) + Math.round(asc) : Math.round(asc);
      if (baseline + desc > height + 0.5) return;   // text that doesn't fit is cut off at the note's edge
      const line: Line = { glyphs, asc, desc, lead, baseline, para: p, first: firstLine };
      line.glyphs.forEach((g) => { (g as Glyph & { r?: Run }).r = runs[g.run]; });
      lines.push(line);
      prev = line;
      firstLine = false;
      k = end;
      if (chars.length === 0) break;
    }
  });
  return lines;
}

/** The note's text as positioned SVG, laid out as Dottie lays it out (SVG.swift's noteText). */
export function noteMarkup(source: string, e: Element): string {
  const rect = textRect({ x: e.x, y: e.y, width: e.width, height: e.height });
  if (!(rect.width > 1 && rect.height > 1)) return "";
  const b = new Builder(e.style.fontSize, rect.width);
  for (const block of parseBlocks(source)) b.block(block, { indent: 0, marker: null, quote: null, listDepth: 0 });
  const lines = layoutLines(b.paras, rect.width, rect.height, e.style.fontSize);
  const ink = color(e.style.stroke);
  let s = "";
  const marks: [number, number, number, number][] = [];
  for (const l of lines) {
    const p = l.para;
    if (p.quote !== null) marks.push([rect.x + p.quote, rect.y + l.baseline - l.asc, rect.x + p.quote, rect.y + l.baseline + l.desc]);
    if (p.rule !== null) marks.push([rect.x + p.rule, rect.y + l.baseline - 3, rect.x + rect.width, rect.y + l.baseline - 3]);
    if (p.tableRule) {
      const y = rect.y + l.baseline + l.desc + 2;
      marks.push([rect.x + p.tableRule[0], y, Math.min(rect.x + rect.width, rect.x + p.tableRule[0] + p.tableRule[1]), y]);
    }
    let spans = "";
    // One tspan per run of like-styled text between tabs, whitespace-only pieces left out.
    let i = 0;
    const gs = l.glyphs as (Glyph & { r: Run })[];
    while (i < gs.length) {
      const r = gs[i].r;
      let j = i;
      let text = "";
      const font = fontOf(gs[i].ch);
      while (j < gs.length && sameStyle(gs[j].r, r) && gs[j].ch !== "\t" && fontOf(gs[j].ch) === font) { text += gs[j].ch; j++; }
      const shown = text.replaceAll("\n", "").replaceAll(SEP, "");
      if (shown.trim() !== "") {
        let a = `font-size="${fmt(r.size)}"`;
        if (r.mono) a += ` font-family="Menlo, Consolas, monospace"`;
        if (r.bold) a += ` font-weight="bold"`;
        if (r.italic) a += ` font-style="italic"`;
        if (r.underline) a += ` text-decoration="underline"`;
        if (r.alpha < 1) a += ` fill-opacity="${fmt(r.alpha * e.style.stroke.a)}"`;
        spans += `<tspan x="${fmt(rect.x + gs[i].x)}" ${a}>${escapeXML(shown)}</tspan>`;
      }
      if (r.strike && j > i) {
        const y = l.baseline - metrics(gs[i].ch, r)[0] * 0.32;
        marks.push([rect.x + gs[i].x, rect.y + y, rect.x + gs[j - 1].x + gs[j - 1].w, rect.y + y]);
      }
      if (j === i) j++;   // a tab
      i = j;
    }
    if (spans) s += `<text y="${fmt(rect.y + l.baseline)}" font-family="Helvetica Neue, Helvetica, Arial, sans-serif" fill="${ink}" xml:space="preserve">${spans}</text>\n`;
  }
  const width = fmt(Math.max(1, e.style.fontSize / 14));
  for (const [x1, y1, x2, y2] of marks) {
    s += `<line x1="${fmt(x1)}" y1="${fmt(y1)}" x2="${fmt(x2)}" y2="${fmt(y2)}" stroke="${ink}" stroke-width="${width}"/>\n`;
  }
  return s;
}

/** Characters Helvetica Neue lacks come from a fallback font, in a CoreText run of their own. */
function fontOf(ch: string): string {
  return fallbackMetrics[ch] ? `fb:${ch}` : "";
}

function sameStyle(a: Run, b: Run): boolean {
  return a === b || (a.size === b.size && a.bold === b.bold && a.italic === b.italic && a.mono === b.mono
    && a.strike === b.strike && a.underline === b.underline && a.alpha === b.alpha);
}
