"""Print and copy a shareable local diagnostic report."""

import argparse
import json
import sys
from collections.abc import Sequence

from community_claude_code.runtime.diagnostics import collect_report

from .clipboard import ClipboardUnavailable, copy_text


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="ccc-doctor",
        description="Print and copy CCC diagnostics for a bug report.",
    )
    parser.add_argument(
        "--disconnect-integrations",
        action="store_true",
        help="Disconnect recognized CCC editor/app integrations before uninstalling.",
    )
    args = parser.parse_args(argv)
    if args.disconnect_integrations:
        from community_claude_code.harnesses.integration_cleanup import (
            IntegrationCleanupError,
            disconnect_integrations,
        )

        try:
            disconnect_integrations()
        except IntegrationCleanupError as exc:
            print(str(exc), file=sys.stderr)
            raise SystemExit(1) from None
        print("Disconnected recognized CCC editor/app integrations.")
        return
    text = json.dumps(collect_report(), indent=2, ensure_ascii=False) + "\n"
    sys.stdout.write(text)
    try:
        copy_text(text)
    except ClipboardUnavailable:
        print("Clipboard unavailable. Copy the JSON above manually.", file=sys.stderr)
    else:
        print("CCC diagnostics copied to the clipboard.", file=sys.stderr)
