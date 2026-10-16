#!/usr/bin/env python3
"""Drives a Debug build of Dottie over its live socket, for looking at the real app without screen-recording
or accessibility permissions. `dottie-debug.py help` lists the commands; `just debug-app` launches a Debug
build on its own socket so it doesn't take over the one your everyday Dottie uses.

    scripts/dottie-debug.py state
    scripts/dottie-debug.py --wait 0.5 snapshot /tmp/dottie.png
"""
import json, os, socket, sys, time

DEFAULT = os.path.expanduser("~/Library/Application Support/Dottie/debug.sock")


def main(argv):
    wait = None
    sock_path = os.environ.get("DOTTIE_LIVE_SOCKET", DEFAULT)
    while argv and argv[0].startswith("--"):
        flag = argv.pop(0)
        if flag == "--wait": wait = float(argv.pop(0))
        elif flag == "--socket": sock_path = argv.pop(0)
        else: sys.exit(f"unknown flag {flag}")
    request = {"op": "debug", "args": argv}
    if wait: request["wait"] = wait
    # A just-launched app takes a moment to open its socket, so keep trying for a little while.
    deadline = time.monotonic() + 10
    while True:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(60)
        try:
            s.connect(sock_path)
            break
        except OSError as e:
            s.close()
            if time.monotonic() > deadline:
                sys.exit(f"can't reach Dottie at {sock_path} ({e}); start it with `just debug-app`")
            time.sleep(0.25)
    s.sendall(json.dumps(request).encode() + b"\n")
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk: break
        data += chunk
    reply = json.loads(data or b"{}")
    if reply.get("error"): sys.exit(reply["error"])
    print(reply.get("text", ""))


if __name__ == "__main__":
    main(sys.argv[1:])
