# Animation demos

Every one of these is a Dottie drawing animated by a short script, played right here from the drawing itself
by [dottie.js](https://github.com/phin-tech/dottie/tree/main/web): press play, drag the slider, or use the
arrow keys. The scripts are in
[scripts/demos](https://github.com/phin-tech/dottie/tree/main/scripts/demos); the same things can be done from
the Animate menu, or by asking an assistant.

## Zooms

The camera chases one order through a checkout flow, pushing in on each step and pulling back to show the
whole system.

<dottie-player class="player" src="../drawings/zoom.dottie" label="Camera zooms"></dottie-player>

## A click-through tour

Camera moves with a named scene at each stop. It plays to each scene and stops: press ⏭ (or →) to continue,
⏮ (or ←) to go back.

<dottie-player class="player" src="../drawings/tour.dottie" label="A click-through tour"></dottie-player>

## Labelled requests

Packets that carry a label, like `POST /orders` and `order.created`, flowing between services on a loop.

<dottie-player class="player" src="../drawings/labels.dottie" label="Labelled requests"></dottie-player>

## Traffic that never stops

Repeating packets and status lights that keep pulsing.

<dottie-player class="player" src="../drawings/live.dottie" label="Live service map"></dottie-player>

## Magic Move

A sprint board, drawn twice: as it is now on the first page, and two days on on a second. Animate ▸ Magic Move
to Next Page (or `dottie.magicMove`) tweens one into the other, Keynote-style: cards with the same text slide to
their new column and change color, on a spring; the new card fades in and the dropped one fades out.

<dottie-player class="player" src="../drawings/board.dottie" label="Magic Move"></dottie-player>

## Marching ants

An event stream whose parts drop in with a bounce, and whose arrows draw on and then keep marching: Animate ▸
March Selected Lines sets the dashes of a line travelling along it, for anything that flows.

<dottie-player class="player" src="../drawings/stream.dottie" label="Marching ants"></dottie-player>

## One after another

Shapes that enter, and wiggle, in turn.

<dottie-player class="player" src="../drawings/stagger.dottie" label="Staggered transitions"></dottie-player>


## As Lottie

File ▸ Export Animation ▸ Lottie saves an animation as [Lottie](https://airbnb.io/lottie/) JSON, which websites
and iOS and Android apps play with Lottie's own players, all vector. This is the diagram on the home page,
exported in smooth mode ([build.json](lottie/build.json), 250 KB) and played by lottie-web:

<div id="lottie-build" class="player" role="img" aria-label="The home page's diagram building itself, played by lottie-web"></div>
<script src="https://cdnjs.cloudflare.com/ajax/libs/lottie-web/5.12.2/lottie_svg.min.js"></script>
<script>
  lottie.loadAnimation({ container: document.getElementById("lottie-build"), renderer: "svg", loop: true,
                         autoplay: !matchMedia("(prefers-reduced-motion: reduce)").matches, path: "../lottie/build.json" });
</script>

Smooth mode lets the player tween between moments and holds the sketchy lines still; exact mode keeps every
frame as Dottie draws it, boil and all.
