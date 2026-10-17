#!/usr/bin/env python3
"""Regenerates the animations made by script: the README's (Design/animation.*) and the feature demos
(Design/demos/*), with a copy of each drawing in website/docs/drawings, which the GitHub Pages site plays with
<dottie-player> (web/). Each script runs on a new page through dottie-mcp, and the dottie tool renders the
result. Run through `just readme-animation` or `just demos`, which build both tools first.

    scripts/make-demos.py readme        the README animation: .dottie, .gif, .mp4, drawings/build.dottie, compiled/build.js
    scripts/make-demos.py demos         every scripts/demos/*.js: .dottie, .gif, drawings/<name>.dottie, compiled/<name>.js
    scripts/make-demos.py live tour     just those demos

A demo can have a second page: scripts/demos/<name>.after.js draws a page called "After" first, for the demo's
script (on page 1) to animate into, as Magic Move does.
"""
import json, pathlib, shutil, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
bin_dir = root / ".build" / "debug"
drawings = root / "website" / "docs" / "drawings"
compiled = root / "website" / "docs" / "compiled"
examples = root / "website" / "docs" / "examples"
# Demos also shown as File > Export Animation's web page, which needs nothing but itself.
EXPORTED = {"flows"}


def run_script(script: pathlib.Path, page: pathlib.Path, after=None) -> None:
    """Runs `script` on a new page saved at `page`, through dottie-mcp over stdio; with `after`, that script
    first draws a second page, "After"."""
    mcp = subprocess.Popen([str(bin_dir / "dottie-mcp")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    next_id = 0

    def call(method, params=None, notify=False):
        nonlocal next_id
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if not notify:
            next_id += 1
            message["id"] = next_id
        mcp.stdin.write(json.dumps(message) + "\n")
        mcp.stdin.flush()
        if notify:
            return None
        while True:
            reply = json.loads(mcp.stdout.readline())
            if reply.get("id") == next_id:
                return reply

    def tool(tool_name, **arguments):
        result = call("tools/call", {"name": tool_name, "arguments": arguments})["result"]
        text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        if result.get("isError"):
            sys.exit(f"{script.name}: {tool_name} failed: {text}")
        return text

    try:
        call("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                            "clientInfo": {"name": "make-demos", "version": "1"}})
        call("notifications/initialized", notify=True)
        page.parent.mkdir(parents=True, exist_ok=True)
        tool("create_diagram", path=str(page), overwrite=True)
        if after is not None:
            tool("add_page", path=str(page), name="After")
            tool("run_script", path=str(page), page="After", code=after.read_text())
        print(f"{script.name}: {tool('run_script', path=str(page), code=script.read_text()).splitlines()[-1]}")
    finally:
        mcp.terminate()


def render(page: pathlib.Path, out: pathlib.Path, scale: str) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(bin_dir / "dottie"), "render", str(page), "-o", str(out), "-s", scale], check=True)


def publish(page: pathlib.Path, name: str) -> None:
    """Puts a copy of the drawing on the Pages site, which plays it live, and the drawing compiled into one
    script (`dottie render -f js`) for the dottie.js page; for the demos in EXPORTED, the web page export too."""
    drawings.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(page, drawings / f"{name}.dottie")
    render(page, compiled / f"{name}.js", "1")
    if name in EXPORTED:
        render(page, examples / f"{name}.html", "1")


def readme() -> None:
    page = root / "Design" / "animation.dottie"
    run_script(root / "scripts" / "readme-animation.js", page)
    render(page, page.with_suffix(".gif"), "1")
    render(page, page.with_suffix(".mp4"), "2")
    publish(page, "build")
    # And as Lottie, which the dottie.js page plays with lottie-web.
    render(page, root / "website" / "docs" / "lottie" / "build.json", "1")


def demo(name: str) -> None:
    script = root / "scripts" / "demos" / f"{name}.js"
    if not script.exists():
        sys.exit(f"no demo called {name} (scripts/demos/{name}.js)")
    page = root / "Design" / "demos" / f"{name}.dottie"
    after = script.with_name(f"{name}.after.js")
    run_script(script, page, after if after.exists() else None)
    render(page, page.with_suffix(".gif"), "1")
    publish(page, name)


targets = sys.argv[1:] or ["readme", "demos"]
for target in targets:
    if target == "readme":
        readme()
    elif target == "demos":
        for script in sorted((root / "scripts" / "demos").glob("*.js")):
            if not script.stem.endswith(".after"):
                demo(script.stem)
    else:
        demo(target)
