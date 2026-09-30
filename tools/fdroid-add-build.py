#!/usr/bin/env python3
"""Add a Builds entry for a released version to the F-Droid metadata.

Run after a release is published:

    tools/fdroid-add-build.py 1.1.0

The file is edited as text rather than round-tripped through a YAML parser,
because a parser would discard every comment in it and the comments are load
bearing: they record why AutoUpdateMode is off and why Description lives in
the app repo instead. The new entry is a copy of the previous one with the
version-specific fields substituted, so the toolchain in `sudo:` and the shape
of `build:` carry forward untouched.

Idempotent: a version already present is left alone.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT: Path = Path(__file__).resolve().parent.parent


def version_code(version: str) -> int:
    """major*10000 + minor*100 + patch, the scheme the release workflow uses."""
    major, minor, patch = (int(p) for p in version.split("."))
    return major * 10000 + minor * 100 + patch


def app_id() -> str:
    """The applicationId, read from the single place that defines it."""
    text = (ROOT / "build.sh").read_text()
    match = re.search(r'^APP_ID="([^"]+)"$', text, re.M)
    if not match:
        raise SystemExit("could not read APP_ID out of build.sh")
    return match.group(1)


def find_last_entry(lines: list[str]) -> tuple[int, int]:
    """Return the [start, end) line range of the last Builds entry."""
    starts = [i for i, l in enumerate(lines) if l.startswith("  - versionName:")]
    if not starts:
        raise SystemExit("no Builds entries to copy from")
    start = starts[-1]
    end = start + 1
    while end < len(lines) and (lines[end].startswith("    ") or not lines[end].strip()):
        end += 1
    # Trailing blank lines belong to the separation, not the entry.
    while end > start + 1 and not lines[end - 1].strip():
        end -= 1
    return start, end


def render_entry(template: list[str], old: str, new: str) -> list[str]:
    """Copy an entry, substituting only the version-bearing fields.

    Deliberately not a blanket search and replace. The build block carries a
    comment explaining the versionCode formula as "major*10000 + minor*100 +
    patch", and a blanket replace rewrites the multiplier in that prose along
    with the real values.
    """
    old_code, new_code = str(version_code(old)), str(version_code(new))
    rules: list[tuple[str, str]] = [
        (rf"^(\s*- versionName:\s*){re.escape(old)}\s*$", rf"\g<1>{new}"),
        (rf"^(\s*versionCode:\s*){re.escape(old_code)}\s*$", rf"\g<1>{new_code}"),
        (rf"^(\s*commit:\s*v?){re.escape(old)}\s*$", rf"\g<1>{new}"),
        (rf"^(\s*output:\s*\S*?){re.escape(old)}(\.apk)\s*$", rf"\g<1>{new}\g<2>"),
        (rf"^(\s*- export VERSION_NAME=){re.escape(old)}\s*$", rf"\g<1>{new}"),
        (rf"^(\s*- export VERSION_CODE=){re.escape(old_code)}\s*$", rf"\g<1>{new_code}"),
    ]
    out: list[str] = []
    for line in template:
        stripped = line.rstrip("\n")
        for pattern, replacement in rules:
            new_line, count = re.subn(pattern, replacement, stripped)
            if count:
                stripped = new_line
                break
        out.append(stripped + "\n")
    return out


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    version = argv[1]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        print(f"error: '{version}' is not major.minor.patch", file=sys.stderr)
        return 1

    path = ROOT / "fdroid" / f"{app_id()}.yml"
    if not path.exists():
        print(f"error: {path} does not exist", file=sys.stderr)
        return 1

    lines = path.read_text().splitlines(keepends=True)

    if any(l.strip() == f"- versionName: {version}" for l in lines):
        print(f"{version} is already in {path.name}, nothing to do")
        return 0

    start, end = find_last_entry(lines)
    template = lines[start:end]
    previous = template[0].split(":", 1)[1].strip()
    if version_code(version) <= version_code(previous):
        print(
            f"error: {version} is not newer than the last entry {previous}",
            file=sys.stderr,
        )
        return 1

    new_entry = render_entry(template, previous, version)
    if not new_entry[-1].endswith("\n"):
        new_entry[-1] += "\n"
    lines[end:end] = new_entry

    code = str(version_code(version))
    for i, line in enumerate(lines):
        if line.startswith("CurrentVersion:"):
            lines[i] = f"CurrentVersion: {version}\n"
        elif line.startswith("CurrentVersionCode:"):
            lines[i] = f"CurrentVersionCode: {code}\n"

    path.write_text("".join(lines))
    print(f"added {version} ({code}) to {path.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
