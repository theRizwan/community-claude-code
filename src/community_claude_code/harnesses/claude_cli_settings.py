"""Merge CCC gateway values into Claude Code's user settings."""

import json
import os
from pathlib import Path
from typing import cast

from community_claude_code.core.json_types import JsonObject
from community_claude_code.harnesses.claude import claude_proxy_values
from community_claude_code.harnesses.config_file import atomic_write_text, decode_json


def settings_path() -> Path:
    """Locate the per-user Claude Code settings honored by the native CLI."""

    home = Path.home()
    root = Path(os.environ.get("CLAUDE_CONFIG_DIR") or home / ".claude")
    if not root.is_absolute():
        root = home / ".claude"
    return root / "settings.json"


def _read(path: Path) -> JsonObject:
    try:
        source = path.read_text(encoding="utf-8-sig")
    except FileNotFoundError:
        return {}
    document = decode_json(source)
    if not isinstance(document, dict):
        raise ValueError("Claude Code settings must be an object")
    return cast(JsonObject, document)


def configure(path: Path, proxy_root_url: str, auth_token: str) -> bool:
    """Apply the proxy environment while preserving every unrelated setting."""

    path = path.resolve()
    document = _read(path)
    environment = document.get("env", {})
    if not isinstance(environment, dict):
        raise ValueError("Claude Code settings env must be an object")
    values = claude_proxy_values(proxy_root_url, auth_token)
    merged = {**environment, **values}
    changed = document.get("env") != merged
    if changed:
        document["env"] = merged
        atomic_write_text(path, json.dumps(document, indent=2, allow_nan=False) + "\n")
    return changed
