#!/usr/bin/env python3
"""Regenerates the README's animation: runs scripts/readme-animation.js on a new page through dottie-mcp,
then renders Design/animation.gif and Design/animation.mp4 with the dottie tool, keeping the source as
Design/animation.dottie. Run it through `just readme-animation`, which builds both tools first.
"""
import json, pathlib, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
bin_dir = root / ".build" / "debug"
design = root / "Design"
source = design / "animation.dottie"
script = (root / "scripts" / "readme-animation.js").read_text()

mcp = subprocess.Popen([str(bin_dir / "dottie-mcp")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
next_id = 0


def call(method, params=None, notify=False):
    global next_id
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
        sys.exit(f"{name} failed: {text}")
    return text


try:
    call("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                        "clientInfo": {"name": "make-readme-animation", "version": "1"}})
    call("notifications/initialized", notify=True)
    tool("create_diagram", path=str(source), overwrite=True)
    print(tool("run_script", path=str(source), code=script))
finally:
    mcp.terminate()

for out, scale in [("animation.gif", "1"), ("animation.mp4", "2")]:
    subprocess.run([str(bin_dir / "dottie"), "render", str(source), "-o", str(design / out), "-s", scale], check=True)
