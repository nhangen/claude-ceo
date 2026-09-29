#!/usr/bin/env python3
"""Emit bounded, dated active domains for report prompts without reading staging.

Usage: ceo-profile-context.py [--doctor] VAULT TODAY

Exit 0 only when current domain content was printed; ceo-gather.sh exports
CEO_PROFILE_CONTEXT_VERSION=1 on that code alone. Exit 1 means withheld (stale,
undated, missing, empty, or oversized) and exit 2 means the profile exists but
could not be read. --doctor prints a health line for `ceo doctor` instead of the
content, and exits 1 when Nathan should re-confirm the section.
"""

import datetime as dt
from pathlib import Path
import re
import sys

MAX_AGE_DAYS = 30
MAX_BYTES = 10000
FRESH, WITHHELD, READ_ERROR = 0, 1, 2


def locate(vault):
    relative = "Profile/goals.md"
    path = vault / relative
    if not path.exists() and not path.is_symlink():
        relative = "Profile.md"
        path = vault / relative
    return relative, path


def as_of_dates(lines):
    metadata = []
    if lines and lines[0] == "---" and "---" in lines[1:]:
        for line in lines[1:]:
            if line == "---":
                break
            metadata.append(line)
    return [line.split(":", 1)[1].strip() for line in metadata
            if line.startswith("active_domains_as_of:")]


def parse_as_of(dates):
    if len(dates) != 1 or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", dates[0]):
        raise ValueError
    return dt.date.fromisoformat(dates[0])


def doctor(vault, today):
    relative, path = locate(vault)
    if not path.exists() and not path.is_symlink():
        print("no Profile/goals.md or Profile.md in the vault; reports run without current roles")
        return WITHHELD
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
        mtime = dt.date.fromtimestamp(path.stat().st_mtime)
    except (OSError, UnicodeError) as exc:
        print(f"{relative} unreadable ({type(exc).__name__}); reports run without current roles")
        return READ_ERROR
    try:
        as_of = parse_as_of(as_of_dates(lines))
    except ValueError:
        print(f"{relative} has no single valid active_domains_as_of: YYYY-MM-DD in its frontmatter; reports withhold Active Domains")
        return WITHHELD
    age = (today - as_of).days
    if age < 0:
        print(f"{relative} active_domains_as_of {as_of} is in the future; reports withhold Active Domains")
        return WITHHELD
    if age > MAX_AGE_DAYS:
        print(f"{relative} active_domains_as_of {as_of} is {age} days old (limit {MAX_AGE_DAYS}); reports withhold Active Domains until you re-confirm and bump it")
        return WITHHELD
    if (mtime - as_of).days > 1:
        print(f"{relative} was edited {mtime} but active_domains_as_of is {as_of}; re-confirm Active Domains and bump the date")
        return WITHHELD
    print(f"{relative} active_domains_as_of {as_of} ({age} days old)")
    return FRESH


def main(argv):
    doctor_mode = bool(argv) and argv[0] == "--doctor"
    if doctor_mode:
        argv = argv[1:]
    vault = Path(argv[0])
    today = dt.date.fromisoformat(argv[1])
    if doctor_mode:
        return doctor(vault, today)

    relative, path = locate(vault)
    print(f"Source: {relative}; maximum context age: {MAX_AGE_DAYS} days.")
    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        print(f"Active domains unavailable ({type(exc).__name__}); do not infer current roles or priorities.")
        return READ_ERROR if path.exists() or path.is_symlink() else WITHHELD

    lines = content.splitlines()
    try:
        as_of = parse_as_of(as_of_dates(lines))
        age = (today - as_of).days
        if not 0 <= age <= MAX_AGE_DAYS:
            raise ValueError
    except ValueError:
        print(f"Active domains need review: active_domains_as_of is missing, invalid, future-dated, or older than {MAX_AGE_DAYS} days. Domain content withheld; use current task evidence only.")
        return WITHHELD

    section = []
    for line in lines:
        if not section:
            if re.fullmatch(r"## Active Domains(?:\s*\([^\n]*\))?\s*", line):
                section.append(line)
        elif re.match(r"^#{1,2}\s", line):
            break
        else:
            section.append(line)
    if not section or not any(line.strip() for line in section[1:]):
        print("Active domains unavailable: canonical section is missing or empty. Do not fall back to historical roles.")
        return WITHHELD

    data = "\n".join(section).encode("utf-8")
    if len(data) > MAX_BYTES:
        print(f"Active domains unavailable: section exceeds {MAX_BYTES} bytes; shorten and review it before use.")
        return WITHHELD
    print(f"Active domains as of: {as_of.isoformat()} ({age} days old).")
    print("Background context only. A domain is not a task; require current actionable evidence. Historical reports do not override current employment status.")
    print(data.decode("utf-8"))
    return FRESH


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
