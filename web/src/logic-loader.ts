// Finding the click-logic engine (dist/dottie-logic.min.js, ADR 0007) for <dottie-player>: already on the page (a
// script tag, or inlined by the HTML export), beside the module player, or beside the classic script.

import type { ClickEvent, LogicResult } from "./logic.ts";
import type { Var } from "./expression.ts";

interface Engine {
  loadLogic(): Promise<void>;
  runLogic(source: string, handler: string, state: Record<string, Var>, event: ClickEvent): LogicResult;
}

// The classic script's own address, known only while it first runs.
const scriptSrc = typeof document !== "undefined" ? (document.currentScript as HTMLScriptElement | null)?.src ?? null : null;

let found: Promise<Engine> | null = null;

const present = (): Engine | undefined => (globalThis as { DottieLogic?: Engine }).DottieLogic;

/** The engine, loaded; rejects where it can't be had. */
export function logicEngine(): Promise<Engine> {
  found ??= (async () => {
    if (!present()) {
      const here: string | undefined = import.meta.url;   // undefined in the classic-script build
      const base = here ?? scriptSrc;
      if (!base) throw new Error("No dottie-logic.min.js on the page, and no address to find it from");
      const url = new URL("./dottie-logic.min.js", base).href;
      if (here) await import(/* @vite-ignore */ url);
      else await new Promise<void>((resolve, reject) => {
        const s = document.createElement("script");
        s.src = url; s.onload = () => resolve(); s.onerror = () => reject(new Error(`Couldn't load ${url}`));
        document.head.append(s);
      });
    }
    const engine = present();
    if (!engine) throw new Error("dottie-logic.min.js didn't load");
    await engine.loadLogic();
    return engine;
  })();
  found.catch(() => { found = null; });
  return found;
}
