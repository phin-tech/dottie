// Clicks: an architecture diagram that waits for you. Click Auth or Orders (in the .html export or
// <dottie-player>) to watch that request go through; Back returns to the overview.
const k = dottie.build({direction: "LR", sketchy: true,
  nodes: [
    {key: "b", text: "Browser", fill: "#ffd966"},
    {key: "g", text: "API gateway", fill: "#8cbfff"},
    {key: "a", text: "Auth", fill: "#c9a7ff"},
    {key: "o", text: "Orders", fill: "#8cbfff"},
    {key: "d", text: "Postgres", fill: "#ff99b3"},
    {key: "q", text: "Queue", fill: "#7fd98c"},
    {key: "w", text: "Worker", fill: "#7fd98c"},
  ],
  edges: [{from: "b", to: "g"}, {from: "g", to: "a"}, {from: "g", to: "o"},
          {from: "o", to: "d"}, {from: "o", to: "q"}, {from: "q", to: "w"}]});
dottie.timeline({fps: 24, boil: 3, settle: true});

const arrows = dottie.elements({kind: "connector"});
const arrow = (a, b) => arrows.find(c => c.from === k[a] && c.to === k[b]);
const run = (t, hops, color) => {
  for (const [a, b] of hops) { dottie.packet(arrow(a, b), t, {duration: 0.5, color, size: 14}); t += 0.5; }
  return t;
};

// Each flow is a scene: a click plays it on to the next scene, and the player waits there.
dottie.scene(0, "Overview");
dottie.scene(0.5, "Sign in");
let t = run(0.6, [["b", "g"], ["g", "a"]], "#7048e8");
dottie.transition(k.a, "pulse", t);
dottie.scene(t + 1, "Place an order");
t = run(t + 1.1, [["b", "g"], ["g", "o"], ["o", "d"]], "#e8590c");
t = run(t, [["o", "q"], ["q", "w"]], "#2f9e44");
dottie.transition(k.w, "pulse", t);
dottie.timeline({duration: t + 1});

const box = dottie.bounds();
const hint = dottie.text({x: box.x, y: box.y + box.height + 20, width: box.width - 110, height: 30,
                          text: "Click Auth or Orders to follow a request"});
const back = dottie.rect({x: box.x + box.width - 90, y: box.y + box.height + 14, width: 90, height: 40, text: "Back"});
const look = {stroke: "#1c7ed6", fill: "#d0ebff"};
dottie.update(k.a, {click: {scene: "Sign in"}, hover: look});
dottie.update(k.o, {click: {scene: "Place an order"}, hover: look});
dottie.update(back, {click: {scene: "Overview"}, hover: look});
dottie.timeline({poster: 0});
return dottie.timeline();
