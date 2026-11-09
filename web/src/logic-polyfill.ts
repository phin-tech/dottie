// What QuickJS's loader needs that JavaScriptCore lacks (it isn't a browser): UTF-8 TextEncoder and TextDecoder,
// and atob. Each is added only where it's missing, so browsers use their own.

/** Adds what's missing; safe to call more than once. */
export function polyfill(): void {
const g = globalThis as Record<string, unknown>;

if (typeof g.TextDecoder === "undefined") {
  g.TextDecoder = class {
    decode(input?: ArrayBufferView | ArrayBuffer): string {
      if (!input) return "";
      const b = input instanceof ArrayBuffer ? new Uint8Array(input) : new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
      let out = "";
      for (let i = 0; i < b.length;) {
        const c = b[i++];
        let cp: number;
        if (c < 0x80) cp = c;
        else if (c < 0xe0) cp = ((c & 0x1f) << 6) | (b[i++] & 0x3f);
        else if (c < 0xf0) cp = ((c & 0x0f) << 12) | ((b[i++] & 0x3f) << 6) | (b[i++] & 0x3f);
        else cp = ((c & 0x07) << 18) | ((b[i++] & 0x3f) << 12) | ((b[i++] & 0x3f) << 6) | (b[i++] & 0x3f);
        out += String.fromCodePoint(cp);
      }
      return out;
    }
  };
}

if (typeof g.TextEncoder === "undefined") {
  g.TextEncoder = class {
    encode(s = ""): Uint8Array {
      const out: number[] = [];
      for (const ch of s) {
        const cp = ch.codePointAt(0)!;
        if (cp < 0x80) out.push(cp);
        else if (cp < 0x800) out.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
        else if (cp < 0x10000) out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
        else out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
      }
      return new Uint8Array(out);
    }
  };
}

if (typeof g.atob === "undefined") {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  g.atob = (s: string): string => {
    const clean = s.replace(/[^A-Za-z0-9+/]/g, "");
    let out = "", bits = 0, value = 0;
    for (const ch of clean) {
      value = (value << 6) | chars.indexOf(ch); bits += 6;
      if (bits >= 8) { bits -= 8; out += String.fromCharCode((value >> bits) & 0xff); }
    }
    return out;
  };
}
}
