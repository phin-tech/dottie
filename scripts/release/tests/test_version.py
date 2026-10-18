import pytest
from semver import Version

from dottie_release import version as v
from dottie_release.dsl import ReleaseError


@pytest.mark.parametrize("current, part, expected", [
    ("0.6.1", "beta", "0.7.0-beta.1"),
    ("0.7.0-beta.1", "beta", "0.7.0-beta.2"),
    ("0.7.0-beta.2", "patch", "0.7.0"),
    ("0.7.0-beta.2", "minor", "0.7.0"),
    ("0.7.0-beta.2", "major", "1.0.0"),
    ("0.6.2-beta.1", "minor", "0.7.0"),
    ("0.6.2-beta.1", "patch", "0.6.2"),
    ("1.0.0-beta.3", "major", "1.0.0"),
    ("0.6.1", "patch", "0.6.2"),
    ("0.6.1", "minor", "0.7.0"),
    ("0.6.1", "major", "1.0.0"),
])
def test_bumps(current, part, expected):
    assert str(v.bumped(v.parse(current), part)) == expected


@pytest.mark.parametrize("text", ["0.7.0-alpha.1", "0.7.0-beta", "0.7.0+build.5", "0.7", "v0.7.0"])
def test_only_releases_and_numbered_betas_are_versions(text):
    with pytest.raises(ReleaseError):
        v.parse(text)


def test_is_beta():
    assert v.is_beta("0.7.0-beta.1") and not v.is_beta("0.7.0")


def test_reads_and_rewrites_project_yml(tmp_path):
    (tmp_path / "project.yml").write_text('settings:\n  base:\n    MARKETING_VERSION: "0.6.1"\n'
                                          '    CURRENT_PROJECT_VERSION: "13"\n        CFBundleVersion: $(CURRENT_PROJECT_VERSION)\n')
    assert v.read(tmp_path) == (Version.parse("0.6.1"), 13)
    text = v.with_build((tmp_path / "project.yml").read_text(), 14)
    assert 'CURRENT_PROJECT_VERSION: "14"' in text and "$(CURRENT_PROJECT_VERSION)" in text
