"""Lightweight entry points for installed Community Claude Code commands."""

import sys
from collections.abc import Sequence

from community_claude_code.core.version import package_version


def serve(argv: Sequence[str] | None = None) -> None:
    """Start the FastAPI server (registered as ``ccc-server``)."""
    if _print_version_if_requested(argv):
        return

    # Keep the server composition root off metadata-only command paths.
    from community_claude_code.cli.commands import serve as run_server

    args = sys.argv[1:] if argv is None else argv
    run_server(console_logging="--auto-started" not in args)


def _print_version_if_requested(argv: Sequence[str] | None) -> bool:
    args = sys.argv[1:] if argv is None else argv
    if "--version" not in args:
        return False
    print(f"community-claude-code {package_version()}")
    return True


def doctor(argv: Sequence[str] | None = None) -> None:
    """Print and copy a local diagnostic report (registered as ``ccc-doctor``)."""
    if _print_version_if_requested(argv):
        return
    from community_claude_code.cli.doctor import main

    main(argv)
