// Magic Move: a sprint board two days on. Page 1 is the board now, the "After" page (board.after.js) the board
// later; dottie.magicMove tweens one into the other. Cards match by their text: they slide to their new column,
// the new card fades in and the dropped spike fades out, all on a spring.
const columns = ["To do", "Doing", "Done"];
columns.forEach((name, i) => dottie.rect({x: 40 + i * 260, y: 20, width: 230, height: 44, text: name, fill: "#e9ecef", sketchy: false}));
const cards = [["Design login", 0, "#ffe066"], ["API for orders", 0, "#ffe066"], ["Spike: caching", 0, "#ffc9c9"],
               ["Fix flaky test", 1, "#a5d8ff"], ["Set up CI", 2, "#b2f2bb"]];
const row = [0, 0, 0];
for (const [text, col, fill] of cards) {
  dottie.note({x: 55 + col * 260, y: 84 + row[col]++ * 104, width: 200, height: 88, text: text, fill: fill});
}
dottie.timeline({fps: 24, duration: 0.8});
const moved = dottie.magicMove("After", {t: 0.8, duration: 1.4, ease: "spring"});
dottie.timeline({duration: 3.4});
return moved;
