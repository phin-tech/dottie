"""Dottie's version: MARKETING_VERSION in project.yml is the one source (bump-my-version writes it and its copies;
see .bumpversion.toml), CURRENT_PROJECT_VERSION is the build number Sparkle compares, which only ever goes up.

Betas are `X.Y.Z-beta.N`. How each kind of bump moves a version:
    beta    from a release, the first beta of the next minor (0.6.1 -> 0.7.0-beta.1); from a beta, the next beta
    patch   0.6.1 -> 0.6.2; from a beta, the release it was a beta of (0.7.0-beta.2 -> 0.7.0)
    minor   0.6.1 -> 0.7.0; from a beta, its release if that is a minor step or less, else the next minor
    major   0.6.1 -> 1.0.0; from a beta, its release if that is a major step, else the next major
That is how semver (and npm) bump a pre-release.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Literal

from semver import Version

from .dsl import fail

Part = Literal["major", "minor", "patch", "beta"]

_MARKETING = re.compile(r'^(\s*MARKETING_VERSION: )"(.*)"$', re.M)
_BUILD = re.compile(r'^(\s*CURRENT_PROJECT_VERSION: )"(.*)"$', re.M)
_BETA = re.compile(r"beta\.(\d+)")


def parse(text: str) -> Version:
    """A Dottie version: X.Y.Z or X.Y.Z-beta.N."""
    try:
        v = Version.parse(text)
    except ValueError:
        fail(f"not a version: {text!r}")
    if v.build or (v.prerelease and not _BETA.fullmatch(v.prerelease)):
        fail(f"not a Dottie version (X.Y.Z or X.Y.Z-beta.N): {text!r}")
    return v


def is_beta(v: Version | str) -> bool:
    return (parse(v) if isinstance(v, str) else v).prerelease is not None


def bumped(v: Version, part: Part) -> Version:
    if not is_beta(v):
        match part:
            case "beta":
                return v.bump_minor().bump_prerelease("beta")
            case "major":
                return v.bump_major()
            case "minor":
                return v.bump_minor()
            case "patch":
                return v.bump_patch()
    release = v.finalize_version()
    match part:
        case "beta":
            return v.bump_prerelease("beta")
        case "patch":
            return release
        case "minor":
            return release if v.patch == 0 else v.bump_minor()
        case "major":
            return release if v.minor == 0 and v.patch == 0 else v.bump_major()


def read(root: Path) -> tuple[Version, int]:
    """The version and build number in project.yml."""
    text = (root / "project.yml").read_text()
    marketing, build = _MARKETING.search(text), _BUILD.search(text)
    if not (marketing and build and build.group(2).isdigit()):
        fail("cannot read MARKETING_VERSION and CURRENT_PROJECT_VERSION from project.yml")
    return parse(marketing.group(2)), int(build.group(2))


def with_build(project_yml: str, build: int) -> str:
    """project.yml's text with the build number replaced."""
    return _BUILD.sub(lambda m: f'{m.group(1)}"{build}"', project_yml, count=1)
