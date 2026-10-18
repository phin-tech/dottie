import pytest

from dottie_release.dsl import Release, ReleaseError, Result, plumbum_runner, tool


def test_reads_run_in_a_dry_run_and_changes_do_not(tmp_path):
    seen = []
    r = Release(tmp_path, dry_run=True, runner=lambda i: seen.append(i.argv[1:]) or Result(0, "looked\n"))
    assert r.read(tool("echo")["look"]) == "looked"
    r.run(tool("echo")["change"])
    r.write(tmp_path / "f.txt", "x")
    assert seen == [["look"]]
    assert not (tmp_path / "f.txt").exists()


def test_secrets_never_show_in_what_is_printed(tmp_path, capsys):
    r = Release(tmp_path, runner=lambda i: Result(1, "", f"bad password {i.argv[-1]}"))
    pw = r.secret("hunter2")
    with pytest.raises(ReleaseError) as e:
        r.run(tool("echo")["--password", pw])
    printed = capsys.readouterr().err
    assert "hunter2" not in printed and "--password ***" in printed
    assert "hunter2" not in str(e.value) and "***" in str(e.value)


def test_input_goes_to_stdin_and_cwd_and_env_apply(tmp_path):
    r = Release(tmp_path, runner=plumbum_runner)
    assert r.read(tool("cat"), input="a key") == "a key"
    assert r.read(tool("pwd")) == str(tmp_path.resolve())
    assert r.read(tool("sh")["-c", "echo $DOTTIE_TEST"], env={"DOTTIE_TEST": "yes"}) == "yes"


def test_a_failing_command_stops_the_lane_but_ok_only_answers(tmp_path):
    r = Release(tmp_path, runner=plumbum_runner)
    assert not r.ok(tool("false"))
    with pytest.raises(ReleaseError, match="false failed"):
        r.read(tool("false"))


def test_a_missing_tool_says_so():
    with pytest.raises(ReleaseError, match="not installed"):
        tool("no-such-tool-anywhere")
