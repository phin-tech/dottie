"""`dottie-release <lane>`: what the release recipes in the justfile run. Every lane takes --dry-run, which runs
the checks and reads but only prints what it would change."""

from __future__ import annotations

import os
import sys
from pathlib import Path

from cyclopts import App

from . import lanes
from .dsl import Release, ReleaseError, console
from .version import Part

app = App(name="dottie-release", help="Bump, build, notarize and publish Dottie.")


def _release(dry_run: bool) -> Release:
    # scripts/release/dottie_release/cli.py -> the repository; DOTTIE_ROOT overrides it (tests, other checkouts).
    root = Path(os.environ.get("DOTTIE_ROOT") or Path(__file__).resolve().parents[3])
    return Release(root, dry_run=dry_run)


@app.command
def bump(part: Part, /, *, dry_run: bool = False) -> None:
    """Bump the version everywhere and the build number. beta: the next beta (0.6.1 -> 0.7.0-beta.1 -> -beta.2);
    major, minor, patch: the next release (from a beta, the release it was a beta of)."""
    lanes.bump(_release(dry_run), part)


@app.command
def notarize(*, dry_run: bool = False) -> None:
    """Build, sign with Developer ID, notarize and staple Dottie.app headless; prints the app's path."""
    print(lanes.notarize(_release(dry_run)))


@app.command
def release(app_path: Path | None = None, /, *, dry_run: bool = False) -> None:
    """Publish a notarized Dottie.app (default: the newest one Xcode notarized) as a GitHub release, then its appcast
    and, unless it is a beta, the Homebrew cask."""
    lanes.release(_release(dry_run), app_path)


@app.command
def appcast(version: str | None = None, /, *, dry_run: bool = False) -> None:
    """Make and upload the Sparkle appcast for a published release (default: the version in project.yml)."""
    lanes.appcast(_release(dry_run), version)


@app.command
def tap(version: str | None = None, /, *, dry_run: bool = False) -> None:
    """Point the Homebrew cask at a published release (default: the version in project.yml); never a beta."""
    lanes.tap(_release(dry_run), version)


@app.command
def ship(part: Part, /, *, dry_run: bool = False) -> None:
    """The whole release: bump, commit, push, stage dottie.js on npm, notarize, publish. `ship beta` ships a beta."""
    lanes.ship(_release(dry_run), part)


def main() -> None:
    try:
        app()
    except ReleaseError as e:
        console.print(f"[red]release: {e}[/red]")
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
