#!/usr/bin/env python3
"""Fails if the upstream's identity is back in code or build scripts.

Cairn is a fork of Search by Office Commun. The fork must not carry the
upstream's bundle id, update address, signing team or mail address: a copy that
did would ask the upstream's server for updates and trust the upstream's key
(see Sources/Search/Brand.swift, Updater.swift). So these never appear:

  - "officecommun", in any case: the domain, the reverse-DNS bundle id, the
    mail address;
  - 7BYKA895MC: the upstream's Apple team id.

Where they may: the licence and the credits, which have to name the
upstream, and the history files that quote what the upstream wrote then.
That list is ALLOWED below, each with its reason; anything else is a failure.

    python3 Tests/brand_audit.py           exits 1 and lists every hit
    python3 Tests/brand_audit.py --self    checks the checker (no repo needed)
"""
import os
import re
import subprocess
import sys

FORBIDDEN = [
    ("the upstream's name as a domain, bundle id or address", re.compile(r"officecommun", re.I)),
    ("the upstream's Apple team id", re.compile(r"7BYKA895MC")),
]

# path -> why it is allowed to name the upstream. Exact paths only.
ALLOWED = {
    "LICENSE": "the MIT licence names its copyright holder, and must stay intact",
    "README.md": "credits the upstream project, as its licence and its request ask",
    "CHANGELOG.md": "upstream history, quoted as it was written",
    "ROADMAP.md": "upstream history, quoted as it was written",
    "Tests/brand_audit.py": "this file names what it looks for",
}

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def files():
    """Tracked files plus new ones not ignored: what a commit would contain."""
    out = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT, capture_output=True, check=True,
    ).stdout.decode()
    return [p for p in out.split("\0") if p]


def scan(text):
    """[(line number, reason, line)] for each forbidden thing in `text`."""
    hits = []
    for number, line in enumerate(text.splitlines(), 1):
        for reason, pattern in FORBIDDEN:
            if pattern.search(line):
                hits.append((number, reason, line.strip()[:120]))
    return hits


def audit():
    bad = []
    for path in files():
        if path in ALLOWED:
            continue
        full = os.path.join(ROOT, path)
        if not os.path.isfile(full) or os.path.islink(full):
            continue
        try:
            with open(full, encoding="utf-8") as handle:
                text = handle.read()
        except (UnicodeDecodeError, OSError):
            continue  # a picture or other binary: nothing it could name
        for number, reason, line in scan(text):
            bad.append(f"{path}:{number}: {reason}: {line}")
    return bad


def self_check():
    assert scan("let id = \"com.OfficeCommun.search\""), "a bundle id is caught in any case"
    assert scan("team = 7BYKA895MC"), "the team id is caught"
    assert scan("mailto:hello@officecommun.com"), "the address is caught"
    assert not scan("A fork of Search by Office Commun (MIT)"), "a credit with its space is not a bundle id"
    assert not scan("let id = Brand.bundleID"), "the constants are fine"
    print("brand_audit self-check: ok")


if __name__ == "__main__":
    if "--self" in sys.argv:
        self_check()
        sys.exit(0)
    found = audit()
    if found:
        print("The upstream's identity is back in code or scripts:\n", file=sys.stderr)
        print("\n".join(found), file=sys.stderr)
        print(f"\n{len(found)} hit(s). Use Brand.swift / build.sh's variables instead.", file=sys.stderr)
        sys.exit(1)
    print("brand_audit: clean")
