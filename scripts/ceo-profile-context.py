#!/usr/bin/env python3
"""Emit bounded, dated active domains for report prompts without reading staging."""

import datetime as dt
from pathlib import Path
import re
import sys


def main():
    vault = Path(sys.argv[1])
    today = dt.date.fromisoformat(sys.argv[2])
    relative = "Profile/goals.md"
    path = vault / relative
    if not path.exists() and not path.is_symlink():
        relative = "Profile.md"
        path = vault / relative
    print(f"Source: {relative}; maximum context age: 30 days.")
    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        print(f"Active domains unavailable ({type(exc).__name__}); do not infer current roles or priorities.")
        return 2 if path.exists() or path.is_symlink() else 0

    lines = content.splitlines()
    metadata = []
    if lines and lines[0] == "---" and "---" in lines[1:]:
        for line in lines[1:]:
            if line == "---":
                break
            metadata.append(line)
    dates = [line.split(":", 1)[1].strip() for line in metadata
             if line.startswith("active_domains_as_of:")]
    try:
        if len(dates) != 1 or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", dates[0]):
            raise ValueError
        as_of = dt.date.fromisoformat(dates[0])
        age = (today - as_of).days
        if not 0 <= age <= 30:
            raise ValueError
    except ValueError:
        print("Active domains need review: active_domains_as_of is missing, invalid, future-dated, or older than 30 days. Domain content withheld; use current task evidence only.")
        return 0

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
        return 0

    print(f"Active domains as of: {as_of.isoformat()} ({age} days old).")
    print("Background context only. A domain is not a task; require current actionable evidence. Historical reports do not override current employment status.")
    data = "\n".join(section).encode("utf-8")
    if len(data) > 10000:
        print("Active domains unavailable: section exceeds 10000 bytes; shorten and review it before use.")
        return 0
    print(data.decode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
