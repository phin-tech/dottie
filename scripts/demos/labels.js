// Labelled packets: a checkout flow where named requests and events keep flowing, each on its own beat.
const k = dottie.build({direction: "LR", sketchy: true,
  nodes: [{key: "app", text: "Checkout page", fill: "#ffd966"},
          {key: "api", text: "Orders API", fill: "#8cbfff"},
          {key: "db", text: "Postgres", fill: "#ff99b3"},
          {key: "bus", text: "Event bus", fill: "#c9a7ff"},
          {key: "mail", text: "Email worker", fill: "#7fd98c"}],
  edges: [{from: "app", to: "api"}, {from: "api", to: "db"}, {from: "api", to: "bus"}, {from: "bus", to: "mail"}]});
dottie.timeline({fps: 24, duration: 4, boil: 3});
const arrows = dottie.elements({kind: "connector"});
const arrow = (f, t) => arrows.find(e => e.from === k[f] && e.to === k[t]);
// One order every 4 seconds: the request, then the write and the event together, then the email.
const send = (f, t, at, label, color) => dottie.repeat(dottie.packet(arrow(f, t), at, {duration: 0.9, color, label}), 0, 4);
send("app", "api", 0, "POST /orders", "#e8590c");
send("api", "db", 1, "INSERT order", "#c2255c");
send("api", "bus", 1, "order.created", "#7048e8");
send("bus", "mail", 2.1, "send receipt", "#2f9e44");
dottie.transition(k.mail, "pulse", 3.1, {duration: 0.6});
return dottie.timeline();
