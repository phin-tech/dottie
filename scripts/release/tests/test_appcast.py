"""The appcast lane against a fake GitHub and 1Password, with Sparkle's real generate_appcast and sign_update (from
build/sparkle, which `just appcast` downloads) and throwaway signing keys."""

import base64
import os
import plistlib
import shutil
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

import nacl.signing
import pytest

from dottie_release import lanes
from dottie_release.dsl import Release, ReleaseError, Result, plumbum_runner

REPO_ROOT = Path(__file__).resolve().parents[3]
TOOLS = REPO_ROOT / "build" / "sparkle" / lanes.SPARKLE_VERSION
NS = {"sparkle": lanes.SPARKLE_NS}

pytestmark = pytest.mark.skipif(not (TOOLS / "bin" / "generate_appcast").exists(),
                                reason="Sparkle's tools aren't in build/sparkle; run `just appcast --dry-run` once")


def keypair() -> tuple[str, str]:
    signing = nacl.signing.SigningKey.generate()
    return base64.b64encode(bytes(signing)).decode(), base64.b64encode(bytes(signing.verify_key)).decode()


def app_zip(folder: Path, version: str, build: int, public_key: str) -> Path:
    app = folder / "stage" / "Dottie.app" / "Contents"
    (app / "MacOS").mkdir(parents=True)
    (app / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "tech.phin.dottie", "CFBundleShortVersionString": version, "CFBundleVersion": str(build),
        "CFBundleExecutable": "Dottie", "LSMinimumSystemVersion": "14.0", "SUPublicEDKey": public_key}))
    (app / "MacOS" / "Dottie").write_text("#!/bin/sh\n")
    out = folder / f"Dottie-{version}.zip"
    subprocess.run(["ditto", "-c", "-k", "--keepParent", app.parent, out], check=True)
    shutil.rmtree(folder / "stage")
    return out


class FakeGitHub:
    """Releases with zips and uploaded appcasts; `latest` is the newest release that isn't a beta."""

    def __init__(self, tmp: Path, private_key: str):
        self.tmp, self.key = tmp, private_key
        self.zips: dict[str, Path] = {}
        self.appcasts: dict[str, str] = {}

    def add(self, version: str, build: int, public_key: str) -> None:
        folder = self.tmp / "releases" / version
        folder.mkdir(parents=True)
        self.zips[f"v{version}"] = app_zip(folder, version, build, public_key)

    def __call__(self, i) -> Result:
        name, args = Path(i.argv[0]).name, i.argv[1:]
        if name in ("generate_appcast", "sign_update"):
            return plumbum_runner(i)
        if name == "op":
            assert args == ["read", f"{lanes.op_item()}/sparkle_private_key"]
            return Result(0, self.key + "\n")
        assert name == "gh", i.argv
        match args:
            case ["api", path, "-q", ".tag_name"] if path.endswith("/releases/latest"):
                return Result(0, max((t for t in self.zips if "-beta" not in t), key=lambda t: t) + "\n")
            case ["release", "download", tag, "--repo", _, "--pattern", pattern, "--dir", folder]:
                if pattern == "appcast.xml":
                    Path(folder, pattern).write_text(self.appcasts[tag])
                else:
                    shutil.copy(self.zips[tag], Path(folder, pattern))
                return Result(0)
            case ["release", "view", tag, *_]:
                return Result(0, f"Notes for {tag}\n")
            case ["api", "markdown", *_]:
                return Result(0, "<p>Notes</p>\n")
            case ["release", "upload", tag, path, *_]:
                self.appcasts[tag] = Path(path).read_text()
                return Result(0)
        raise AssertionError(f"unexpected gh {args}")


@pytest.fixture
def setup(tmp_path):
    (tmp_path / "build" / "sparkle").mkdir(parents=True)
    os.symlink(TOOLS, tmp_path / "build" / "sparkle" / lanes.SPARKLE_VERSION)
    private, public = keypair()
    github = FakeGitHub(tmp_path, private)
    return Release(tmp_path, runner=github), github, public


def entries(xml: str) -> list[tuple[str, str | None, bool]]:
    """(version, channel, signed) per appcast entry."""
    root = ET.fromstring(xml)
    return sorted((i.findtext("sparkle:shortVersionString", namespaces=NS) or i.findtext("title"),
                   i.findtext("sparkle:channel", namespaces=NS),
                   bool(i.find("enclosure").get(f"{{{lanes.SPARKLE_NS}}}edSignature")))
                  for i in root.findall("./channel/item"))


def test_a_release_lists_itself_and_a_beta_joins_the_release_in_its_channel(setup):
    r, github, public = setup
    github.add("0.6.0", 13, public)
    lanes.appcast(r, "0.6.0")
    assert entries(github.appcasts["v0.6.0"]) == [("0.6.0", None, True)]

    github.add("0.7.0-beta.1", 14, public)
    lanes.appcast(r, "0.7.0-beta.1")
    expected = [("0.6.0", None, True), ("0.7.0-beta.1", "beta", True)]
    assert entries(github.appcasts["v0.6.0"]) == expected  # the feed installed copies read
    assert entries(github.appcasts["v0.7.0-beta.1"]) == expected

    github.add("0.7.0-beta.2", 15, public)
    lanes.appcast(r, "0.7.0-beta.2")
    assert entries(github.appcasts["v0.6.0"]) == [("0.6.0", None, True), ("0.7.0-beta.2", "beta", True)]

    github.add("0.7.0", 16, public)
    lanes.appcast(r, "0.7.0")
    assert entries(github.appcasts["v0.7.0"]) == [("0.7.0", None, True)]


def test_a_key_that_does_not_match_the_app_stops_before_uploading(setup):
    r, github, _ = setup
    github.add("0.6.0", 13, keypair()[1])  # built with some other key
    with pytest.raises(ReleaseError, match="unsigned"):
        lanes.appcast(r, "0.6.0")
    assert github.appcasts == {}


def test_a_dry_run_prints_the_appcast_and_uploads_nothing(setup, capsys):
    r, github, public = setup
    github.add("0.6.0", 13, public)
    r.dry_run = True
    lanes.appcast(r, "0.6.0")
    assert "<sparkle:version>13</sparkle:version>" in capsys.readouterr().out
    assert github.appcasts == {}


def test_the_cask_never_follows_a_beta(tmp_path):
    with pytest.raises(ReleaseError, match="beta"):
        lanes.tap(Release(tmp_path, runner=lambda i: Result(0)), "0.7.0-beta.1")
