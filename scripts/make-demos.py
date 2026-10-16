#!/usr/bin/env python3
"""Regenerates the animations made by script: the README's (Design/animation.*) and the feature demos
(Design/demos/*), with a web player for each in website/docs/players for the GitHub Pages site. Each script
runs on a new page through dottie-mcp, and the dottie tool renders the result. Run through
`just readme-animation` or `just demos`, which build both tools first.

    scripts/make-demos.py readme        the README animation: .dottie, .gif, .mp4, and players/build.html
    scripts/make-demos.py demos         every scripts/demos/*.js: .dottie, .gif and players/<name>.html
    scripts/make-demos.py live tour     just those demos
"""
import json, pathlib, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
bin_dir = root / ".build" / "debug"
players = root / "website" / "docs" / "players"


def run_script(script: pathlib.Path, page: pathlib.Path) -> None:
    """Runs `script` on a new page saved at `page`, through dottie-mcp over stdio."""
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

    def tool(name, **arguments):
        result = call("tools/call", {"name": name, "arguments": arguments})["result"]
        text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        if result.get("isError"):
            sys.exit(f"{script.name}: {name} failed: {text}")
        return text

    try:
        call("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                            "clientInfo": {"name": "make-demos", "version": "1"}})
        call("notifications/initialized", notify=True)
        page.parent.mkdir(parents=True, exist_ok=True)
        tool("create_diagram", path=str(page), overwrite=True)
        print(f"{script.name}: {tool('run_script', path=str(page), code=script.read_text()).splitlines()[-1]}")
    finally:
        mcp.terminate()


def render(page: pathlib.Path, out: pathlib.Path, scale: str) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(bin_dir / "dottie"), "render", str(page), "-o", str(out), "-s", scale], check=True)


def readme() -> None:
    page = root / "Design" / "animation.dottie"
    run_script(root / "scripts" / "readme-animation.js", page)
    render(page, page.with_suffix(".gif"), "1")
    render(page, page.with_suffix(".mp4"), "2")
    render(page, players / "build.html", "1")


def demo(name: str) -> None:
    script = root / "scripts" / "demos" / f"{name}.js"
    if not script.exists():
        sys.exit(f"no demo called {name} (scripts/demos/{name}.js)")
    page = root / "Design" / "demos" / f"{name}.dottie"
    run_script(script, page)
    render(page, page.with_suffix(".gif"), "1")
    render(page, players / f"{name}.html", "1")


targets = sys.argv[1:] or ["readme", "demos"]
for target in targets:
    if target == "readme":
        readme()
    elif target == "demos":
        for script in sorted((root / "scripts" / "demos").glob("*.js")):
            demo(script.stem)
    else:
        demo(target)
