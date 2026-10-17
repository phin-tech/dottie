// Symbols: a heartbeat light and a turning cog, each drawn and animated once, then placed beside every service.
// Every copy plays on its own clock: the lights blink out of step, and one cog runs at double size.
const k = dottie.build({direction: "LR", sketchy: true,
  nodes: [
    {key: "g", text: "Gateway", fill: "#8cbfff"},
    {key: "o", text: "Orders", fill: "#8cbfff"},
    {key: "p", text: "Payments", fill: "#c9a7ff"},
    {key: "w", text: "Worker", fill: "#7fd98c"},
  ],
  edges: [{from: "g", to: "o"}, {from: "o", to: "p"}, {from: "o", to: "w"}]});

// The heartbeat: a dot that flares and fades over 1.2 s.
dottie.timeline({fps: 24, duration: 1.2});
const dot = dottie.ellipse({x: 0, y: 0, width: 18, height: 18, fill: "#2f9e44", stroke: "#2f9e44"});
dottie.key(dot, 0, {opacity: 1, width: 18, height: 18, x: 0, y: 0});
dottie.key(dot, 0.3, {opacity: 0.25, width: 26, height: 26, x: -4, y: -4, ease: "easeOut"});
dottie.key(dot, 1.2, {opacity: 1, width: 18, height: 18, x: 0, y: 0});
const beat = dottie.symbol([dot], {name: "Heartbeat"});

// The cog: a hatched block that turns once every 2 s.
dottie.timeline({duration: 2});
const wheel = dottie.rect({x: 0, y: 0, width: 40, height: 40, fill: "#f08c00", fillStyle: "hachure"});
dottie.key(wheel, 0, {rotation: 0}); dottie.key(wheel, 2, {rotation: 6.283});
const cog = dottie.symbol([wheel], {name: "Cog"});
dottie.remove(cog.instance);

// One light per service, each starting at a different point in its blink.
dottie.remove(beat.instance);
dottie.timeline({duration: 4.8});
[k.g, k.o, k.p, k.w].forEach((id, i) => {
  const box = dottie.get(id);
  dottie.place("Heartbeat", {x: box.x + box.width - 12, y: box.y - 6, offset: i * 0.4});
});
const w = dottie.get(k.w);
dottie.place("Cog", {x: w.x + w.width / 2 - 20, y: w.y + w.height + 20});
dottie.place("Cog", {x: w.x + w.width / 2 + 30, y: w.y + w.height + 10, width: 80});
return dottie.symbols();
