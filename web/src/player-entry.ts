// The script a page includes to get <dottie-player>: registers the element and exposes the library as
// `window.Dottie` for non-module use.

import * as Dottie from "./index.ts";

Dottie.definePlayer();
(globalThis as { Dottie?: typeof Dottie }).Dottie ??= Dottie;

export * from "./index.ts";
