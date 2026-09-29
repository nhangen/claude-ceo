#!/usr/bin/env python3
"""Render the dated canonical Active Domains section for CEO reports."""
import argparse
from datetime import date
from pathlib import Path
import re
import sys


MAX_AGE_DAYS = 30


def unavailable(reason):
    return "Active domains unavailable: " + reason + ". Do not infer current roles or priorities from history.\n"


def render(vault, today):
    source = vault / "Profile/goals.md"
    try:
        content = source.read_text()
    except OSError:
        return unavailable("canonical Profile/goals.md is missing or unreadable")
    match = re.match(r"^---\n(.*?)\n---\n", content, re.DOTALL)
    if not match:
        return unavailable("canonical Profile/goals.md has no frontmatter")
    fields = dict(line.split(":", 1) for line in match.group(1).splitlines() if ":" in line)
    value = fields.get("active_domains_as_of", "").strip()
    try:
        as_of = date.fromisoformat(value)
    except ValueError:
        return unavailable("canonical active_domains_as_of is missing or invalid")
    age = (today - as_of).days
    if age < 0 or age > MAX_AGE_DAYS:
        return unavailable("canonical active domains are stale as of " + as_of.isoformat())
    section = re.search(r"^## Active Domains(?:\s*\([^\n]*\))?\s*$\n(.*?)(?=^## |\Z)", content, re.MULTILINE | re.DOTALL)
    if not section or not section.group(1).strip():
        return unavailable("canonical Profile/goals.md has no Active Domains section")
    domains = section.group(1).strip()
    if len(domains.encode()) > 10000:
        return unavailable("canonical Active Domains section exceeds the report context limit")
    return "Canonical active domains (Profile/goals.md; as of " + as_of.isoformat() + "):\n" + domains + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vault", type=Path)
    parser.add_argument("today", nargs="?", default=date.today().isoformat())
    args = parser.parse_args()
    try:
        print(render(args.vault.resolve(strict=True), date.fromisoformat(args.today)), end="")
        return 0
    except (OSError, ValueError) as error:
        print(unavailable(str(error)), end="")
        return 0


if __name__ == "__main__":
    sys.exit(main())
