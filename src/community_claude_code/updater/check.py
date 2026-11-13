"""Standalone version preflight for the native update launchers."""

import argparse
import re
import sys
from importlib.metadata import PackageNotFoundError, version
from urllib.parse import urljoin

import httpx
from packaging.version import Version

RELEASE_URL = "https://github.com/theRizwan/community-claude-code/releases/"
UPDATE_AVAILABLE = 10


def main(argv: list[str] | None = None) -> int:
    """Return 10 to authorize installation, 0 to skip, or 1 on check failure."""
    parser = argparse.ArgumentParser(prog="_ccc-update-check")
    parser.add_argument("--print-version", action="store_true")
    arguments = parser.parse_args(argv)
    try:
        installed = Version(version("community-claude-code"))
        if str(installed) == "0+unknown":
            raise ValueError("installed CCC version is unknown")
        with httpx.Client(timeout=10.0, follow_redirects=False) as client:
            response = client.get(RELEASE_URL + "latest")
            if response.is_redirect:
                redirect_target = response.headers.get("Location")
                if redirect_target is None:
                    raise ValueError("GitHub did not return a release redirect target")
                resolved_target = urljoin(str(response.url), redirect_target)
                selected = re.fullmatch(
                    re.escape(RELEASE_URL)
                    + r"tag/v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))",
                    resolved_target,
                )
                if selected is None:
                    raise ValueError("GitHub did not return a canonical CCC release URL")
                response = client.get(resolved_target)
            response.raise_for_status()
            selected = re.fullmatch(
                re.escape(RELEASE_URL)
                + r"tag/v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))",
                str(response.url),
            )
            if selected is None:
                raise ValueError("GitHub did not return a canonical CCC release URL")
            published = selected[1]
        latest = Version(published)
    except (
        PackageNotFoundError,
        httpx.HTTPError,
        ValueError,
    ) as exc:
        print(f"Could not check for CCC updates: {exc}. Please retry.", file=sys.stderr)
        return 1

    output = sys.stderr if arguments.print_version else sys.stdout
    if installed == latest:
        print(f"CCC {installed} is already up to date.", file=output)
        return 0
    if installed > latest:
        print(
            f"CCC {installed} is newer than the published version {latest}. No update needed.",
            file=output,
        )
        return 0
    print(
        f"CCC update available: {installed} -> {latest}. Running the installer.",
        file=output,
    )
    if arguments.print_version:
        print(published)
    return UPDATE_AVAILABLE
