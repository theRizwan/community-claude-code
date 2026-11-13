from pathlib import Path

from community_claude_code.cli import bootstrap


class FakeProcess:
    pid = 4242


def test_opencode_serve_skips_an_existing_listener(monkeypatch):
    monkeypatch.setattr(bootstrap, "_port_open", lambda host, port: True)

    report = bootstrap.start_opencode_serve()

    assert report == {
        "started": False,
        "reason": "already_listening",
        "url": "http://127.0.0.1:4096",
    }


def test_opencode_serve_skips_when_opencode_is_missing(monkeypatch):
    monkeypatch.setattr(bootstrap, "_port_open", lambda host, port: False)
    monkeypatch.setattr(bootstrap.shutil, "which", lambda name: None)

    report = bootstrap.start_opencode_serve()

    assert report["started"] is False
    assert report["reason"] == "not_installed"


def test_opencode_serve_starts_a_detached_fixed_endpoint(monkeypatch, tmp_path):
    calls = {}

    def fake_popen(command, **kwargs):
        calls["command"] = command
        calls["kwargs"] = kwargs
        return FakeProcess()

    monkeypatch.setattr(bootstrap, "_port_open", lambda host, port: False)
    monkeypatch.setattr(bootstrap.shutil, "which", lambda name: "opencode")
    monkeypatch.setattr(bootstrap, "config_dir_path", lambda: tmp_path)
    monkeypatch.setattr(bootstrap.subprocess, "Popen", fake_popen)

    report = bootstrap.start_opencode_serve()

    assert report["started"] is True
    assert report["pid"] == FakeProcess.pid
    assert calls["command"] == [
        "opencode",
        "serve",
        "--hostname",
        "127.0.0.1",
        "--port",
        "4096",
    ]
    assert calls["kwargs"]["stdin"] == bootstrap.subprocess.DEVNULL
    assert Path(calls["kwargs"]["cwd"]) == Path.home()


def test_desktop_launch_does_not_reopen_a_running_app(monkeypatch):
    monkeypatch.setattr(bootstrap, "_desktop_installed", lambda: True)
    monkeypatch.setattr(bootstrap, "_desktop_running", lambda: True)

    assert bootstrap.launch_claude_desktop() == {
        "launched": False,
        "reason": "already_running",
    }


def test_desktop_launch_reports_a_missing_app(monkeypatch):
    monkeypatch.setattr(bootstrap, "_desktop_installed", lambda: False)

    assert bootstrap.launch_claude_desktop() == {
        "launched": False,
        "reason": "not_installed",
    }
