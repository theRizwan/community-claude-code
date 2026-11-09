#!/usr/bin/env python3
"""Apply the small, idempotent Community Claude Code patches used by Claude Opus 5.5.

1. Show the custom `opus-5.5` model as exactly "Claude Opus 5.5".
2. Do not add a duplicate "Claude Opus 5.5 (no thinking)" entry.
3. Find Claude Desktop's MSIX-redirected config directory on Windows.
"""

from __future__ import annotations

import sys
from pathlib import Path


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", newline="\n")


def patch_model_catalog(root: Path) -> bool:
    path = root / "src/community_claude_code/application/model_catalog.py"
    text = _read(path)
    if 'model_id == "opus-5.5"' in text:
        return False
    old = """        if definition := settings.custom_provider(provider_id):
            models[ref] = replace(
                model,
                display_name=f"{definition.display_name}/{model_id}"
                + (" (no thinking)" if model.supports_reasoning is False else ""),
            )
"""
    new = """        if definition := settings.custom_provider(provider_id):
            display_name = (
                definition.display_name
                if model_id == "opus-5.5"
                else f"{definition.display_name}/{model_id}"
            )
            models[ref] = replace(
                model,
                display_name=display_name
                + (" (no thinking)" if model.supports_reasoning is False else ""),
            )
"""
    if old not in text:
        raise SystemExit(f"Could not find the custom display block in {path}")
    _write(path, text.replace(old, new, 1))
    return True


def patch_claude_catalog(root: Path) -> bool:
    path = root / "src/community_claude_code/api/model_catalog.py"
    text = _read(path)
    if 'ref.endswith("/opus-5.5")' in text:
        return False
    old = """        if native:
            continue
        models.append(
"""
    new = """        if native:
            continue
        if ref.endswith("/opus-5.5"):
            continue
        models.append(
"""
    if old not in text:
        raise SystemExit(f"Could not find the no-thinking block in {path}")
    _write(path, text.replace(old, new, 1))
    return True


def patch_desktop_config_root(root: Path) -> bool:
    path = root / "src/community_claude_code/harnesses/claude_desktop_integration.py"
    text = _read(path)
    marker = 'parent.glob("Packages/Claude_*'
    if marker in text:
        return False
    old = """    if sys.platform == "win32":
        parent = Path(os.environ.get("LOCALAPPDATA") or home / "AppData/Local")
"""
    new = """    if sys.platform == "win32":
        parent = Path(os.environ.get("LOCALAPPDATA") or home / "AppData/Local")
        packaged = sorted(
            parent.glob("Packages/Claude_*/LocalCache/Local/Claude-3p")
        )
        if packaged:
            return packaged[0]
"""
    if old not in text:
        raise SystemExit(f"Could not find the Windows config root in {path}")
    _write(path, text.replace(old, new, 1))
    return True


def main(argv: list[str]) -> int:
    root = Path(argv[1] if len(argv) > 1 else r"C:\Users\Rizwan\Documents\community-claude-code")
    if not (root / "src/community_claude_code").is_dir():
        raise SystemExit(f"Not a Community Claude Code checkout: {root}")
    changed = []
    for name, function in (
        ("model_catalog", patch_model_catalog),
        ("claude catalog", patch_claude_catalog),
        ("desktop config root", patch_desktop_config_root),
    ):
        if function(root):
            changed.append(name)
    if changed:
        print("Patched: " + ", ".join(changed))
    else:
        print("Already patched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
