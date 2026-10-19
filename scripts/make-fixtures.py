#!/usr/bin/env python3
"""Writes the edge-case fixtures in fixtures/edge: small .dottie files that each exercise one corner of the
format (every element kind, routing, arrowhead, transition, follow, repeat, camera, theme, damaged timelines),
for the contract between Dottie and dottie.js (see web/ and `just goldens`).

Files that Dottie itself can't open but dottie.js must survive (unknown kinds, newer versions) go in
fixtures/js-only: they have no goldens.

Deterministic: ids are counters and seeds are fixed, so running it twice changes nothing.
"""
import base64
import json
import math
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EDGE = ROOT / "fixtures" / "edge"
JS_ONLY = ROOT / "fixtures" / "js-only"

_next = [0]


def uid(lower=False):
    _next[0] += 1
    n = _next[0]
    s = f"{n:08X}-0000-4000-8000-{n:012X}"
    return s.lower() if lower else s


def rgba(r, g, b, a=1):
    return {"r": r, "g": g, "b": b, "a": a}


INK = rgba(0.12, 0.12, 0.13)
CLEAR = rgba(0, 0, 0, 0)


def style(**kw):
    s = {"stroke": INK, "fill": CLEAR, "fillStyle": "solid", "strokeWidth": 2, "dash": "solid",
         "roughness": 1, "bowing": 1, "fontSize": 18}
    s.update(kw)
    return s


class Page:
    def __init__(self, name="Page 1", theme=None, layers=1):
        self.id = uid()
        self.name = name
        self.theme = theme
        self.layers = [{"id": uid(), "name": f"Layer {i + 1}", "visible": True, "locked": False} for i in range(layers)]
        self.elements = []
        self.timeline = None
        self.seed = 1000

    @property
    def layer(self):
        return self.layers[0]["id"]

    def add(self, kind, x, y, w, h, layer=None, **kw):
        self.seed = (self.seed * 1103515245 + 12345) % 4294967291 + 1
        st = kw.pop("style", None) or style()
        e = {"id": kw.pop("id", None) or uid(), "kind": kind, "x": x, "y": y, "width": w, "height": h,
             "style": st, "seed": self.seed, "layerID": layer or self.layer}
        e.update(kw)
        self.elements.append(e)
        return e["id"]

    def connect(self, a, b, routing="straight", start_port=None, end_port=None, start_head="none", end_head="arrow",
                text=None, st=None, free_start=None, free_end=None, waypoints=None, hops=None, layer=None):
        def ep(target, port, free):
            if free is not None:
                return {"x": free[0], "y": free[1]}
            d = {"elementID": target, "x": 0, "y": 0}
            if port:
                d["port"] = port
            return d
        kw = {"connector": {"start": ep(a, start_port, free_start), "end": ep(b, end_port, free_end),
                            "routing": routing, "startHead": start_head, "endHead": end_head}}
        if waypoints is not None:
            kw["connector"]["waypoints"] = [{"x": x, "y": y} for x, y in waypoints]
        if hops is not None:
            kw["connector"]["hops"] = hops
        if text:
            kw["text"] = text
        return self.add("connector", 0, 0, 0, 0, style=st or style(), layer=layer, **kw)

    def animate(self, duration, fps=12, **kw):
        self.timeline = {"fps": fps, "duration": duration, "tracks": []}
        self.timeline.update(kw)
        return self.timeline

    def track(self, element, keys, **kw):
        t = {"element": element, "keys": keys}
        t.update(kw)
        self.timeline["tracks"].append(t)
        return t

    def json(self):
        d = {"id": self.id, "name": self.name, "layers": self.layers, "elements": self.elements}
        d.update(getattr(self, "extra", {}))
        if self.theme:
            d["theme"] = self.theme
        if self.timeline is not None:
            d["timeline"] = self.timeline
        return d


def write(path, pages, version=2, images=None, extra=None):
    d = {"version": version, "pages": [p.json() for p in pages]}
    if images:
        d["images"] = images
    if extra:
        d.update(extra)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")


def png(w, h, color):
    raw = b"".join(b"\x00" + bytes(color) * w for _ in range(h))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def shapes():
    p = Page(layers=2)
    top = p.layers[1]["id"]
    yellow = rgba(1, 0.85, 0.4)
    p.add("rectangle", 20, 20, 120, 70, text="Rectangle", style=style(fill=yellow))
    p.add("ellipse", 170, 20, 120, 70, text="Ellipse", style=style(fill=rgba(0.6, 0.85, 1)))
    p.add("diamond", 320, 10, 120, 90, text="Diamond", style=style(fill=rgba(0.7, 0.95, 0.7)))
    p.add("text", 470, 25, 140, 60, text="Free text\nover two lines")
    # Fill styles, dashes, widths and bowing.
    for i, fs in enumerate(["hachure", "crossHatch", "solid"]):
        p.add("rectangle", 20 + i * 150, 130, 120, 70, style=style(fill=rgba(0.9, 0.4, 0.3), fillStyle=fs, strokeWidth=1 + i))
    p.add("ellipse", 470, 130, 120, 70, style=style(fill=rgba(0.3, 0.5, 0.9), fillStyle="hachure"))
    p.add("diamond", 620, 120, 100, 90, style=style(fill=rgba(0.3, 0.7, 0.4), fillStyle="crossHatch"))
    p.add("rectangle", 20, 240, 120, 60, style=style(dash="dashed"))
    p.add("ellipse", 170, 240, 120, 60, style=style(dash="dotted", strokeWidth=3))
    p.add("rectangle", 320, 240, 120, 60, style=style(roughness=0, fill=yellow), text="Clean")
    p.add("rectangle", 470, 240, 120, 60, style=style(roughness=2, bowing=0), text="Rough, no bow")
    p.add("rectangle", 620, 240, 120, 60, style=style(roughness=1, bowing=4))
    # Rotation and opacity.
    p.add("rectangle", 20, 340, 120, 60, rotation=0.4, text="Rotated", style=style(fill=yellow))
    p.add("ellipse", 170, 340, 120, 60, rotation=-1.1, style=style(fill=rgba(0.6, 0.85, 1), fillStyle="hachure"))
    p.add("diamond", 320, 330, 100, 80, style=style(fill=yellow, opacity=0.4), text="40%")
    p.add("text", 470, 340, 140, 40, rotation=0.25, text="Tilted text")
    # Freehand: fitted and raw.
    p.add("freehand", 20, 440, 160, 80, path=[0, 0.5, 0.2, 0, 0.4, 0, 0.5, 0.5, 0.6, 1, 0.8, 1, 1, 0.5])
    p.add("freehand", 200, 440, 160, 80, points=[{"x": 0, "y": 1}, {"x": 0.25, "y": 0.2}, {"x": 0.5, "y": 0.8},
                                                   {"x": 0.75, "y": 0}, {"x": 1, "y": 0.6}])
    p.add("freehand", 380, 440, 40, 40, points=[{"x": 0, "y": 0}, {"x": 1, "y": 1}])
    # Paths: a closed star with a hole (even-odd), an open curve.
    star = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        r = 0.5 if i % 2 == 0 else 0.2
        star.append((0.5 + r * math.cos(a), 0.5 + r * math.sin(a)))
    coords = [*star[0]]
    for i in range(1, 11):
        a, b = star[i - 1], star[i % 10]
        coords += [a[0], a[1], b[0], b[1], b[0], b[1]]
    hole = [0.45, 0.45, 0.45, 0.45, 0.55, 0.45, 0.55, 0.45, 0.55, 0.45, 0.55, 0.55, 0.55, 0.55,
            0.55, 0.55, 0.45, 0.55, 0.45, 0.55, 0.45, 0.55, 0.45, 0.45, 0.45, 0.45]
    p.add("path", 450, 430, 100, 100, evenOdd=True, subpaths=[{"closed": True, "coords": coords}, {"closed": True, "coords": hole}],
          style=style(fill=rgba(0.95, 0.75, 0.2)))
    p.add("path", 580, 440, 140, 80, subpaths=[{"closed": False, "coords": [0, 1, 0.2, 0, 0.8, 0, 1, 1]}])
    p.add("path", 580, 540, 140, 80, subpaths=[{"closed": True, "coords": [0, 1, 0.2, 0, 0.8, 0, 1, 1, 1, 1, 0, 1, 0, 1]}],
          style=style(fill=rgba(0.6, 0.85, 1), fillStyle="hachure"), rotation=0.2)
    # Notes: Markdown, unfilled, on the second layer.
    p.add("note", 20, 560, 200, 150, layer=top, text="# Heading\nSome **bold** and *italic* text with `code`.\n\n- one\n- two\n  - nested",
          style=style(fill=rgba(1, 0.91, 0.52), strokeWidth=1, fontSize=16))
    p.add("note", 240, 560, 160, 100, text="Plain note with a long line that wraps at the edge of the card",
          style=style(fill=CLEAR, strokeWidth=1, fontSize=14))
    # Pictures: inline, by reference, a dangling reference, with a border.
    data = png(4, 3, (200, 60, 40))
    b64 = base64.b64encode(data).decode()
    import hashlib
    digest = hashlib.sha256(data).hexdigest()
    p.add("image", 420, 560, 80, 60, image={"ref": digest}, style=style(stroke=CLEAR))
    p.add("image", 520, 560, 80, 60, image={"ref": digest}, style=style(strokeWidth=3), rotation=0.3)
    p.add("image", 620, 560, 80, 60, image={"ref": "0" * 64}, style=style(stroke=CLEAR))
    p.add("image", 420, 640, 40, 30, image={"data": b64, "format": "png"}, style=style(stroke=CLEAR))
    # Layer order: an element on the top layer listed first still draws over the one below.
    p.elements.insert(0, {**p.elements[0], "id": uid(), "x": 60, "y": 50, "layerID": top,
                          "style": style(fill=rgba(0.9, 0.5, 0.9)), "text": "On top"})
    # A shape on a hidden layer is not drawn.
    hidden = {"id": uid(), "name": "Hidden", "visible": False, "locked": False}
    p.layers.append(hidden)
    p.add("rectangle", 300, 600, 60, 40, layer=hidden["id"], style=style(fill=rgba(1, 0, 0)))
    # Unknown fields are ignored.
    p.elements[1]["futureField"] = {"anything": [1, 2, 3]}
    p.elements[1]["style"]["futureStyle"] = 7
    write(EDGE / "shapes.dottie", [p], images={digest: {"data": b64, "format": "png"}},
          extra={"futureTopLevel": True})


def connectors():
    p = Page()
    a = p.add("rectangle", 40, 40, 120, 60, text="A")
    b = p.add("ellipse", 320, 160, 120, 70, text="B")
    c = p.add("diamond", 40, 280, 120, 90, text="C")
    d = p.add("rectangle", 560, 40, 120, 60, rotation=0.5, text="D")
    e = p.add("rectangle", 560, 300, 100, 60, text="E", style=style(roughness=0))
    # Edge-following, every routing.
    p.connect(a, b)
    p.connect(a, b, routing="curved", end_head="triangle")
    p.connect(a, b, routing="elbow", end_head="dot")
    p.connect(c, b, routing="curved", start_head="bar", end_head="arrow", text="label")
    p.connect(c, b, routing="elbow", start_head="dot", end_head="triangle", text="two\nlines")
    # Ports, all combinations of axis for elbows.
    p.connect(a, d, routing="elbow", start_port="right", end_port="left")
    p.connect(a, c, routing="elbow", start_port="bottom", end_port="top")
    p.connect(a, e, routing="elbow", start_port="bottom", end_port="left", text="v→h")
    p.connect(d, e, routing="elbow", start_port="right", end_port="top")
    p.connect(d, b, routing="curved", start_port="bottom")
    p.connect(b, e, routing="straight", end_port="left", end_head="none")
    # Rotated shape, edge-following.
    p.connect(b, d)
    # Free ends and a dangling binding.
    p.connect(None, a, free_start=(300, 20), end_head="bar")
    p.connect(None, None, routing="elbow", free_start=(200, 420), free_end=(420, 360), start_head="triangle")
    p.connect(None, None, routing="curved", free_start=(450, 420), free_end=(700, 440), text="free curve")
    p.connect(uid(), c, start_head="arrow")
    # Clean, dashed, thick.
    p.connect(c, e, routing="curved", st=style(roughness=0, dash="dashed"))
    p.connect(e, a, routing="straight", st=style(strokeWidth=4, dash="dotted"), start_head="dot")
    # Long labels wrap at 200 points, breaking after spaces, slashes and hyphens as CoreText does.
    g = p.add("rectangle", 760, 40, 80, 50)
    h = p.add("rectangle", 760, 420, 80, 50)
    p.connect(g, h, text="a label much too long to fit on one line, so it wraps onto several lines")
    p.connect(g, h, routing="elbow", start_port="right", end_port="right",
              text="GET https://api.example.com/v1/orders/12345/line-items?expand=true")
    p.connect(h, b, text="well-known state-of-the-art hyphenated-words-in-a-row")
    p.connect(g, d, text="Supercalifragilisticexpialidociousnessofthelabel")
    # Coincident shapes: zero-length route.
    f = p.add("rectangle", 300, 420, 40, 40)
    p.connect(f, f)
    write(EDGE / "connectors.dottie", [p])


def timeline():
    p = Page()
    box = p.add("rectangle", 40, 40, 100, 60, text="box", style=style(fill=rgba(1, 0.85, 0.4)))
    circ = p.add("ellipse", 300, 40, 80, 80, style=style(fill=rgba(0.6, 0.85, 1)))
    gone = p.add("diamond", 300, 220, 100, 80, text="gone")
    late = p.add("rectangle", 40, 220, 100, 60, text="late")
    keyed_line = p.connect(box, gone, routing="elbow")
    plain_line = p.connect(circ, gone)
    hidden_line = p.connect(box, late, routing="curved")
    title = p.add("text", 40, 340, 300, 40, text="Typing out a title")
    still = p.add("rectangle", 500, 40, 80, 60)
    live = p.add("ellipse", 500, 160, 60, 60)
    p.animate(4, fps=10, boil=2, settle=True, poster=2.5)
    p.track(box, [
        {"t": 2, "x": 200, "ease": "easeOut"},     # out of order on purpose
        {"t": 0, "x": 40, "ease": "easeIn"},
        {"t": 3, "x": 120, "ease": "hold"},
        {"t": 3.5, "x": 40},
        {"t": -1, "x": 999},                       # impossible times are dropped
        {"t": 5000, "x": 999},
        {"t": 0, "rotation": 0, "ease": "easeInOut"},
        {"t": 2, "rotation": 1.2},
        {"t": 1, "stroke": rgba(0.12, 0.12, 0.13), "fill": rgba(1, 0.85, 0.4), "strokeWidth": 2},
        {"t": 2.5, "stroke": rgba(0.8, 0.1, 0.1), "fill": rgba(0.2, 0.8, 0.3, 0.5), "strokeWidth": 6},
    ])
    p.track(circ, [
        {"t": 0, "width": 80, "height": 80, "opacity": 1, "ease": "linear"},
        {"t": 1.5, "width": 160, "height": 40, "opacity": 0.2},
        {"t": 3, "opacity": 1},
    ])
    # A second track for the same element: the first one wins.
    p.track(circ, [{"t": 0, "x": 0}, {"t": 4, "x": 600}])
    p.track(gone, [{"t": 1.2, "visible": False}, {"t": 2.6, "visible": True}])
    p.track(late, [{"t": 1, "visible": True, "reveal": 0, "ease": "easeInOut"}, {"t": 2, "reveal": 1}])
    p.track(keyed_line, [{"t": 0.5, "visible": True, "reveal": 0}, {"t": 1.5, "reveal": 1, "opacity": 1},
                         {"t": 3, "opacity": 0.3}])
    p.track(hidden_line, [], boil=False)
    p.track(title, [{"t": 0, "reveal": 0}, {"t": 2, "reveal": 1}])
    p.track(still, [], boil=True)
    p.track(live, [{"t": 0.3, "visible": True}, {"t": 3.7, "visible": False}])
    # A track for an element that doesn't exist is harmless.
    p.track(uid(), [{"t": 0, "x": 5}])

    # Repeats: counted, forever, and invalid ones that are dropped.
    q = Page(name="Repeats")
    pulse = q.add("ellipse", 40, 40, 60, 60, style=style(fill=rgba(0.95, 0.36, 0.33)))
    blink = q.add("rectangle", 200, 40, 60, 60)
    wig = q.add("rectangle", 360, 40, 80, 50)
    q.animate(6, fps=15, boil=3)
    q.track(pulse, [{"t": 0, "width": 60, "height": 60, "x": 40, "y": 40, "ease": "easeInOut"},
                    {"t": 0.5, "width": 80, "height": 80, "x": 30, "y": 30, "ease": "easeInOut"},
                    {"t": 1, "width": 60, "height": 60, "x": 40, "y": 40}],
            repeats=[{"start": 0, "end": 1}])
    q.track(blink, [{"t": 0.5, "visible": False}, {"t": 1, "visible": True}],
            repeats=[{"start": 0, "end": 1, "count": 3}, {"start": 2, "end": 2.0001}, {"start": -1, "end": 1},
                     {"start": 1, "end": 2, "count": 0}])
    q.track(wig, [{"t": 1, "rotation": 0, "ease": "easeInOut"}, {"t": 1.25, "rotation": 0.12, "ease": "easeInOut"},
                  {"t": 1.5, "rotation": -0.12, "ease": "easeInOut"}, {"t": 1.75, "rotation": 0}],
            repeats=[{"start": 1, "end": 1.75, "count": 2}, {"start": 4, "end": 4.5, "count": 2}])

    # Damaged numbers are clamped: fps, duration, boil; lowercase ids still match.
    r = Page(name="Damaged")
    low = uid(lower=True)
    r.add("rectangle", 40, 40, 80, 60, id=low)
    other = r.add("ellipse", 240, 40, 80, 60)
    r.connect(low.upper(), other)
    r.animate(-3, fps=0, boil=0)
    r.track(low, [{"t": 0, "x": 40}, {"t": 2, "x": 140}])
    s = Page(name="Fast")
    s.add("rectangle", 40, 40, 80, 60, id=uid())
    s.animate(1.234, fps=1000, boil=50000)
    s.track(s.elements[0]["id"], [{"t": 0, "y": 0}, {"t": 1.234, "y": 100}])
    write(EDGE / "timeline.dottie", [p, q, r, s])


def follow():
    p = Page()
    a = p.add("rectangle", 40, 40, 100, 60)
    b = p.add("rectangle", 400, 220, 100, 60)
    route = p.connect(a, b, routing="curved")
    elbow = p.connect(a, b, routing="elbow", start_port="bottom")
    ring = p.add("ellipse", 600, 40, 160, 100)
    box = p.add("rectangle", 600, 220, 160, 100, rotation=0.3)
    gem = p.add("diamond", 40, 300, 120, 100)
    star = p.add("path", 220, 320, 100, 100, subpaths=[{"closed": True, "coords": [
        0.5, 0, 0.5, 0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0, 1, 0.5, 0, 0.5, 0]}])
    clean_ring = p.add("ellipse", 820, 220, 100, 100, style=style(roughness=0))
    dots = [p.add("ellipse", 0, 0, 14, 14, style=style(fill=rgba(0.95, 0.36, 0.33))) for _ in range(9)]
    arrow = p.add("rectangle", 0, 0, 30, 12, style=style(fill=rgba(0.3, 0.5, 0.9)))
    p.animate(5, fps=12)
    p.track(dots[0], [{"t": 0.5, "visible": True}, {"t": 1.5, "visible": False}],
            follow=[{"path": route, "start": 0.5, "end": 1.5}])
    p.track(dots[1], [], follow=[{"path": elbow, "start": 0, "end": 2, "ease": "linear", "reverse": True}])
    p.track(dots[2], [], follow=[{"path": ring, "start": 0, "end": 4, "ease": "linear", "laps": 2.5}])
    p.track(arrow, [], follow=[{"path": box, "start": 0, "end": 4, "ease": "linear", "orient": True}])
    p.track(dots[3], [], follow=[{"path": gem, "start": 1, "end": 3, "ease": "easeIn", "orient": True, "reverse": True}])
    p.track(dots[4], [], follow=[{"path": star, "start": 0, "end": 2, "laps": 2}])
    p.track(dots[5], [], follow=[{"path": clean_ring, "start": 0, "end": 3, "ease": "linear"}])
    # Taken back by an x key after the span; a second span later.
    p.track(dots[6], [{"t": 3, "x": 40, "y": 450}],
            follow=[{"path": route, "start": 0, "end": 1}, {"path": elbow, "start": 3.5, "end": 4.5}])
    # Following itself, or a path that doesn't exist, does nothing.
    p.track(dots[7], [], follow=[{"path": dots[7], "start": 0, "end": 1}, {"path": uid(), "start": 1, "end": 2}])
    # A follow that repeats.
    p.track(dots[8], [], follow=[{"path": route, "start": 0, "end": 1, "ease": "linear"}],
            repeats=[{"start": 0, "end": 1.2}])
    # The path itself moves: the follower tracks it.
    p.track(b, [{"t": 0, "y": 220}, {"t": 4, "y": 120}])
    write(EDGE / "follow.dottie", [p])


def camera():
    p = Page()
    for i in range(4):
        p.add("rectangle", 40 + i * 220, 40 + (i % 2) * 140, 140, 80, text=f"Scene {i + 1}")
    p.animate(8, fps=12, markers=[{"t": 6, "name": "Last"}, {"t": 0, "name": "First"}, {"t": -2, "name": "Never"},
                                  {"t": 3, "name": "Middle"}])
    p.timeline["camera"] = [
        {"t": 5, "x": 400, "y": 0, "width": 400, "height": 300, "ease": "linear"},
        {"t": 0, "x": 0, "y": 0, "width": 300, "height": 200},
        {"t": 2, "x": 200, "y": 100, "width": 600, "height": 200, "ease": "easeIn"},   # wider: widened in height
        {"t": 3, "x": 0, "y": 0, "width": 0, "height": 200},                            # invalid: dropped
        {"t": 7, "x": 0, "y": 0, "width": 1000, "height": 300, "ease": "hold"},
    ]
    q = Page(name="No camera")
    box = q.add("rectangle", 40, 40, 100, 60)
    q.animate(2, fps=8)
    q.track(box, [{"t": 0, "x": -100, "visible": True}, {"t": 2, "x": 300}])
    write(EDGE / "camera.dottie", [p, q])


def themes():
    pages = []
    for theme in ["paper", "white", "sepia", "blueprint", "chalkboard", "midnight", "unknown-theme"]:
        p = Page(name=theme, theme=theme)
        a = p.add("rectangle", 40, 40, 120, 60, text="Auto ink")
        b = p.add("rectangle", 200, 40, 120, 60, text="Light fill", style=style(fill=rgba(1, 0.91, 0.52)))
        p.add("rectangle", 360, 40, 120, 60, text="Hatched", style=style(fill=rgba(1, 0.91, 0.52), fillStyle="hachure"))
        p.add("rectangle", 520, 40, 120, 60, text="Red ink", style=style(stroke=rgba(0.8, 0.1, 0.1)))
        p.add("note", 680, 30, 140, 90, text="A **note**", style=style(fill=rgba(1, 0.91, 0.52), strokeWidth=1, fontSize=16))
        p.connect(a, b, text="label")
        pages.append(p)
    write(EDGE / "themes.dottie", pages)


def dungeon():
    p = Page()
    floor = rgba(0.96, 0.93, 0.85)
    p.add("rectangle", 50, 50, 200, 150, style=style(fill=floor, fillStyle="grid"))
    p.add("rectangle", 250, 100, 150, 50, style=style(fill=floor, fillStyle="grid"))
    p.add("ellipse", 420, 40, 160, 160, style=style(fill=floor, fillStyle="grid", gridSize=25))
    p.add("rectangle", 100, 260, 150, 100, rotation=0.3, style=style(fill=floor, fillStyle="grid", roughness=0))
    p.add("diamond", 320, 240, 160, 140, style=style(fill=rgba(0.15, 0.25, 0.4), fillStyle="grid", gridSize=4))
    p.add("rectangle", 520, 260, 100, 100, style=style(fill=CLEAR, fillStyle="grid"))   # no fill: not a floor
    q = Page(name="Blueprint", theme="blueprint")
    q.add("rectangle", 50, 50, 200, 150, style=style(fill=rgba(0.15, 0.3, 0.5), fillStyle="grid"))
    write(EDGE / "dungeon.dottie", [p, q])


def transitions():
    """Every canned transition, written as the keys Dottie's `addTransition` writes (see Transitions.swift)."""
    p = Page()
    names = ["popIn", "growIn", "wipeIn", "dropIn", "slideIn", "drawIn", "fadeIn",
             "popOut", "shrinkOut", "wipeOut", "fadeOut", "pulse", "wiggle"]
    p.animate(4, fps=15)
    ids = []
    for i, n in enumerate(names):
        x, y = 40 + (i % 5) * 160, 120 + (i // 5) * 140
        ids.append(p.add("rectangle", x, y, 120, 70, text=n, style=style(fill=rgba(1, 0.85, 0.4))))
    for i, (n, e) in enumerate(zip(names, ids)):
        el = p.elements[i]
        fx, fy, fw, fh = el["x"], el["y"], el["width"], el["height"]
        t, d = 0.5, 1.0

        def scaled(at, s, ease=None, visible=None):
            k = {"t": at, "x": fx + fw / 2 - fw * s / 2, "y": fy + fh / 2 - fh * s / 2, "width": fw * s, "height": fh * s}
            if ease:
                k["ease"] = ease
            if visible is not None:
                k["visible"] = visible
            return k

        def wiped(at, s, ease=None, visible=None):
            k = {"t": at, "x": fx, "width": max(1, fw * s)}
            if ease:
                k["ease"] = ease
            if visible is not None:
                k["visible"] = visible
            return k
        keys = {
            "popIn": [scaled(t, 0.2, "easeOut", True), scaled(t + 0.6 * d, 1.15, "easeInOut"), scaled(t + d, 1)],
            "growIn": [scaled(t, 0.02, "easeOut", True), scaled(t + d, 1)],
            "wipeIn": [wiped(t, 0, "easeOut", True), wiped(t + d, 1)],
            "dropIn": [{"t": t, "y": fy - 140, "ease": "bounce", "visible": True}, {"t": t + d, "y": fy}],
            "slideIn": [{"t": t, "x": fx - 120, "ease": "easeOut", "visible": True}, {"t": t + d, "x": fx}],
            "drawIn": [{"t": t, "visible": True, "reveal": 0, "ease": "easeInOut"}, {"t": t + d, "reveal": 1}],
            "fadeIn": [{"t": t, "visible": True, "opacity": 0, "ease": "easeOut"}, {"t": t + d, "opacity": 1}],
            "popOut": [scaled(t, 1, "easeOut"), scaled(t + 0.35 * d, 1.15, "easeIn"), scaled(t + d, 0.2, visible=False)],
            "shrinkOut": [scaled(t, 1, "easeIn"), scaled(t + d, 0.02, visible=False)],
            "wipeOut": [wiped(t, 1, "easeIn"), wiped(t + d, 0, visible=False)],
            "fadeOut": [{"t": t, "opacity": 1, "ease": "easeIn"}, {"t": t + d, "visible": False, "opacity": 0}],
            "pulse": [scaled(t, 1, "easeInOut"), scaled(t + d / 2, 1.12, "easeInOut"), scaled(t + d, 1)],
            "wiggle": [{"t": t + d * f, "rotation": r, "ease": "easeInOut"} for f, r in
                       [(0, 0), (0.25, 0.12), (0.5, -0.12), (0.75, 0.06), (1, 0)]],
        }[n]
        p.track(e, keys)
    write(EDGE / "transitions.dottie", [p])


def eases():
    """The springy eases, which overshoot: colors, sizes and line widths are clamped, follows stop at the end."""
    p = Page()
    p.animate(2, fps=20)
    for i, ease in enumerate(["spring", "bounce", "elastic", "wobble"]):   # wobble: a name from the future, played linear
        e = p.add("rectangle", 40, 40 + i * 80, 60, 50, text=ease)
        p.track(e, [{"t": 0, "x": 40, "ease": ease}, {"t": 1.5, "x": 400}])
    tint = p.add("ellipse", 520, 40, 60, 60, style=style(fill=rgba(0.05, 0.9, 0.5)))
    p.track(tint, [{"t": 0, "fill": rgba(0.05, 0.9, 0.5), "stroke": rgba(0, 0, 0), "ease": "elastic"},
                   {"t": 1, "fill": rgba(0.95, 0.1, 0.5, 1), "stroke": rgba(1, 1, 1)}])
    shrink = p.add("rectangle", 520, 160, 80, 60)
    p.track(shrink, [{"t": 0, "width": 80, "height": 60, "strokeWidth": 4, "ease": "elastic"},
                     {"t": 1, "width": 2, "height": 2, "strokeWidth": 0.5}])
    ring = p.add("ellipse", 520, 260, 120, 120)
    dot = p.add("ellipse", 0, 0, 14, 14, style=style(fill=rgba(0.2, 0.2, 0.2)))
    p.track(dot, [], follow=[{"path": ring, "start": 0, "end": 1.5, "ease": "elastic"}])
    write(EDGE / "eases.dottie", [p])


def march():
    """Marching ants: dashes travel along lines, evened out to loop; a solid line shows nothing."""
    p = Page()
    p.animate(1.5, fps=10, boil=2)
    a = p.add("rectangle", 40, 40, 100, 60, text="a")
    b = p.add("rectangle", 360, 40, 100, 60, text="b")
    flow = p.connect(a, b, st=style(dash="dashed"))
    back = p.connect(a, b, routing="curved", start_port="bottom", end_port="bottom", st=style(dash="dotted", strokeWidth=3))
    solid = p.connect(b, a, routing="elbow", start_port="top", end_port="top")
    ring = p.add("ellipse", 520, 40, 100, 100, style=style(dash="dashed", roughness=0))
    widen = p.add("rectangle", 520, 180, 100, 60, style=style(dash="dashed"))
    p.track(flow, [], march=40)
    p.track(back, [], march=-25)
    p.track(solid, [], march=40)
    p.track(ring, [], march=1e9)                       # clamped
    p.track(widen, [{"t": 0, "strokeWidth": 2}, {"t": 1.5, "strokeWidth": 5}], march=30)
    p.add("rectangle", 40, 180, 100, 60, style=style(dash="dashed", dashOffset=7))   # a still offset
    write(EDGE / "march.dottie", [p])


def notes():
    """Sticky notes: the Markdown Dottie lays out, at two sizes, plus wrapping, overflow and alignment."""
    p = Page()
    texts = ["# H1\npara", "## H2\npara", "### H3\npara", "A\nB\nC", "para\n\npara2", "# H1\n## H2\n### H3",
             "**bold**\nplain", "plain\n**bold**", "x\n# H1", "- a\n- b\n\npara", "1. one\n2. two", "> quote\n> more",
             "```\ncode\nmore\n```\nafter", "---\nafter", "| a | b |\n|---|---|\n| 1 | 2 |\nafter",
             "- [ ] task\n- [x] done", "- a\n  - b\n    - c", "*it* ~~st~~ [ln](http://x)",
             "| left | mid | right |\n|:--|:-:|--:|\n| 1 | two | 3 |\n| four | 5 | six six |",
             "See https://example.com/path, or www.phin.tech now",
             "A very long paragraph that keeps on going well past the bottom edge of this small note so it is cut off "
             "at the edge rather than spilling out of the card, the way Dottie cuts it.",
             "Supercalifragilisticexpialidociousness overflows",
             "Arrows → and ← ✓ done… “quoted” — dash",
             "3. three\n4. four\n\n   continued",
             "> # Quoted heading\n> - item\n> \n> ```\n> code\n> ```",
             "Setext\n======\nbody\n\nSub\n---", "Line one  \nhard break\\\nback\\slash \\*not em\\*", "`` a ` b ``"]
    for i, t in enumerate(texts):
        for big in (True, False):
            fs = 16 if big else 13
            p.add("note", (i % 7) * 250, (i // 7) * 300 + (0 if big else 1200), 230, 280 if i != 20 else 90, text=t,
                  style=style(fill=rgba(1, 0.91, 0.52), strokeWidth=1, fontSize=fs, roughness=1 if big else 0))
    p.elements[3]["rotation"] = 0.2
    write(EDGE / "notes.dottie", [p])


def fonts():
    """Text in each bundled handwriting font (a shape's label, a text element, a connector's label and a note
    with bold, italic and code), a name in the wrong case, and a font nobody has, which draws as Helvetica Neue."""
    p = Page()
    note = "# Plan\nSome **bold**, *italic* and `code`.\n\n- [ ] arrows → ←\n- [x] “quotes” — dash"
    for i, font in enumerate(["Caveat", "Patrick Hand", "Architects Daughter", "caveat", "No Such Font"]):
        y = i * 260
        a = p.add("rectangle", 20, y, 180, 90, text=f"{font} label that wraps", style=style(font=font))
        b = p.add("ellipse", 360, y, 140, 90, text="Hi!", style=style(font=font, fontSize=24))
        p.connect(a, b, text=f"{font} edge", st=style(font=font, fontSize=14))
        p.add("text", 20, y + 110, 300, 40, text=f"Text in {font}: AVATAR, Wolf, 1234", style=style(font=font))
        p.add("note", 560, y, 260, 230, text=note,
              style=style(font=font, fill=rgba(1, 0.91, 0.52), strokeWidth=1, fontSize=16, roughness=0 if i % 2 else 1))
    write(EDGE / "fonts.dottie", [p])


def clicks():
    """Clickable elements for the web players: scenes by name (any case), links, hover looks, a link to another page,
    and clicks that must do nothing (a scene that isn't there, a javascript: link)."""
    p = Page("Overview")
    q = Page("Details")
    p.animate(3, fps=10)
    p.timeline["markers"] = [{"t": 0, "name": "Overview"}, {"t": 1, "name": "Login flow"}, {"t": 2, "name": "Done"}]
    auth = p.add("rectangle", 40, 40, 140, 60, text="Auth", click={"scene": "login FLOW"},
                 hover={"stroke": rgba(0.2, 0.4, 1), "fill": rgba(0.85, 0.9, 1)})
    docs = p.add("rectangle", 220, 40, 140, 60, text="Docs", click={"url": "https://example.com/docs"},
                 hover={"opacity": 0.6})
    p.add("ellipse", 400, 40, 80, 60, text="Back", anchor="back", click={"scene": "Overview"})
    p.add("rectangle", 40, 140, 140, 60, text="Nowhere", click={"scene": "No such scene"})
    p.add("rectangle", 220, 140, 140, 60, text="Script", click={"url": "javascript:alert(1)"})
    more = q.add("rectangle", 40, 40, 140, 60, text="More")
    p.add("diamond", 400, 140, 80, 60, text="Details", link=more)
    packet = p.add("ellipse", 60, 110, 16, 16, style=style(fill=rgba(1, 0.5, 0.2)))
    p.track(packet, [{"t": 0, "visible": False}, {"t": 1, "visible": True, "x": 60}, {"t": 2, "x": 300}])
    p.track(auth, [{"t": 1, "strokeWidth": 2}, {"t": 1.5, "strokeWidth": 4}, {"t": 2, "strokeWidth": 2}])
    write(EDGE / "clicks.dottie", [p, q])

    # Clicks that must never run script: as hostile.dottie, for the browser tests.
    h = Page()
    h.add("rectangle", 40, 40, 160, 60, text='" onfocus="window.__pwned=1', click={"url": "javascript:window.__pwned=1"})
    h.add("rectangle", 240, 40, 160, 60, text="mixed case", click={"url": " JavaScript:window.__pwned=1"})
    h.add("rectangle", 440, 40, 160, 60, text="data", click={"url": "data:text/html,<script>window.__pwned=1</script>"})
    write(JS_ONLY / "hostile-clicks.dottie", [h])


def links():
    """Links out of the drawing (`url`): web and mail addresses become <a> in SVG and clicks in the web players, faded
    and turned shapes keep their link around the whole element, a symbol's parts keep theirs, and links that must do
    nothing on the web (another drawing, a javascript: address) stay plain."""
    p = Page("Links")
    p.add("rectangle", 40, 40, 140, 60, text="Docs", url="https://example.com/docs?a=1&b=\"2\"")
    p.add("ellipse", 220, 40, 120, 60, text="Mail", url="mailto:team@example.com", rotation=0.3,
          style=style(opacity=0.6))
    p.add("rectangle", 380, 40, 140, 60, text="Next plan", url="plans/next.dottie#Login")
    p.add("rectangle", 40, 140, 140, 60, text="Script", url="javascript:alert(1)")
    p.add("diamond", 220, 140, 120, 60, text="Click wins", url="https://example.com/url",
          click={"url": "https://example.com/click"})
    p.add("rectangle", 380, 140, 140, 60, text="Section", anchor="Section")
    sp = Page("Badge")
    sp.add("rectangle", 0, 0, 100, 40, text="Help", url="https://example.com/help", style=style(roughness=0))
    badge = {"id": sp.id, "name": "Badge", "width": 100, "height": 40, "layers": sp.layers, "elements": sp.elements}
    p.extra = {"symbols": [badge]}
    p.add("symbol", 40, 240, 100, 40, symbol=badge["id"], style=style(roughness=0))
    write(EDGE / "links.dottie", [p])

    h = Page()
    h.add("rectangle", 40, 40, 160, 60, text="url", url="javascript:window.__pwned=1")
    h.add("rectangle", 240, 40, 160, 60, text="mixed", url=" JavaScript:window.__pwned=1")
    write(JS_ONLY / "hostile-links.dottie", [h])


def symbols():
    """Symbols: instances scaled, turned unevenly, offset, played once or held still, nested, faded, keyed on the
    page, boiled with it, and one naming a symbol that isn't there (it draws nothing); connectors inside a symbol
    and from the page to an instance."""
    p = Page()
    p.animate(3, fps=10, boil=2)

    def symbol(name, w, h, build, duration=None, **tl):
        sp = Page(name)
        build(sp)
        d = {"id": sp.id, "name": name, "width": w, "height": h, "layers": sp.layers, "elements": sp.elements}
        if sp.timeline is not None:
            d["timeline"] = sp.timeline
        return d

    def gear(sp):
        sp.animate(1.2, fps=10)
        a = sp.add("rectangle", 10, 10, 30, 20, style=style(fill=rgba(0.55, 0.75, 1)), text="g")
        b = sp.add("ellipse", 70, 30, 20, 20, style=style(roughness=0))
        sp.connect(a, b, routing="elbow", start_port="right", end_port="left")
        sp.track(a, [{"t": 0, "x": 10, "rotation": 0}, {"t": 1.2, "x": 50, "rotation": 1.5, "ease": "easeInOut"}])
        sp.track(b, [{"t": 0, "visible": False}, {"t": 0.6, "visible": True}])
    g = symbol("Gear", 100, 60, gear)

    def light(sp):
        sp.animate(0.8, fps=10)
        bulb = sp.add("ellipse", 0, 0, 40, 40, style=style(fill=rgba(1, 0.85, 0.2)))
        sp.track(bulb, [{"t": 0, "opacity": 1}, {"t": 0.4, "opacity": 0.2}, {"t": 0.8, "opacity": 1}])
        sp.add("symbol", 50, 0, 50, 30, symbol=g["id"], offset=0.3, style=style(roughness=0))
    l = symbol("Light", 100, 40, light)
    p.extra = {"symbols": [g, l]}

    base = p.add("rectangle", 20, 200, 80, 50, text="src")
    a = p.add("symbol", 40, 40, 100, 60, symbol=g["id"], style=style(roughness=0))
    p.add("symbol", 200, 40, 160, 40, symbol=g["id"], rotation=0.5, offset=0.5, style=style(roughness=0, opacity=0.6))
    p.add("symbol", 400, 40, 50, 30, symbol=g["id"], playback="once", style=style(roughness=0))
    p.add("symbol", 500, 40, 100, 60, symbol=g["id"], playback="still", style=style(roughness=0))
    moving = p.add("symbol", 40, 300, 200, 80, symbol=l["id"], style=style(roughness=0))
    p.add("symbol", 300, 300, 50, 50, symbol=uid(), style=style(roughness=0))
    p.connect(base, a)
    p.track(moving, [{"t": 0, "x": 40}, {"t": 3, "x": 300}])
    write(EDGE / "symbols.dottie", [p])

    # A symbol that contains itself, and ten levels of ten instances each: readers cut both short.
    h = Page()
    me = uid()
    loop = {"id": me, "name": "Loop", "width": 10, "height": 10, "layers": h.layers,
            "elements": [{"id": uid(), "kind": "rectangle", "x": 0, "y": 0, "width": 10, "height": 10, "style": style(),
                          "seed": 1, "layerID": h.layer},
                         {"id": uid(), "kind": "symbol", "symbol": me, "x": 0, "y": 0, "width": 10, "height": 10,
                          "style": style(), "seed": 2, "layerID": h.layer}]}
    chain, nxt = [], None
    for i in range(10):
        els = []
        for k in range(10):
            e = {"id": uid(), "kind": "symbol" if nxt else "rectangle", "x": k, "y": 0, "width": 1, "height": 1,
                 "style": style(), "seed": k + 1, "layerID": h.layer}
            if nxt:
                e["symbol"] = nxt
            els.append(e)
        s = {"id": uid(), "name": f"S{i}", "width": 10, "height": 10, "layers": h.layers, "elements": els}
        chain.append(s)
        nxt = s["id"]
    h.add("symbol", 0, 0, 10, 10, symbol=me)
    h.add("symbol", 50, 0, 100, 100, symbol=nxt)
    h.extra = {"symbols": [loop] + chain}
    write(JS_ONLY / "hostile-symbols.dottie", [h])


def buttons():
    """Button symbols: up, over and down looks, a small hit area, a button whose frame takes clicks (no hit scene), a
    clip that plays when clicked (<dottie-player> only), and a button with no action (not clickable)."""
    p = Page()
    p.animate(2, fps=10)
    p.timeline["markers"] = [{"t": 0, "name": "Start"}, {"t": 1, "name": "Next"}]

    def symbol(name, w, h, build, **extra):
        sp = Page(name)
        build(sp)
        d = {"id": sp.id, "name": name, "width": w, "height": h, "layers": sp.layers, "elements": sp.elements}
        if sp.timeline is not None:
            d["timeline"] = sp.timeline
        d.update(extra)
        return d

    def go(sp):
        sp.animate(1.5, fps=10)
        sp.timeline["markers"] = [{"t": 0, "name": "up"}, {"t": 0.5, "name": "Over"}, {"t": 1, "name": "down"}, {"t": 1.5, "name": "hit"}]
        box = sp.add("rectangle", 0, 0, 120, 40, text="Go", style=style(fill=rgba(0.85, 0.85, 0.85), roughness=0))
        spot = sp.add("ellipse", 50, 10, 20, 20, style=style(fill=rgba(0, 0, 0), roughness=0))
        sp.track(box, [{"t": 0, "fill": rgba(0.85, 0.85, 0.85), "ease": "hold", "visible": True}, {"t": 0.5, "fill": rgba(0.4, 0.6, 1), "ease": "hold"},
                       {"t": 1, "fill": rgba(0.1, 0.2, 0.6), "ease": "hold"}, {"t": 1.5, "visible": False}])
        sp.track(spot, [{"t": 0, "visible": False}, {"t": 1.5, "visible": True}])
    g = symbol("Go", 120, 40, go, button=True)

    def link(sp):
        sp.animate(1, fps=10)
        sp.timeline["markers"] = [{"t": 0.5, "name": "over"}]
        box = sp.add("ellipse", 0, 0, 100, 40, text="Docs", style=style(fill=rgba(1, 0.9, 0.6), roughness=0))
        sp.track(box, [{"t": 0, "strokeWidth": 2, "ease": "hold"}, {"t": 0.5, "strokeWidth": 5, "ease": "hold"}])
    l = symbol("Docs button", 100, 40, link, button=True)

    def spin(sp):
        sp.animate(1, fps=10)
        r = sp.add("rectangle", 10, 10, 40, 40, style=style(fill=rgba(0.95, 0.55, 0.1), fillStyle="hachure"))
        sp.track(r, [{"t": 0, "rotation": 0}, {"t": 1, "rotation": 3.14159}])
    c = symbol("Spinner", 60, 60, spin)
    p.extra = {"symbols": [g, l, c]}

    p.add("symbol", 40, 40, 120, 40, symbol=g["id"], click={"scene": "Next"}, playback="loop", offset=0.3, style=style(roughness=0))
    p.add("symbol", 200, 40, 100, 40, symbol=l["id"], rotation=0.2, click={"url": "https://example.com/docs"}, style=style(roughness=0))
    p.add("symbol", 340, 30, 60, 60, symbol=c["id"], playback="click", anchor="spinner", style=style(roughness=0))
    p.add("symbol", 40, 120, 120, 40, symbol=g["id"], style=style(roughness=0))
    dot = p.add("ellipse", 60, 200, 16, 16, style=style(fill=rgba(1, 0.4, 0.2)))
    p.track(dot, [{"t": 1, "x": 60}, {"t": 2, "x": 300}])
    write(EDGE / "buttons.dottie", [p])


def params():
    """Symbol parameters: copies of one toast with their own text, one with none (the defaults), one naming a param
    the symbol doesn't have (left as written), a value passed down into a nested copy, text that types out, and
    toasts that pop in at their own moment (once, with a negative offset)."""
    p = Page()
    p.animate(4, fps=10)

    def symbol(name, w, h, build, **extra):
        sp = Page(name)
        build(sp)
        d = {"id": sp.id, "name": name, "width": w, "height": h, "layers": sp.layers, "elements": sp.elements}
        if sp.timeline is not None:
            d["timeline"] = sp.timeline
        d.update(extra)
        return d

    def tag(sp):
        sp.add("rectangle", 0, 0, 80, 24, text="{{ who }}", style=style(fill=rgba(0.85, 0.95, 0.85), roughness=0))
    t = symbol("Tag", 80, 24, tag, params={"who": "nobody"})

    def toast(sp):
        sp.animate(1.5, fps=10)
        box = sp.add("rectangle", 0, 0, 200, 50, text="{{message}} ({{count}}) {{missing}}", style=style(fill=rgba(0.2, 0.2, 0.25)))
        note = sp.add("text", 10, 54, 180, 20, text="{{message}}!")
        sp.add("symbol", 110, 54, 80, 24, symbol=t["id"], args={"who": "by {{author}}"}, style=style(roughness=0))
        sp.track(box, [{"t": 0, "opacity": 0, "visible": True}, {"t": 0.3, "opacity": 1}, {"t": 1.2, "opacity": 1}, {"t": 1.5, "opacity": 0}])
        sp.track(note, [{"t": 0, "reveal": 0}, {"t": 1, "reveal": 1}])
    s = symbol("Toast", 200, 80, toast, params={"message": "Saved", "count": "1", "author": "me"})
    p.extra = {"symbols": [s, t]}

    p.add("symbol", 40, 40, 200, 80, symbol=s["id"], args={"message": "Upload failed", "count": "3", "author": "Sam"}, style=style(roughness=0))
    p.add("symbol", 280, 40, 200, 80, symbol=s["id"], style=style(roughness=0))
    p.add("symbol", 40, 160, 300, 120, symbol=s["id"], args={"message": "Later", "nope": "x"}, playback="once", offset=-1.5, rotation=0.1, style=style(roughness=0))
    p.add("symbol", 380, 160, 80, 24, symbol=t["id"], args={"who": "{{message}}"}, style=style(roughness=0))
    write(EDGE / "params.dottie", [p])


def js_only():
    p = Page()
    p.add("rectangle", 40, 40, 120, 60, text="known")
    p.add("hexagon", 200, 40, 120, 60, text="unknown kind")
    p.add("rectangle", 360, 40, 120, 60, style=style(fill=rgba(1, 0.85, 0.4), fillStyle="zigzag", dash="wavy"))
    write(JS_ONLY / "future.dottie", [p], version=99)

    # Hostile strings where they end up in the drawn SVG: none may become markup or script.
    h = Page()
    evil = 'x" onerror="window.__pwned=1" y="'
    h.add("image", 40, 40, 80, 60, image={"data": evil, "format": 'png" onload="window.__pwned=1'})
    h.add("image", 140, 40, 80, 60, image={"ref": "evil"})
    h.add("rectangle", 240, 40, 160, 60, text='<img src=x onerror="window.__pwned=1">')
    h.add("note", 40, 140, 200, 100, text='<script>window.__pwned=1</script> **<b onmouseover="window.__pwned=1">x</b>**')
    h.add('svg onload="window.__pwned=1"', 260, 140, 100, 60, text="</text><script>window.__pwned=1</script>")
    write(JS_ONLY / "hostile.dottie", [h], images={"evil": {"data": evil, "format": "png"}},
          extra={})


def extension_shapes():
    """Paths with an outline that isn't its box, ports and label rects (what extension shapes carry), and connectors
    to them: edge-following runs the outline, portIndex pins to a port. Shapes are written as Dottie stores them
    after an extension generates them, so this file opens without any extension installed."""
    def poly(corners):
        # Each edge is a cubic whose control points sit a third and two thirds along it: the edge is straight.
        coords = [corners[0][0], corners[0][1]]
        for i in range(len(corners)):
            (ax, ay), (bx, by) = corners[i], corners[(i + 1) % len(corners)]
            coords += [ax + (bx - ax) / 3, ay + (by - ay) / 3, ax + 2 * (bx - ax) / 3, ay + 2 * (by - ay) / 3, bx, by]
        return [{"closed": True, "coords": coords}]

    p = Page()
    tri = p.add("path", 360, 40, 160, 120, subpaths=poly([(0.5, 0), (1, 1), (0, 1)]), text="triangle",
                labelRect={"x": 0.25, "y": 0.5, "width": 0.5, "height": 0.4})
    p.elements[-1]["extension"] = {"id": "com.example.shapes", "shape": "triangle", "version": "1.0.0",
                                   "params": {"inset": 0.25}}
    rot = p.add("path", 40, 40, 120, 80, subpaths=poly([(0, 0), (1, 0.25), (1, 1), (0, 0.75)]), rotation=0.6, text="rotated")
    # A hexagon with a port on each of two opposite vertices and a label rect in its middle.
    hexa = p.add("path", 40, 260, 180, 120, subpaths=poly([(0.25, 0), (0.75, 0), (1, 0.5), (0.75, 1), (0.25, 1), (0, 0.5)]),
                 ports=[{"x": 0, "y": 0.5}, {"x": 1, "y": 0.5}], labelRect={"x": 0.2, "y": 0.3, "width": 0.6, "height": 0.4},
                 text="hex")
    p.elements[-1]["extension"] = {"id": "com.example.shapes", "shape": "hex", "version": "2.1.0",
                                   "params": {"sides": 6, "round": False}}
    box = p.add("rectangle", 360, 260, 120, 60, text="box")
    # Edge-following to the outlines, and pinned to a port.
    p.connect(box, tri)
    p.connect(rot, tri, routing="curved", end_head="triangle")
    p.connect(hexa, box, routing="elbow", start_head="dot")
    e1 = p.connect(hexa, tri, text="to the ports")
    p.elements[-1]["connector"]["start"]["portIndex"] = 1
    p.elements[-1]["connector"]["end"]["portIndex"] = 0
    p.connect(hexa, rot, routing="curved", start_head="bar", text="from port 0")
    p.elements[-1]["connector"]["start"]["portIndex"] = 0
    # A box with open lines across its inside, like a database's rims: connectors stop at the outside edge, not on
    # the first inside line the ray from its center meets.
    rims = poly([(0, 0), (1, 0), (1, 1), (0, 1)]) + [
        {"closed": False, "coords": [0, y, 1 / 3, y, 2 / 3, y, 1, y]} for y in (0.2, 0.6)]
    drum = p.add("path", 600, 220, 100, 160, subpaths=rims, text="rims")
    cache = p.add("rectangle", 600, 40, 100, 50, text="above")
    p.connect(cache, drum)
    p.connect(drum, box, routing="curved")
    write(EDGE / "extensions.dottie", [p])


def extension_tools():
    """What an extension's drawing tool leaves on the page: plain elements in their own looks. A calligraphy ribbon
    (a closed, smooth, solid-filled path with no stroke, like the template's Ribbon tool draws), its ink dot, and a
    box in its own stroke color and width. Nothing refers back to the extension, so the file draws without it."""
    import math
    # The ribbon's centre line, a wave, widened across a slanted nib and tapered at both ends.
    pts = [(20 + i * 10, 100 + 40 * math.sin(i / 3)) for i in range(31)]
    left, right = [], []
    for i, (x, y) in enumerate(pts):
        (ax, ay), (bx, by) = pts[max(0, i - 1)], pts[min(len(pts) - 1, i + 1)]
        ln = math.hypot(bx - ax, by - ay) or 1
        dx, dy = (bx - ax) / ln, (by - ay) / ln
        across = abs(math.sin(math.atan2(dy, dx) + math.pi / 4))
        half = 7 * (0.15 + 0.85 * across) * (0.2 + 0.8 * min(1, i / 3, (len(pts) - 1 - i) / 3))
        left.append((x - dy * half, y + dx * half))
        right.append((x + dy * half, y - dx * half))
    loop = left + right[::-1]
    xs, ys = [q[0] for q in loop], [q[1] for q in loop]
    fx, fy, fw, fh = min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)
    norm = [((qx - fx) / fw, (qy - fy) / fh) for qx, qy in loop]
    n = len(norm)
    coords = list(norm[0])
    for i in range(n):  # Catmull-Rom through the outline, closed
        p0, p1, p2, p3 = norm[(i - 1) % n], norm[i], norm[(i + 1) % n], norm[(i + 2) % n]
        coords += [p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6,
                   p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6, p2[0], p2[1]]
    ink = rgba(0.184, 0.31, 0.847)
    page = Page()
    page.add("path", round(fx, 2), round(fy, 2), round(fw, 2), round(fh, 2),
             style=style(stroke=CLEAR, fill=ink, roughness=0), subpaths=[{"closed": True, "coords": [round(c, 4) for c in coords]}])
    page.add("ellipse", 340, 150, 7, 7, style=style(stroke=CLEAR, fill=ink, roughness=0))
    page.add("rectangle", 380, 60, 160, 90, style=style(stroke=rgba(1, 0, 0), strokeWidth=4), text="boxed")
    write(EDGE / "extension-tools.dottie", [page])


def waypoints():
    """Bends dragged into connectors, for every routing, and hops where a line crosses the ones beneath it."""
    p = Page(layers=2)
    a = p.add("rectangle", 40, 40, 100, 60, text="A")
    b = p.add("ellipse", 420, 60, 100, 60, text="B")
    c = p.add("rectangle", 40, 300, 100, 60, text="C")
    d = p.add("diamond", 420, 300, 120, 80, text="D")
    # Edge-following ends aim at the nearest bend; the label sits halfway along the bent line.
    p.connect(a, b, waypoints=[(200, 10), (330, 10)], text="over")
    p.connect(a, d, routing="curved", waypoints=[(120, 200), (300, 180), (380, 260)], end_head="triangle")
    # Elbows: bends out of line get corners; a pinned port decides the last leg; bends in line fall away.
    p.connect(c, b, routing="elbow", waypoints=[(250, 250), (330, 140)], start_head="dot")
    p.connect(c, d, routing="elbow", start_port="bottom", end_port="bottom", waypoints=[(90, 420), (480, 420)],
              st=style(roughness=0))
    p.connect(None, None, routing="elbow", free_start=(600, 40), free_end=(700, 200),
              waypoints=[(650, 40), (680, 40), (680, 120)], st=style(roughness=0))
    p.connect(None, None, routing="curved", free_start=(600, 260), free_end=(740, 400), waypoints=[(700, 250)])
    # Hops: over the lines beneath, not too near a bend, not over a hidden layer's line or one drawn above.
    h1 = p.connect(None, None, free_start=(40, 520), free_end=(760, 520), st=style(roughness=0))
    p.connect(None, None, routing="curved", free_start=(40, 600), free_end=(760, 560))
    p.connect(None, None, free_start=(40, 640), free_end=(760, 640), layer=p.layers[1]["id"])
    p.layers[1]["visible"] = False
    p.connect(None, None, routing="elbow", free_start=(120, 460), free_end=(300, 700),
              waypoints=[(120, 580), (300, 580)], hops=True, st=style(roughness=0, strokeWidth=3))
    p.connect(None, None, free_start=(400, 460), free_end=(560, 700), hops=True)
    p.connect(None, None, free_start=(600, 460), free_end=(600, 700), hops=True, end_head="triangle")
    p.connect(None, None, free_start=(700, 470), free_end=(720, 700), hops=False)
    p.connect(None, None, routing="curved", free_start=(650, 460), free_end=(760, 700), hops=True)  # a curve hops too
    p.connect(None, None, free_start=(40, 515), free_end=(160, 515), hops=True)  # nothing beneath it crosses
    # A curve hopping a curve beneath it, sketchy and clean, and one with bends hopping twice.
    p.connect(None, None, routing="curved", free_start=(40, 760), free_end=(400, 720))
    p.connect(None, None, routing="curved", free_start=(160, 860), free_end=(260, 680), hops=True)
    p.connect(None, None, routing="curved", free_start=(300, 860), free_end=(360, 680), hops=True, st=style(roughness=0))
    p.connect(None, None, routing="curved", free_start=(440, 700), free_end=(760, 860),
              waypoints=[(520, 860), (680, 690)], hops=True)
    write(EDGE / "waypoints.dottie", [p])

    # A connector with bends inside a symbol: the bends scale and turn with each copy.
    q = Page()
    sp = Page("Bent")
    x = sp.add("rectangle", 0, 0, 30, 20)
    y = sp.add("rectangle", 70, 60, 30, 20)
    sp.connect(x, y, routing="elbow", waypoints=[(50, 10), (50, 70)])
    sp.connect(None, None, free_start=(0, 60), free_end=(100, 0), waypoints=[(20, 0)])
    bent = {"id": sp.id, "name": "Bent", "width": 100, "height": 80, "layers": sp.layers, "elements": sp.elements}
    q.extra = {"symbols": [bent]}
    q.add("symbol", 40, 40, 100, 80, symbol=bent["id"], style=style(roughness=0))
    q.add("symbol", 220, 40, 200, 120, symbol=bent["id"], rotation=0.6, style=style(roughness=0))
    write(EDGE / "waypoints-symbol.dottie", [q])


def main():
    shapes()
    connectors()
    timeline()
    follow()
    camera()
    themes()
    dungeon()
    transitions()
    notes()
    js_only()
    eases()
    march()
    clicks()
    symbols()
    buttons()
    params()
    extension_shapes()
    links()
    extension_tools()
    fonts()
    waypoints()
    print("wrote", ", ".join(sorted(p.name for p in [*EDGE.glob("*.dottie"), *JS_ONLY.glob("*.dottie")])))


if __name__ == "__main__":
    sys.exit(main())
