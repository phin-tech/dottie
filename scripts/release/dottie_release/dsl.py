"""The small language release lanes are written in: plumbum commands, run through a `Release` that knows which
commands only look and which change something, keeps secrets out of what it prints, and can rehearse a lane.

    gh, xcrun = tool("gh"), tool("xcrun")
    with r.step("Publishing v0.7.0"):
        if r.ok(gh["release", "view", "v0.7.0"]):     # only looks: always runs; did it succeed?
            fail("v0.7.0 is already released")        # stops the lane with that message
        notes = r.read(gh["release", "view", ...])    # only looks: always runs, returns its output
        r.run(gh["release", "create", "v0.7.0", zip]) # changes something: a dry run prints it instead
        r.write(path, text)                           # a file edit: a dry run says which file instead
    password = r.secret(r.read(op["read", item]))     # from now on shown as *** wherever a command is printed
    r.run(tool(sign_update)["--ed-key-file", "-", zip], input=key)   # secrets go in on stdin where a tool allows it

Commands run from the repository root unless given `cwd`, inherit the environment plus `env`, and raise
`ReleaseError` when they fail. Tests swap `runner` for a fake, so lanes can be checked without touching GitHub.
"""

from __future__ import annotations

from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import NoReturn

from plumbum import CommandNotFound, local
from plumbum.commands.base import BaseCommand
from rich.console import Console

# Results (a path, an appcast) go to stdout; everything a person reads goes to stderr.
console = Console(stderr=True, highlight=False)


class ReleaseError(Exception):
    """A lane stopped: the message says why and, where it can, what to do."""


def fail(message: str) -> NoReturn:
    raise ReleaseError(message)


def tool(name: str | Path) -> BaseCommand:
    """A command by name (looked up on PATH) or by path."""
    try:
        return local[str(name)]
    except CommandNotFound:
        fail(f"{name} is not installed")


@dataclass
class Invocation:
    """One command as a runner gets it."""

    cmd: BaseCommand
    argv: list[str]
    cwd: Path
    env: dict[str, str]
    input: str | None
    capture: bool


@dataclass
class Result:
    returncode: int
    stdout: str = ""
    stderr: str = ""


Runner = Callable[[Invocation], Result]


def plumbum_runner(i: Invocation) -> Result:
    cmd = i.cmd << i.input if i.input is not None else i.cmd
    with local.cwd(i.cwd), local.env(**i.env):
        if i.capture:
            code, out, err = cmd.run(retcode=None)
        else:  # stream to the terminal
            code, out, err = cmd.run(retcode=None, stdout=None, stderr=None)
    return Result(code, out or "", err or "")


@dataclass
class Release:
    root: Path
    dry_run: bool = False
    runner: Runner = plumbum_runner
    _secrets: list[str] = field(default_factory=list, repr=False)
    _depth: int = field(default=0, repr=False)

    # Steps and messages

    @contextmanager
    def step(self, title: str) -> Iterator[None]:
        console.print(f"{'  ' * self._depth}[bold]›[/bold] {self.mask(title)}")
        self._depth += 1
        try:
            yield
        finally:
            self._depth -= 1

    def say(self, message: str) -> None:
        console.print(f"{'  ' * self._depth}{self.mask(message)}")

    # Secrets

    def secret(self, value: str) -> str:
        """Registers `value` as a secret and returns it: printed commands and messages show *** instead."""
        if value and value not in self._secrets:
            self._secrets.append(value)
        return value

    def mask(self, text: str) -> str:
        for s in self._secrets:
            text = text.replace(s, "***")
        return text

    # Commands

    def run(self, cmd: BaseCommand, *, cwd: Path | None = None, env: dict[str, str] | None = None,
            input: str | None = None, quiet: bool = False, check: bool = True) -> Result:
        """Runs a command that changes something; `quiet` captures its output instead of showing it. A dry run prints
        the command instead and returns an empty success."""
        return self._exec(cmd, cwd, env, input, capture=quiet, changes=True, check=check)

    def read(self, cmd: BaseCommand, *, cwd: Path | None = None, env: dict[str, str] | None = None,
             input: str | None = None, stderr: bool = False) -> str:
        """Runs a command that only looks, even in a dry run, and returns its output without the final newline
        (with what it wrote to stderr after it, when `stderr`)."""
        result = self._exec(cmd, cwd, env, input, capture=True, changes=False)
        return (result.stdout + (result.stderr if stderr else "")).rstrip("\n")

    def ok(self, cmd: BaseCommand, *, cwd: Path | None = None, input: str | None = None) -> bool:
        """Whether a command that only looks succeeds."""
        return self._exec(cmd, cwd, None, input, capture=True, changes=False, check=False).returncode == 0

    def _exec(self, cmd: BaseCommand, cwd: Path | None, env: dict[str, str] | None, input: str | None,
              capture: bool, changes: bool, check: bool = True) -> Result:
        argv = [str(a) for a in cmd.formulate()]
        shown = self.mask(" ".join([Path(argv[0]).name, *(_quote(a) for a in argv[1:])]))
        if changes and self.dry_run:
            self.say(f"[dim]would run[/dim] {shown}")
            return Result(0)
        self.say(f"[dim]$ {shown}[/dim]")
        result = self.runner(Invocation(cmd, argv, cwd or self.root, env or {}, input, capture))
        if check and result.returncode != 0:
            detail = self.mask((result.stderr or result.stdout).strip())
            fail(f"{Path(argv[0]).name} failed (exit {result.returncode})" + (f": {detail}" if detail else ""))
        return result

    # Files

    def path(self, *parts: str | Path) -> Path:
        return self.root.joinpath(*parts)

    def write(self, path: Path, text: str) -> None:
        """Writes a file; a dry run says which file instead."""
        if self.dry_run:
            self.say(f"[dim]would write[/dim] {path}")
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


def _quote(arg: str) -> str:
    return arg if arg and all(c.isalnum() or c in "-_./:=@%+,^" for c in arg) else repr(arg)
