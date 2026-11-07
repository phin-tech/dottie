// The script a page includes to get <dottie-player>: registers the element and exposes the library as
// `window.Dottie` for non-module use.

import * as Dottie from "./index.ts";
import { servePlans } from "./planner.ts";

// Started as a worker to plan a big animation (planner.ts), it only answers; on a page, it defines the player.
servePlans();
Dottie.definePlayer();
(globalThis as { Dottie?: typeof Dottie }).Dottie ??= Dottie;

export * from "./index.ts";
