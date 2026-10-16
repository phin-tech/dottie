// The "After" page for board.js: the same board two days on.
const columns = ["To do", "Doing", "Done"];
columns.forEach((name, i) => dottie.rect({x: 40 + i * 260, y: 20, width: 230, height: 44, text: name, fill: "#e9ecef", sketchy: false}));
const cards = [["Write the docs", 0, "#ffe066"], ["Design login", 1, "#a5d8ff"], ["API for orders", 1, "#a5d8ff"],
               ["Fix flaky test", 2, "#b2f2bb"], ["Set up CI", 2, "#b2f2bb"]];
const row = [0, 0, 0];
for (const [text, col, fill] of cards) {
  dottie.note({x: 55 + col * 260, y: 84 + row[col]++ * 104, width: 200, height: 88, text: text, fill: fill});
}
