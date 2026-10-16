// Zooms: the camera chases one order through the checkout flow, pushing in on each step and pulling back
// to show the whole system at the end.
const k = dottie.build({direction: "LR", sketchy: true,
  nodes: [{key: "app", text: "Checkout page", fill: "#ffd966"},
          {key: "api", text: "Orders API", fill: "#8cbfff"},
          {key: "db", text: "Postgres", fill: "#ff99b3"},
          {key: "bus", text: "Event bus", fill: "#c9a7ff"},
          {key: "mail", text: "Email worker", fill: "#7fd98c"}],
  edges: [{from: "app", to: "api"}, {from: "api", to: "db"}, {from: "api", to: "bus"}, {from: "bus", to: "mail"}]});
dottie.timeline({fps: 24, boil: 3});
const arrows = dottie.elements({kind: "connector"});
const arrow = (f, t) => arrows.find(e => e.from === k[f] && e.to === k[t]);
dottie.packet(arrow("app", "api"), 0.6, {duration: 1.1, color: "#e8590c", label: "POST /orders"});
dottie.packet(arrow("api", "db"), 2.2, {duration: 1.0, color: "#c2255c", label: "INSERT order"});
dottie.packet(arrow("api", "bus"), 2.2, {duration: 1.0, color: "#7048e8", label: "order.created"});
dottie.packet(arrow("bus", "mail"), 3.8, {duration: 1.0, color: "#2f9e44", label: "send receipt"});
dottie.transition(k.api, "pulse", 1.7, {duration: 0.5});
dottie.transition([k.db, k.bus], "pulse", 3.2, {duration: 0.5, stagger: 0});
dottie.transition(k.mail, "pulse", 4.8, {duration: 0.5});

// The camera: tight on the page, push along with the request, pull back for the fork, chase the receipt,
// then the whole picture.
dottie.camera(0, k.app, {padding: 30});
dottie.camera(0.6, k.app, {padding: 30});
dottie.camera(1.7, k.api, {padding: 30});
dottie.camera(2.4, [k.api, k.db, k.bus], {padding: 30});
dottie.camera(3.3, [k.api, k.db, k.bus], {padding: 30});
dottie.camera(3.9, [k.bus, k.mail], {padding: 30});
dottie.camera(4.8, k.mail, {padding: 30});
dottie.camera(5.6, k.mail, {padding: 30});
dottie.camera(6.6, [k.app, k.api, k.db, k.bus, k.mail], {padding: 30});
dottie.timeline({duration: 8});
return dottie.timeline();
