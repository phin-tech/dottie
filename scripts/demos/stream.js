// Marching ants and springy eases: an event stream. The parts drop in with a bounce, then the arrows draw on and
// keep marching, like events flowing for good.
const k = dottie.build({direction: "LR", sketchy: true,
  nodes: [{key: "app", text: "Checkout", fill: "#ffd966"}, {key: "bus", text: "Event stream", fill: "#d0bfff"},
          {key: "mail", text: "Emails", fill: "#8cbfff"}, {key: "stats", text: "Analytics", fill: "#8ce99a"},
          {key: "stock", text: "Inventory", fill: "#ffa8a8"}],
  edges: [{from: "app", to: "bus"}, {from: "bus", to: "mail"}, {from: "bus", to: "stats"}, {from: "bus", to: "stock"}]});
dottie.timeline({fps: 24, duration: 5, boil: 3});
["app", "bus", "mail", "stats", "stock"].forEach((n, i) => dottie.transition(k[n], "dropIn", i * 0.2, {duration: 0.9}));
for (const arrow of dottie.elements({kind: "connector"})) {
  dottie.transition(arrow, "drawIn", 1.6, {duration: 0.5});
  dottie.march(arrow, {speed: 32});
}
return dottie.timeline();
