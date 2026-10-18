"""Dottie's release lanes. Each takes a `Release` (see dsl) and can be run alone from `just`:

    bump      next version in every file (bump-my-version), build number, dottie.js and its embedded player
    notarize  archive, Developer ID export, notarize and staple, headless; returns the app
    release   publish a notarized app as a GitHub release (a pre-release for a beta), then appcast and cask
    appcast   Sparkle's appcast for a published release, made by Sparkle's generate_appcast
    tap       point the Homebrew cask at a published release (releases only, never betas)
    ship      all of it: bump, commit, push, stage dottie.js on npm, notarize, release

Settings come from the environment, so a build machine can run them unattended: NOTARY_OP_ITEM (the 1Password item;
`op` also works with a service account's OP_SERVICE_ACCOUNT_TOKEN), DEVELOPMENT_TEAM, NOTARY_PROFILE (a notarytool
keychain profile, used when 1Password can't be read) and SKIP_NPM.
"""

from __future__ import annotations

import hashlib
import html
import os
import plistlib
import shutil
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

from semver import Version

from . import version as versions
from .dsl import Release, ReleaseError, fail, tool
from .version import Part

REPO = "phin-tech/dottie"
TAP = "phin-tech/homebrew-tap"
BUNDLE_ID = "tech.phin.dottie"
SPARKLE_VERSION = "2.10.0"  # matches the Sparkle package in project.yml
SPARKLE_SHA256 = "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def op_item() -> str:
    return os.environ.get("NOTARY_OP_ITEM", "op://Development/Mac App Release")


def team() -> str:
    return os.environ.get("DEVELOPMENT_TEAM", "J35P7AJDN7")


def op_read(r: Release, name: str) -> str:
    """A field of the release item in 1Password, registered as a secret."""
    return r.secret(r.read(tool("op")["read", f"{op_item()}/{name}"]))


# MARK: Version


def bump(r: Release, part: Part) -> Version:
    current, build = versions.read(r.root)
    new = versions.bumped(current, part)
    with r.step(f"Bumping {current} -> {new} (build {build + 1})"):
        r.run(tool("bump-my-version")["replace", "--current-version", str(current), "--new-version", str(new)])
        project = r.path("project.yml")
        r.write(project, versions.with_build(project.read_text(), build + 1))
        # dottie.js goes out at the app's version: npm owns package.json and the lockfile, and the player embedded
        # for `dottie render -f js` is rebuilt from it.
        web = r.path("web")
        r.run(tool("npm")["version", str(new), "--no-git-tag-version", "--allow-same-version"], cwd=web, quiet=True)
        r.run(tool("npm")["ci", "--silent"], cwd=web)
        r.run(tool("npm")["run", "build", "--silent"], cwd=web, quiet=True)
        r.run(tool(r.path("scripts", "update-player-script.py")))
        if shutil.which("xcodegen"):
            r.run(tool("xcodegen")["generate", "--quiet"])
    return new


# MARK: Build


def notarize(r: Release) -> Path:
    """Builds a Developer ID signed, notarized, stapled Dottie.app from this checkout: what Xcode's Archive ▸
    Distribute App ▸ Direct Distribution does by hand. Credentials: the Apple ID, team and app-specific password in
    the 1Password item (apple_id, team_id, app_specific_password), else the notarytool keychain profile
    NOTARY_PROFILE (default dottie-notary), made with
    `xcrun notarytool store-credentials dottie-notary --apple-id <you> --team-id J35P7AJDN7`."""
    version, build = versions.read(r.root)
    xcrun, team_id = tool("xcrun"), team()
    identities = r.read(tool("security")["find-identity", "-v", "-p", "codesigning"])
    if not any("Developer ID Application" in line and f"({team_id})" in line for line in identities.splitlines()):
        fail(f"no Developer ID Application certificate for team {team_id} in the keychain")

    auth: list[str]
    try:
        apple_id, password = op_read(r, "apple_id"), op_read(r, "app_specific_password")
        team_id = op_read(r, "team_id") or team_id
        # notarytool takes the password only as an argument: it is masked in what's printed, but shows in `ps`.
        auth = ["--apple-id", apple_id, "--team-id", team_id, "--password", password]
        r.say(f"Notarizing as {apple_id} (credentials from 1Password).")
    except ReleaseError:
        profile = os.environ.get("NOTARY_PROFILE", "dottie-notary")
        auth = ["--keychain-profile", profile]
        if not r.ok(xcrun["notarytool", "history", *auth]):
            fail(f"no 1Password item at {op_item()} (is `op` signed in?) and no notarytool profile '{profile}'")

    out = r.path("build", "release", str(version))
    app = out / "export" / "Dottie.app"
    with r.step(f"Archiving Dottie {version} ({build})"):
        r.run(tool("rm")["-rf", out])
        r.run(tool("mkdir")["-p", out])
        r.run(tool("xcodegen")["generate", "--quiet", "--use-cache"])
        r.run(tool("xcodebuild")["archive", "-project", "Dottie.xcodeproj", "-scheme", "Dottie",
                                 "-configuration", "Release", "-destination", "generic/platform=macOS",
                                 "-archivePath", out / "Dottie.xcarchive", f"DEVELOPMENT_TEAM={team_id}",
                                 "-allowProvisioningUpdates", "-quiet"])
        options = out / "ExportOptions.plist"
        r.write(options, plistlib.dumps({"method": "developer-id", "teamID": team_id, "signingStyle": "automatic"}).decode())
        r.run(tool("xcodebuild")["-exportArchive", "-archivePath", out / "Dottie.xcarchive", "-exportPath", out / "export",
                                 "-exportOptionsPlist", options, "-allowProvisioningUpdates", "-quiet"])
    if r.dry_run:
        return app
    if not app.is_dir():
        fail("the export produced no Dottie.app")

    with r.step("Notarizing (usually a few minutes)"):
        submit = out / "submit.zip"
        r.run(tool("ditto")["-c", "-k", "--sequesterRsrc", "--keepParent", app, submit])
        result = r.run(xcrun["notarytool", "submit", submit, *auth, "--wait", "--output-format", "plist"],
                       quiet=True, check=False)
        try:
            report = plistlib.loads(result.stdout.encode())
        except Exception:
            report = {}
        if report.get("status") != "Accepted":
            if report.get("id"):
                r.say(r.read(xcrun["notarytool", "log", report["id"], *auth]))
            fail(f"notarization {report.get('status', 'failed')}" + (f": {result.stderr.strip()}" if result.stderr else ""))
        r.run(xcrun["stapler", "staple", app], quiet=True)
        r.run(xcrun["stapler", "validate", app], quiet=True)
        submit.unlink(missing_ok=True)
    r.say("Notarized and stapled.")
    return app


# MARK: Publish


def newest_xcode_export() -> Path:
    """The newest app Xcode notarized: after Distribute App ▸ Direct Distribution, the Organizer keeps that copy in
    <archive>.xcarchive/Submissions/<id>/Dottie.app."""
    archives = Path.home() / "Library/Developer/Xcode/Archives"
    apps = sorted(archives.glob("*/*.xcarchive/Submissions/*/Dottie.app"), key=lambda p: p.stat().st_mtime)
    if not apps:
        fail(f"no notarized Dottie.app under {archives}; archive, then Distribute App ▸ Direct Distribution")
    return apps[-1]


def require_pushed_main(r: Release) -> None:
    """The tag goes on the commit the app was built from, so that commit must be main, clean and pushed."""
    git = tool("git")
    if r.read(git["branch", "--show-current"]) != "main":
        fail("not on main")
    if not (r.ok(git["diff", "--quiet"]) and r.ok(git["diff", "--cached", "--quiet"])):
        fail("there are uncommitted changes")
    r.read(git["fetch", "--quiet", "origin", "main"])
    if r.read(git["rev-parse", "HEAD"]) != r.read(git["rev-parse", "origin/main"]):
        fail("main is not the same as origin/main; push or pull first")


def release(r: Release, app: Path | None = None) -> None:
    """Publishes a notarized, stapled Dottie.app as a GitHub release tagged v<version> at the commit on main, then its
    appcast and, for a release (not a beta), the Homebrew cask."""
    app = (app or newest_xcode_export()).resolve()
    r.say(f"Using {app}")
    if app.name != "Dottie.app" or not app.is_dir():
        fail(f"{app} is not a Dottie.app")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        fail(f"{app} is not Dottie (bundle id)")
    if "CFBundleShortVersionString" not in info:
        fail(f"{app} has no version; it was archived before MARKETING_VERSION was set, so archive again")
    version, build = versions.parse(info["CFBundleShortVersionString"]), info.get("CFBundleVersion", "?")
    tag = f"v{version}"

    with r.step(f"Checking Dottie {version} ({build})"):
        # What people will run: a valid signature, Developer ID, notarized, with the ticket stapled for offline launch.
        r.read(tool("codesign")["--verify", "--deep", "--strict", app])
        assessment = r.read(tool("spctl")["--assess", "--type", "execute", "-vv", app], stderr=True)
        if "source=Notarized Developer ID" not in assessment:
            fail(f"not a notarized Developer ID app: {assessment}")
        if not r.ok(tool("xcrun")["stapler", "validate", app]):
            fail("no notarization ticket is stapled")
        require_pushed_main(r)
        project, _ = versions.read(r.root)
        if project != version:
            fail(f"the app is {version} but project.yml is {project}; archive again from this commit")
        if r.ok(tool("gh")["release", "view", tag, "--repo", REPO]):
            fail(f"release {tag} already exists; bump the version")

    work = Path(tempfile.mkdtemp())
    try:
        zip_path = work / f"Dottie-{version}.zip"
        # ditto keeps the bundle's symlinks, permissions and signature intact, unlike zip.
        r.read(tool("ditto")["-c", "-k", "--sequesterRsrc", "--keepParent", app, zip_path])
        sha = hashlib.sha256(zip_path.read_bytes()).hexdigest()
        # Notes come from release-notes/<version>.md when there is one, else from the commits since the last release.
        notes = r.path("release-notes", f"{version}.md")
        flags = ["--notes-file", notes] if notes.exists() else ["--generate-notes"]
        if versions.is_beta(version):
            # A pre-release never becomes GitHub's "latest": the download link, the cask and copies that haven't
            # opted in to betas stay on the last release.
            flags.append("--prerelease")
        head = r.read(tool("git")["rev-parse", "HEAD"])
        with r.step(f"Publishing {tag}"):
            r.run(tool("gh")["release", "create", tag, zip_path, "--repo", REPO, "--target", head,
                             "--title", f"Dottie {version}", *flags], quiet=True)
            r.say(f"Released {tag} (build {build}): Dottie-{version}.zip, sha256 {sha}")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if r.dry_run:
        r.say(f"[dim]would then make the appcast{'' if versions.is_beta(version) else ' and update the cask'}[/dim]")
        return
    appcast(r, str(version))
    if versions.is_beta(version):
        r.say("Beta: the Homebrew cask stays on the last release.")
    else:
        tap(r, str(version))


# MARK: Appcast


def sparkle_tools(r: Release) -> Path:
    """The directory holding Sparkle's command-line tools, downloading the pinned release on first use."""
    folder = r.path("build", "sparkle", SPARKLE_VERSION)
    if not (folder / "bin" / "generate_appcast").exists():
        shutil.rmtree(folder, ignore_errors=True)
        folder.mkdir(parents=True)
        archive = folder / f"Sparkle-{SPARKLE_VERSION}.tar.xz"
        r.read(tool("gh")["release", "download", SPARKLE_VERSION, "--repo", "sparkle-project/Sparkle",
                          "--pattern", archive.name, "--dir", folder])
        if hashlib.sha256(archive.read_bytes()).hexdigest() != SPARKLE_SHA256:
            shutil.rmtree(folder, ignore_errors=True)
            fail(f"checksum mismatch for {archive.name}")
        r.read(tool("tar")["-xf", archive, "-C", folder])
    return folder / "bin"


def without_betas(appcast_xml: str) -> str:
    """An appcast with its beta entries taken out, so a new beta replaces the last one rather than piling up."""
    ET.register_namespace("sparkle", SPARKLE_NS)
    root = ET.fromstring(appcast_xml)
    for channel in root.iter("channel"):
        for item in list(channel.findall("item")):
            if item.find(f"{{{SPARKLE_NS}}}channel") is not None:
                channel.remove(item)
    return ET.tostring(root, encoding="unicode", xml_declaration=True)


def appcast(r: Release, version: str | None = None) -> str:
    """Makes the Sparkle appcast for a published release with Sparkle's generate_appcast and uploads it as appcast.xml.
    The app's feed is releases/latest/download/appcast.xml: the newest release that isn't a pre-release.
      - A release's appcast lists just that release.
      - A beta is added to the latest release's appcast in Sparkle's `beta` channel, which only copies that opted in
        take (replacing an earlier beta), and uploaded there and to the beta's own release.
    Each entry is signed with the EdDSA key in 1Password (sparkle_private_key), given on stdin, never written down."""
    v = versions.parse(version) if version else versions.read(r.root)[0]
    tag, beta = f"v{v}", versions.is_beta(v)
    gh = tool("gh")
    bin_dir = sparkle_tools(r)
    work = Path(tempfile.mkdtemp())
    try:
        targets = [tag]
        if beta:
            stable = r.read(gh["api", f"repos/{REPO}/releases/latest", "-q", ".tag_name"])
            r.read(gh["release", "download", stable, "--repo", REPO, "--pattern", "appcast.xml", "--dir", work])
            feed = work / "appcast.xml"
            feed.write_text(without_betas(feed.read_text()))
            targets.insert(0, stable)

        zip_name = f"Dottie-{v}.zip"
        r.read(gh["release", "download", tag, "--repo", REPO, "--pattern", zip_name, "--dir", work])
        with zipfile.ZipFile(work / zip_name) as z:
            info = plistlib.loads(z.read("Dottie.app/Contents/Info.plist"))
        if info.get("CFBundleShortVersionString") != str(v):
            fail(f"{zip_name} is not Dottie {v}")

        # The release notes as GitHub renders them, next to the zip, for --embed-release-notes.
        body = r.read(gh["release", "view", tag, "--repo", REPO, "--json", "body", "-q", ".body"])
        try:
            notes = r.read(gh["api", "markdown", "-f", f"text={body}", "-f", "mode=gfm", "-f", f"context={REPO}"])
        except ReleaseError:
            notes = f"<pre>{html.escape(body)}</pre>"
        (work / f"Dottie-{v}.html").write_text(notes)

        key = op_read(r, "sparkle_private_key")
        r.read(tool(bin_dir / "generate_appcast")[
            "--ed-key-file", "-", "--embed-release-notes", "--link", f"https://github.com/{REPO}",
            "--download-url-prefix", f"https://github.com/{REPO}/releases/download/{tag}/",
            *(["--channel", "beta"] if beta else []), work], input=key)
        xml = (work / "appcast.xml").read_text()
        check_appcast(r, xml, v, beta, bin_dir, work / zip_name, key)

        if r.dry_run:
            print(xml)
            r.say(f"[dim]would upload appcast.xml to {', '.join(targets)}[/dim]")
        else:
            for t in targets:
                r.run(gh["release", "upload", t, work / "appcast.xml", "--repo", REPO, "--clobber"], quiet=True)
            r.say(f"Appcast for {v} uploaded to {', '.join(targets)}.")
        return xml
    finally:
        shutil.rmtree(work, ignore_errors=True)


def check_appcast(r: Release, xml: str, v: Version, beta: bool, bin_dir: Path, zip_path: Path, key: str) -> None:
    """generate_appcast quietly leaves an entry unsigned when the key doesn't match the app's SUPublicEDKey, and
    installed copies would refuse that update, so every entry must be signed and the new one must verify."""
    root = ET.fromstring(xml)
    items = root.findall("./channel/item")
    new = [i for i in items if i.findtext(f"{{{SPARKLE_NS}}}shortVersionString") == str(v)
           or i.findtext("title") == str(v)]
    if len(new) != 1:
        fail(f"the appcast has {len(new)} entries for {v}")
    if (new[0].findtext(f"{{{SPARKLE_NS}}}channel") == "beta") != beta:
        fail(f"{v}'s entry is {'not ' if beta else ''}in the beta channel")
    for item in items:
        enclosure = item.find("enclosure")
        if enclosure is None or not enclosure.get(f"{{{SPARKLE_NS}}}edSignature"):
            fail(f"the appcast entry for {item.findtext('title')} is unsigned: does the key in 1Password match "
                 "SUPublicEDKey in project.yml?")
    signature = new[0].find("enclosure").get(f"{{{SPARKLE_NS}}}edSignature")
    if not r.ok(tool(bin_dir / "sign_update")["--verify", "--ed-key-file", "-", zip_path, signature], input=key):
        fail(f"the signature for {zip_path.name} does not verify")


# MARK: Homebrew

CASK = """\
cask "dottie" do
  version "{version}"
  sha256 "{sha}"

  url "https://github.com/phin-tech/dottie/releases/download/v#{{version}}/Dottie-#{{version}}.zip"
  name "Dottie"
  desc "Hand-drawn style diagrams that AI agents can draw over MCP"
  homepage "https://github.com/phin-tech/dottie"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Dottie updates itself (Sparkle), so brew upgrade leaves it alone unless given --greedy.
  auto_updates true
  depends_on macos: :sonoma

  app "Dottie.app"
  binary "#{{appdir}}/Dottie.app/Contents/Helpers/dottie-cli", target: "dottie"

  zap trash: [
    "~/Library/Application Support/Dottie",
    "~/Library/Preferences/tech.phin.dottie.plist",
    "~/Library/Saved Application State/tech.phin.dottie.savedState",
  ]
end
"""


def tap(r: Release, version: str | None = None) -> None:
    """Points the Homebrew cask in phin-tech/homebrew-tap at a published release. The sha256 comes from the asset as
    GitHub serves it, which is what brew will check. Betas never go in the cask."""
    v = versions.parse(version) if version else versions.read(r.root)[0]
    if versions.is_beta(v):
        fail(f"{v} is a beta; the cask only follows releases")
    gh, git = tool("gh"), tool("git")
    work = Path(tempfile.mkdtemp())
    try:
        asset = f"Dottie-{v}.zip"
        r.read(gh["release", "download", f"v{v}", "--repo", REPO, "--pattern", asset, "--dir", work])
        sha = hashlib.sha256((work / asset).read_bytes()).hexdigest()
        checkout = work / "tap"
        r.read(gh["repo", "clone", TAP, checkout, "--", "--quiet"])
        cask = checkout / "Casks" / "dottie.rb"
        cask.parent.mkdir(parents=True, exist_ok=True)
        cask.write_text(CASK.format(version=v, sha=sha))
        if not r.read(git["status", "--porcelain"], cwd=checkout):
            r.say(f"The tap already has Dottie {v}.")
            return
        with r.step(f"Updating the cask to {v}"):
            r.run(git["add", "Casks/dottie.rb"], cwd=checkout)
            r.run(git["commit", "--quiet", "-m", f"dottie v{v}"], cwd=checkout)
            r.run(git["pull", "--quiet", "--rebase"], cwd=checkout)
            r.run(git["push", "--quiet"], cwd=checkout)
        r.say(f"Tap updated: brew install --cask phin-tech/tap/dottie installs Dottie {v}.")
    finally:
        shutil.rmtree(work, ignore_errors=True)


# MARK: Ship


def ship(r: Release, part: Part) -> None:
    """The whole release: bump, commit, push, stage dottie.js on npm, build and notarize, then publish. `beta` ships
    the next beta: a GitHub pre-release in the appcast's beta channel, on npm under the `beta` tag, not in the cask.
    Write release-notes/<next version>.md first for curated notes."""
    git = tool("git")
    with r.step("Checking"):
        if r.read(git["branch", "--show-current"]) != "main":
            fail("not on main")
        if not (r.ok(git["diff", "--quiet"]) and r.ok(git["diff", "--cached", "--quiet"])):
            fail("there are uncommitted changes")
        r.read(git["fetch", "--quiet", "origin", "main"])
        if r.read(git["rev-parse", "HEAD"]) != r.read(git["rev-parse", "origin/main"]):
            fail("main is not the same as origin/main")
        # Fail now, before anything is bumped or pushed, if 1Password can't be read.
        op_read(r, "apple_id")
        if not os.environ.get("SKIP_NPM") and not op_read(r, "npm_token"):
            fail(f"npm_token in {op_item()} is empty; fill it in, or set SKIP_NPM=1")

    new = bump(r, part)
    with r.step(f"Committing Dottie {new}"):
        r.run(git["add", "-A"])
        r.run(git["commit", "--quiet", "-m", f"Dottie {new}"])
        r.run(git["push", "--quiet", "origin", "main"])

    # The token is stage-only: `npm stage publish` uploads the version, and it goes live when it is approved with 2FA
    # (npmjs.com, the package's staged versions, or `npm stage approve <id>`). The release does not wait for that.
    staged = False
    if not os.environ.get("SKIP_NPM"):
        with r.step(f"Staging dottie.js {new} on npm"):
            token = op_read(r, "npm_token")
            tag = ["--tag", "beta"] if versions.is_beta(new) else []  # `npm install dottie` stays on the release
            r.run(tool("npm")["stage", "publish", *tag], cwd=r.path("web"),
                  env={"npm_config_//registry.npmjs.org/:_authToken": token})
            staged = True

    if r.dry_run:
        r.say("[dim]would then notarize the app and publish it (just notarize, just release)[/dim]")
        return
    release(r, notarize(r))
    if staged:
        r.say(f"dottie.js {new} is staged on npm, not live yet: approve it at npmjs.com (the package's staged "
              "versions) or run `npm stage list` then `npm stage approve <id>`.")
