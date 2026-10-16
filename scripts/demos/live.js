// Repeat: a live service map. Requests keep flowing to the servers and on to Postgres, and status lights pulse.
const k = dottie.build({direction: "LR", sketchy: true,
  nodes: [{key: "lb", text: "Load balancer", fill: "#ffd966"},
          {key: "a", text: "web-1", fill: "#8cbfff"}, {key: "b", text: "web-2", fill: "#8cbfff"}, {key: "c", text: "web-3", fill: "#8cbfff"},
          {key: "db", text: "Postgres", fill: "#ff99b3"}],
  edges: [{from: "lb", to: "a"}, {from: "lb", to: "b"}, {from: "lb", to: "c"},
          {from: "a", to: "db"}, {from: "b", to: "db"}, {from: "c", to: "db"}]});
dottie.timeline({fps: 24, duration: 6, boil: 3});
const arrows = dottie.elements({kind: "connector"});
const arrow = (f, t) => arrows.find(e => e.from === k[f] && e.to === k[t]);
// Each server gets a request every 1.5 s, the three a beat apart, and passes it on to the database.
["a", "b", "c"].forEach((s, i) => {
  const t = i * 0.5;
  const req = dottie.packet(arrow("lb", s), t, {duration: 0.6, color: "#e8590c", size: 14});
  const q = dottie.packet(arrow(s, "db"), t + 0.6, {duration: 0.6, color: "#7048e8", size: 12});
  dottie.repeat(req, 0, 1.5);
  dottie.repeat(q, 0, 1.5);
});
// A status light on each server, pulsing for good.
["a", "b", "c"].forEach((s, i) => {
  const box = dottie.get(k[s]);
  const light = dottie.ellipse({x: box.x + box.width - 18, y: box.y - 8, width: 16, height: 16, fill: "#2f9e44", fillStyle: "solid", sketchy: false});
  dottie.transition(light, "pulse", i * 0.3, {duration: 0.9, repeat: true});
});
return dottie.timeline();
