#!/usr/bin/env python3
"""Regenerates fixtures/goldens: what Dottie says every fixture resolves to, for dottie.js to be tested against.

1. Copies the Design/ drawings and demos into fixtures/design, so the corpus is self-contained.
2. `dottie inspect` on every fixture -> fixtures/goldens/<group>/<name>.json (the geometry contract).
3. `dottie render -f svg` of every page at a few moments, clean and as drawn ->
   fixtures/goldens/svg/<group>/<name>-p<page>-t<time>-<clean|sketchy>.svg (the visual reference).
4. `dottie render -f html` of a few edge fixtures -> fixtures/goldens/html/<name>.html (the exported player, for
   the browser tests).

Run with `just goldens`, which builds the dottie tool first. Pass --check to fail instead of writing when
anything would change (what CI runs on a Mac).
"""
import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / "fixtures"
GROUPS = ["design", "edge"]


def dottie_bin():
    out = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, check=True, capture_output=True, text=True)
    return Path(out.stdout.strip()) / "dottie"


def svg_times(page):
    """A few moments per page: the middle of things and the poster for an animation, 0 for a still."""
    if "duration" not in page:
        return [0]
    d = page["duration"]
    times = {round(d * 0.37, 4), round(d * 0.71, 4), page["poster"]}
    times.update(m["t"] for m in page.get("markers", [])[:2])
    return sorted(t for t in times if 0 <= t <= d)


def stamp(t):
    return f"{t:.4f}".rstrip("0").rstrip(".") if t else "0"


def generate(out, dottie):
    design = out / "design"
    design.mkdir(parents=True, exist_ok=True)
    for src in [*sorted((ROOT / "Design").glob("*.dottie")), *sorted((ROOT / "Design" / "demos").glob("*.dottie"))]:
        shutil.copyfile(src, design / src.name)
    for group in GROUPS:
        for f in sorted((out / group).glob("*.dottie")):
            inspected = subprocess.run([dottie, "inspect", f], check=True, capture_output=True, text=True).stdout
            target = out / "goldens" / group / (f.stem + ".json")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(inspected)
            for page in json.loads(inspected)["pages"]:
                for t in svg_times(page):
                    for look in ["clean", "sketchy"]:
                        svg = out / "goldens" / "svg" / group / f"{f.stem}-p{page['page']}-t{stamp(t)}-{look}.svg"
                        svg.parent.mkdir(parents=True, exist_ok=True)
                        cmd = [dottie, "render", f, "-f", "svg", "-p", str(page["page"]), "--at", str(t), "-o", svg]
                        if look == "clean":
                            cmd.append("--clean")
                        subprocess.run(cmd, check=True, capture_output=True)
    # The HTML export's own player, for the browser tests of clicking (they run where Dottie can't).
    html = out / "goldens" / "html"
    html.mkdir(parents=True, exist_ok=True)
    for name in ["clicks", "links", "symbols", "buttons"]:
        subprocess.run([dottie, "render", out / "edge" / f"{name}.dottie", "-f", "html", "-o", html / f"{name}.html"],
                       check=True, capture_output=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if the committed goldens are stale")
    args = ap.parse_args()
    dottie = dottie_bin()
    if not args.check:
        shutil.rmtree(FIX / "goldens", ignore_errors=True)
        generate(FIX, dottie)
        print("wrote", FIX / "goldens")
        return 0
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        shutil.copytree(FIX / "edge", tmp / "edge")
        generate(tmp, dottie)
        diff = subprocess.run(["diff", "-rq", "--exclude=js-only", tmp / "design", FIX / "design"], capture_output=True, text=True)
        diff2 = subprocess.run(["diff", "-rq", tmp / "goldens", FIX / "goldens"], capture_output=True, text=True)
        if diff.returncode or diff2.returncode:
            sys.stderr.write(diff.stdout + diff2.stdout)
            sys.stderr.write("The goldens are stale: run `just goldens` and commit fixtures/.\n")
            return 1
    print("goldens are up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
