"""Non-interactive post-install setup and background service startup."""

import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from community_claude_code.cli.launchers.common import ensure_proxy_available
from community_claude_code.config.loader import (
    ManagedConfigStore,
    clear_settings_cache,
    get_settings,
)
from community_claude_code.config.paths import (
    claude_desktop_disconnect_path,
    config_dir_path,
)
from community_claude_code.config.server_urls import local_proxy_root_url
from community_claude_code.harnesses import (
    claude_cli_settings,
    claude_desktop_integration,
)
from community_claude_code.runtime.opencode_shim import (
    DEFAULT_MODEL_BACKENDS,
    SHIM_DEFAULT_PORT,
    build_default_chains,
)

OPENCODE_SERVE_HOST = "127.0.0.1"
OPENCODE_SERVE_PORT = 4096
SHIM_HOST = "127.0.0.1"
SHIM_PORT = SHIM_DEFAULT_PORT
SHIM_PROVIDER_ID = "custom_" + hashlib.md5(
    b"opencode-free-models", usedforsecurity=False
).hexdigest()
_OPENCODE_LOG_FILENAME = "opencode-serve.log"
_SHIM_LOG_FILENAME = "shim.log"
_CREATE_DETACHED = (
    getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    | getattr(subprocess, "DETACHED_PROCESS", 0)
    if sys.platform == "win32"
    else 0
)

_USAGE = """Usage: ccc-bootstrap <command>

Commands:
  configure       Write Claude Code, Claude Desktop, and free-model settings.
  services        Start the CCC proxy, OpenCode server, and free-model shim.
  launch-desktop  Open the installed Claude Desktop app.
  setup           Run configure, services, then launch-desktop.
"""


def _desktop_installed() -> bool:
    if shutil.which("claude-desktop"):
        return True
    if sys.platform == "win32":
        parent = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData/Local")
        return next(parent.glob("Packages/Claude_*"), None) is not None
    if sys.platform == "darwin":
        return Path("/Applications/Claude.app").exists()
    return False


def _windows_process_running(names: tuple[str, ...]) -> bool:
    try:
        output = subprocess.run(
            ["tasklist", "/FO", "CSV", "/NH"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        ).stdout.lower()
    except OSError:
        return False
    return any(f'"{name.lower()}"' in output for name in names)


def _desktop_running() -> bool:
    if sys.platform == "win32":
        return _windows_process_running(("claude.exe",))
    if sys.platform == "darwin":
        try:
            return (
                subprocess.run(
                    ["pgrep", "-x", "Claude"],
                    capture_output=True,
                    check=False,
                ).returncode
                == 0
            )
        except OSError:
            return False
    return False


def _port_open(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=0.5):
            return True
    except OSError:
        return False


def _free_model_provider() -> dict[str, Any]:
    public_models = list(build_default_chains())
    return {
        "provider_id": SHIM_PROVIDER_ID,
        "display_name": "OpenCode",
        "base_url": f"http://{SHIM_HOST}:{SHIM_PORT}/v1",
        "api_keys": ["opencode"],
        "api_format": "openai_chat",
        "reasoning_format": "provider_default",
        "model_ids": public_models,
    }


def configure_free_models() -> dict[str, Any]:
    """Point every Claude model alias at a free OpenCode-backed shim model."""

    store = ManagedConfigStore()
    store.initialize()
    snapshot = store.read()
    managed = dict(snapshot.managed)
    provider = _free_model_provider()
    managed["CCC_CUSTOM_PROVIDERS"] = json.dumps(
        [provider], separators=(",", ":")
    )
    managed.setdefault("ANTHROPIC_AUTH_TOKEN", "ccc")
    managed.setdefault("PROXY_AUTH_ENABLED", "true")
    managed.setdefault("CCC_OPEN_BROWSER", "false")
    managed["MODEL"] = f"{SHIM_PROVIDER_ID}/fable-5-free"
    managed["MODEL_FABLE"] = f"{SHIM_PROVIDER_ID}/fable-5-free"
    managed["MODEL_OPUS"] = f"{SHIM_PROVIDER_ID}/opus-4.5-free"
    managed["MODEL_SONNET"] = f"{SHIM_PROVIDER_ID}/sonnet-4.5-free"
    managed["MODEL_HAIKU"] = f"{SHIM_PROVIDER_ID}/haiku-4.5-free"
    store.commit(managed, expected=snapshot)
    clear_settings_cache()
    return {
        "provider": provider["provider_id"],
        "models": provider["model_ids"],
        "base_url": provider["base_url"],
    }


def configure_integrations() -> dict[str, Any]:
    """Point Claude Code and Claude Desktop at the local CCC gateway."""

    free_models = configure_free_models()
    settings = get_settings()
    proxy_root_url = local_proxy_root_url(settings)
    auth_token = settings.proxy_auth_token
    path = claude_cli_settings.settings_path()
    changed = claude_cli_settings.configure(path, proxy_root_url, auth_token)
    result: dict[str, Any] = {
        "claude_code": {
            "changed": changed,
            "settings": str(path),
            "base_url": proxy_root_url,
        },
        "free_models": free_models,
    }
    if not _desktop_installed():
        result["claude_desktop"] = {"connected": False, "reason": "not_installed"}
        return result
    try:
        status = claude_desktop_integration.configure(
            claude_desktop_integration.config_root(),
            proxy_root_url,
            auth_token,
            True,
            disconnect_path=claude_desktop_disconnect_path(),
        )
    except claude_desktop_integration.ManagedDesktopError:
        result["claude_desktop"] = {"connected": False, "reason": "managed"}
    except claude_desktop_integration.PendingDisconnectError:
        result["claude_desktop"] = {"connected": False, "reason": "disconnect_pending"}
    except claude_desktop_integration.PendingMigrationError:
        result["claude_desktop"] = {"connected": False, "reason": "migration_pending"}
    except (OSError, ValueError):
        result["claude_desktop"] = {"connected": False, "reason": "unavailable"}
    else:
        result["claude_desktop"] = {
            "connected": status["connected"],
            "profile": status["paths"]["desktop_profile"],
        }
    return result


def start_opencode_serve() -> dict[str, Any]:
    """Start one detached OpenCode server unless its fixed port is in use."""

    url = f"http://{OPENCODE_SERVE_HOST}:{OPENCODE_SERVE_PORT}"
    if _port_open(OPENCODE_SERVE_HOST, OPENCODE_SERVE_PORT):
        return {"started": False, "reason": "already_listening", "url": url}
    binary = shutil.which("opencode")
    if binary is None:
        return {"started": False, "reason": "not_installed", "url": url}

    log_path = config_dir_path() / "logs" / _OPENCODE_LOG_FILENAME
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("ab") as output:
            process = subprocess.Popen(
                [
                    binary,
                    "serve",
                    "--hostname",
                    OPENCODE_SERVE_HOST,
                    "--port",
                    str(OPENCODE_SERVE_PORT),
                ],
                cwd=Path.home(),
                stdin=subprocess.DEVNULL,
                stdout=output,
                stderr=subprocess.STDOUT,
                creationflags=_CREATE_DETACHED,
                start_new_session=sys.platform != "win32",
            )
    except OSError as exc:
        return {"started": False, "reason": f"spawn_failed: {exc}", "url": url}
    return {
        "started": True,
        "pid": process.pid,
        "url": url,
        "log": str(log_path),
    }


def _shim_healthy() -> bool:
    try:
        with urllib.request.urlopen(
            f"http://{SHIM_HOST}:{SHIM_PORT}/health", timeout=2
        ) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, ValueError, urllib.error.URLError):
        return False
    return bool(isinstance(payload, dict) and payload.get("ok"))


def start_shim() -> dict[str, Any]:
    """Start the detached free-model shim unless it already answers."""

    url = f"http://{SHIM_HOST}:{SHIM_PORT}"
    if _shim_healthy():
        return {"started": False, "reason": "already_running", "url": url}
    log_path = config_dir_path() / "logs" / _SHIM_LOG_FILENAME
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("ab") as output:
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-m",
                    "community_claude_code.runtime.opencode_shim",
                    "--shim-port",
                    str(SHIM_PORT),
                    "--opencode-port",
                    str(OPENCODE_SERVE_PORT),
                    "--log-file",
                    str(log_path),
                ],
                cwd=Path.home(),
                stdin=subprocess.DEVNULL,
                stdout=output,
                stderr=subprocess.STDOUT,
                creationflags=_CREATE_DETACHED,
                start_new_session=sys.platform != "win32",
            )
    except OSError as exc:
        return {"started": False, "reason": f"spawn_failed: {exc}", "url": url}

    deadline = time.time() + 60
    while time.time() < deadline:
        if _shim_healthy():
            return {
                "started": True,
                "pid": process.pid,
                "url": url,
                "log": str(log_path),
            }
        if process.poll() is not None:
            break
        time.sleep(0.2)
    return {"started": False, "reason": "not_healthy", "url": url}


def start_runtimes() -> dict[str, Any]:
    """Start the shared OpenCode server and the free-model shim, never the proxy."""

    return {
        "opencode_serve": start_opencode_serve(),
        "shim": start_shim(),
    }


def start_services() -> dict[str, Any]:
    """Ensure the CCC proxy, OpenCode server, and free-model shim keep running."""

    settings = get_settings()
    proxy_root_url = local_proxy_root_url(settings)
    # Bring up the free-model runtime first so the proxy never forwards to a
    # shim that is still starting.
    runtimes = start_runtimes()
    error = ensure_proxy_available(proxy_root_url, env=dict(os.environ))
    return {
        "proxy": {
            "url": proxy_root_url,
            "ready": error is None,
            "error": error,
        },
        **runtimes,
    }


def launch_claude_desktop() -> dict[str, Any]:
    """Open Claude Desktop without blocking the installer."""

    if not _desktop_installed():
        return {"launched": False, "reason": "not_installed"}
    if _desktop_running():
        return {"launched": False, "reason": "already_running"}

    if sys.platform == "darwin":
        try:
            subprocess.Popen(
                ["open", "-a", "Claude"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as exc:
            return {"launched": False, "reason": f"spawn_failed: {exc}"}
        return {"launched": True}

    binary = shutil.which("claude-desktop")
    if binary is None:
        local = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData/Local")
        candidate = local / "Microsoft/WindowsApps/claude-desktop.exe"
        if not candidate.is_file():
            return {"launched": False, "reason": "not_found"}
        binary = str(candidate)
    try:
        process = subprocess.Popen(
            [binary],
            cwd=Path.home(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=_CREATE_DETACHED,
            start_new_session=sys.platform != "win32",
        )
    except OSError as exc:
        return {"launched": False, "reason": f"spawn_failed: {exc}"}
    return {"launched": True, "pid": process.pid}


def setup() -> dict[str, Any]:
    """Apply client configuration, start services, and open Claude Desktop."""

    result = configure_integrations()
    services = start_services()
    result["services"] = services
    result["desktop_launch"] = launch_claude_desktop()
    return result


def main(argv: list[str] | None = None) -> None:
    """Run one bootstrap command, printing a JSON report."""

    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args[0] in {"-h", "--help"}:
        print(_USAGE, end="")
        return
    command = args[0]
    if len(args) > 1:
        raise SystemExit(f"Unknown arguments: {' '.join(args[1:])}")
    if command == "configure":
        result = configure_integrations()
    elif command == "services":
        result = start_services()
    elif command == "launch-desktop":
        result = launch_claude_desktop()
    elif command == "setup":
        result = setup()
    else:
        print(_USAGE, file=sys.stderr, end="")
        raise SystemExit(2)
    print(json.dumps(result, indent=2))
    if command == "services" and not result["proxy"]["ready"]:
        raise SystemExit(1)
