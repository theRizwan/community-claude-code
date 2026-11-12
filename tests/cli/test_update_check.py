"""The updater checks the published GitHub release before authorizing installation."""

from importlib.metadata import PackageNotFoundError

import httpx
import pytest

from community_claude_code.updater import check as update_check

RELEASE_URL = "https://github.com/theRizwan/community-claude-code/releases/tag/v1.10.0"


@pytest.fixture
def check(monkeypatch):
    original_client = httpx.Client

    def run(
        installed="1.9.0",
        status=200,
        error=None,
        print_version=False,
        release_url=RELEASE_URL,
    ):
        monkeypatch.setattr(update_check, "version", lambda name: installed)

        def respond(request):
            if error is not None:
                raise error
            if str(request.url).endswith("/releases/latest"):
                return httpx.Response(302, headers={"Location": release_url})
            if str(request.url) == release_url:
                return httpx.Response(status, text="release")
            raise AssertionError(str(request.url))

        monkeypatch.setattr(
            update_check.httpx,
            "Client",
            lambda **kwargs: original_client(
                transport=httpx.MockTransport(respond), **kwargs
            ),
        )
        return update_check.main(["--print-version"] if print_version else [])

    return run


@pytest.mark.parametrize(
    ("installed", "expected"),
    [
        ("1.9.0", 10),
        ("1.10.0", 0),
        ("1.11.0", 0),
        ("1.10.0+local", 0),
        ("1.10.0.dev1", 10),
    ],
)
def test_version_comparison(check, capsys, installed, expected):
    assert check(installed) == expected
    output = capsys.readouterr()
    assert installed in output.out
    assert not output.err


@pytest.mark.parametrize("installed", ["invalid", "0+unknown"])
def test_unknown_installed_version(check, installed):
    assert check(installed) == 1


def test_missing_distribution(monkeypatch, capsys):
    def missing(name):
        raise PackageNotFoundError(name)

    monkeypatch.setattr(update_check, "version", missing)
    assert update_check.main([]) == 1
    assert capsys.readouterr().err


def test_http_error(check, capsys):
    assert check(status=503) == 1
    assert capsys.readouterr().err


def test_timeout(check, capsys):
    assert check(error=httpx.ReadTimeout("timed out")) == 1
    assert capsys.readouterr().err


@pytest.mark.parametrize("installed", ["1.9.0", "1.10.0", "1.11.0"])
def test_print_version_is_only_the_authorized_release(check, capsys, installed):
    expected = 10 if installed == "1.9.0" else 0
    assert check(installed, print_version=True) == expected
    output = capsys.readouterr()
    assert output.out == ("1.10.0\n" if expected == 10 else "")
    assert installed in output.err


def test_failed_preflight_prints_no_release(check, capsys):
    assert (
        check(
            print_version=True,
            release_url="https://github.com/theRizwan/community-claude-code/releases/tag/v2.0.0/../main",
        )
        == 1
    )
    output = capsys.readouterr()
    assert output.out == ""
    assert output.err


@pytest.mark.parametrize(
    "suffix",
    ["v1.10.0rc1", "v01.10.0", "v1.10.0?query=1", "v1.10.0#fragment", "v1.10.0/extra"],
)
def test_invalid_github_release_does_not_authorize_installation(check, suffix):
    assert (
        check(
            release_url="https://github.com/theRizwan/community-claude-code/releases/tag/"
            + suffix,
        )
        == 1
    )


def test_release_from_another_repository_is_rejected(check):
    assert (
        check(
            release_url="https://github.com/other/repo/releases/tag/v1.10.0",
        )
        == 1
    )
