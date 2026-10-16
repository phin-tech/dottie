// Stagger: a sprint board whose notes pop in column by column, then the Doing column wiggles card by card.
const cols = [["To do", "#fff3a3", ["Sketch the onboarding", "Write the API docs", "Pick an icon"]],
              ["Doing", "#ffd1dc", ["Timeline editor", "Camera moves", "Scene markers"]],
              ["Done", "#c8f7c5", ["Fades", "Onion skin", "Draw-on strokes"]]];
const titles = [], columns = [];
cols.forEach(([title, fill, items], c) => {
  titles.push(dottie.text({x: 30 + c * 230, y: 0, width: 200, height: 30, text: title, fontSize: 22}));
  columns.push(items.map((t, r) => dottie.note({x: 20 + c * 230, y: 50 + r * 130, width: 200, height: 110, text: "**" + t + "**", fill})));
});
dottie.timeline({fps: 24, boil: 3, settle: true});
dottie.transition(titles, "fadeIn", 0, {stagger: 0.2});
columns.forEach((notes, c) => dottie.transition(notes, "popIn", 0.5 + c * 0.6, {stagger: 0.15}));
dottie.transition(columns[1], "wiggle", 3, {stagger: 0.2});
dottie.timeline({duration: 5});
return dottie.timeline();
