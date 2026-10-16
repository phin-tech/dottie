// The README's animation (Design/animation.*): an architecture diagram that builds itself, then one request
// running through it. Regenerate with `just readme-animation`, which runs this through dottie-mcp.
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
dottie.animateBuild({transition: "drawIn", drawArrows: true, packets: true, travel: 0.45, stagger: 0.35});

// Then one request runs the whole way through.
const arrows = dottie.elements({kind: "connector"});
const arrow = (a, b) => arrows.find(c => c.from === k[a] && c.to === k[b]);
let t = dottie.timeline().duration - 0.2;
for (const [a, b] of [["b", "g"], ["g", "o"], ["o", "q"], ["q", "w"]]) {
  dottie.packet(arrow(a, b), t, {duration: 0.5, color: "#e8590c", size: 16});
  t += 0.5;
}
dottie.transition(k.w, "pulse", t);
const box = dottie.bounds();
const caption = dottie.text({x: box.x, y: box.y + box.height + 20, width: box.width, height: 30,
                             text: "drawn, animated and exported by Dottie"});
dottie.transition(caption, "fadeIn", t + 0.3, {duration: 0.6});
dottie.timeline({duration: t + 2.2});
return dottie.timeline();
