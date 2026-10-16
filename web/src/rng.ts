// DottieKit's SeededRNG (SplitMix64) and boil reseeding, bit for bit: the same seed draws the same sketch.
// Wrapping 64-bit arithmetic on two 32-bit halves; Number arithmetic alone would silently lose bits.

const GOLDEN_HI = 0x9e3779b9, GOLDEN_LO = 0x7f4a7c15;
const M1_HI = 0xbf58476d, M1_LO = 0x1ce4e5b9;
const M2_HI = 0x94d049bb, M2_LO = 0x133111eb;

/** (hi, lo) as unsigned 32-bit halves of a 64-bit value. */
type U64 = [number, number];

function add(a: U64, bh: number, bl: number): U64 {
  const lo = (a[1] + bl) >>> 0;
  const carry = lo < a[1] ? 1 : 0;
  return [(a[0] + bh + carry) >>> 0, lo];
}

/** 32 x 32 -> 64 bits. */
function mul32(a: number, b: number): U64 {
  const a0 = a & 0xffff, a1 = a >>> 16, b0 = b & 0xffff, b1 = b >>> 16;
  const p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;
  const mid = p01 + p10;                                   // < 2^33, exact
  const lo = p00 + (mid % 0x10000) * 0x10000;              // < 2^49, exact
  const hi = p11 + Math.floor(mid / 0x10000) + Math.floor(lo / 0x100000000);
  return [hi >>> 0, lo >>> 0];
}

function mul(a: U64, bh: number, bl: number): U64 {
  const low = mul32(a[1], bl);
  const hi = (low[0] + Math.imul(a[0], bl) + Math.imul(a[1], bh)) >>> 0;
  return [hi, low[1]];
}

/** a ^ (a >> s), 0 < s < 32. */
function xorShift(a: U64, s: number): U64 {
  const lo = ((a[1] >>> s) | (a[0] << (32 - s))) >>> 0;
  return [(a[0] ^ (a[0] >>> s)) >>> 0, (a[1] ^ lo) >>> 0];
}

function mix(z: U64): U64 {
  z = mul(xorShift(z, 30), M1_HI, M1_LO);
  z = mul(xorShift(z, 27), M2_HI, M2_LO);
  return xorShift(z, 31);
}

export class SeededRNG {
  private state: U64;
  constructor(seed: number) { this.state = add([0, seed >>> 0], GOLDEN_HI, GOLDEN_LO); }

  /** The next 64 bits, as (hi, lo). */
  next(): U64 {
    this.state = add(this.state, GOLDEN_HI, GOLDEN_LO);
    return mix(this.state);
  }

  /** The top 53 bits of `next()`, exactly. */
  private top53(): number {
    const [hi, lo] = this.next();
    return hi * 0x200000 + (lo >>> 11);   // (hi:lo) >> 11
  }

  /** Uniform in -1...1. */
  signed(): number { return Math.floor(this.top53()) / 2 ** 52 - 1; }
  /** Uniform in 0...1. */
  unit(): number { return this.top53() / 2 ** 53; }
}

/** A different but repeatable seed for each boil step, never 0 (DottieDocument.boiled). */
export function boiled(seed: number, step: number): number {
  let z = add([0, seed >>> 0], ...mulConst(step));
  z = mix(z);
  return Math.max(1, z[1] >>> 0);
}

/** step * 0x9E3779B97F4A7C15, wrapping, as (hi, lo). */
function mulConst(step: number): [number, number] {
  const p = mul([0, step >>> 0], GOLDEN_HI, GOLDEN_LO);
  return [p[0], p[1]];
}
