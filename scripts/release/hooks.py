"""Dottie's own release steps, which app-release runs around its lanes (release.toml names this file): dottie.js goes
out on npm at the app's version, and the player embedded for `dottie render -f js` is rebuilt from it. SKIP_NPM=1 leaves
npm out of a release."""

import os

from app_release.dsl import fail, tool
from app_release.lanes import op_read

_staged = False


def check(r, cfg):
    # Before anything is bumped or pushed.
    if not os.environ.get("SKIP_NPM") and not op_read(r, cfg, "npm_token"):
        fail(f"npm_token in {cfg.op_item} is empty; fill it in, or set SKIP_NPM=1")


def bumped(r, cfg, version):
    # npm owns package.json and the lockfile; the embedded player is rebuilt from the new dottie.js.
    web = r.path("web")
    r.run(tool("npm")["version", str(version), "--no-git-tag-version", "--allow-same-version"], cwd=web, quiet=True)
    r.run(tool("npm")["ci", "--silent"], cwd=web)
    r.run(tool("npm")["run", "build", "--silent"], cwd=web, quiet=True)
    r.run(tool(r.path("scripts", "update-player-script.py")))


def pushed(r, cfg, version):
    # The token is stage-only: `npm stage publish` uploads the version, and it goes live when it is approved with 2FA
    # (npmjs.com, the package's staged versions, or `npm stage approve <id>`). The release does not wait for that.
    global _staged
    if os.environ.get("SKIP_NPM"):
        return
    with r.step(f"Staging dottie.js {version} on npm"):
        token = op_read(r, cfg, "npm_token")
        tag = ["--tag", "beta"] if version.prerelease else []  # `npm install dottie` stays on the release
        r.run(tool("npm")["stage", "publish", *tag], cwd=r.path("web"),
              env={"npm_config_//registry.npmjs.org/:_authToken": token})
        _staged = True


def released(r, cfg, version):
    if _staged:
        r.say(f"dottie.js {version} is staged on npm, not live yet: approve it at npmjs.com (the package's staged "
              "versions) or run `npm stage list` then `npm stage approve <id>`.")
