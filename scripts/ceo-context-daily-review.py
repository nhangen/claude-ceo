#!/usr/bin/env python3
"""Stage recent Daily notes for human context review without promoting claims."""
import argparse
from datetime import date, timedelta
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def digest(content):
    return hashlib.sha256(content.encode()).hexdigest()


def quote(content):
    for line in content.splitlines():
        text = line.strip()
        if text and text != "---" and not text.startswith(("#", "tags:", "type:", "date:")):
            return text[:500]
    return ""


def denied(vault, content):
    terms = [term.strip().lower() for term in os.environ.get("CEO_DISCRETION_DENY", "").split("|") if term.strip()]
    denylist = vault / "Profile/discretion-denylist.txt"
    if denylist.is_file():
        terms.extend(line.strip().lower() for line in denylist.read_text().splitlines()
                     if line.strip() and not line.lstrip().startswith("#"))
    return any(term in content.lower() for term in terms)


def daily_sources(vault, today, lookback):
    start = today - timedelta(days=lookback - 1)
    notes = []
    for path in sorted((vault / "Daily").glob("????-??-??.md")):
        try:
            note_day = date.fromisoformat(path.stem)
        except ValueError:
            continue
        if start <= note_day <= today and "sync-conflict" not in path.name:
            notes.append(path)
    return notes


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text() == content:
        return
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix="." + path.name + ".", delete=False) as output:
        output.write(content)
        output.flush()
        os.fsync(output.fileno())
        temporary = output.name
    os.replace(temporary, path)


def run(vault, context_script, today, lookback):
    inventory = subprocess.run([sys.executable, str(context_script), "--vault", str(vault), "inventory"], capture_output=True, text=True)
    if inventory.returncode:
        raise RuntimeError(inventory.stderr.strip() or "context inventory failed")
    existing = {item["id"] for item in json.loads(inventory.stdout)}
    new, rows = [], []
    for source in daily_sources(vault, today, lookback):
        content = source.read_text()
        relative = source.relative_to(vault).as_posix()
        if denied(vault, content):
            rows.append("- [ ] " + relative + " | withheld by discretion policy")
            continue
        source_quote = quote(content)
        if not source_quote:
            rows.append("- [ ] " + relative + " | blank or unreviewable")
            continue
        record = {
            "subject": "daily-note." + source.stem,
            "key": "review",
            "value": "Recent daily note needs explicit context review.",
            "effective_from": source.stem,
            "authority": "inferred",
            "visibility": "private",
            "source": relative,
            "quote": source_quote,
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json") as record_file:
            json.dump(record, record_file)
            record_file.flush()
            ingested = subprocess.run([sys.executable, str(context_script), "--vault", str(vault), "ingest", "--record", record_file.name], capture_output=True, text=True)
        if ingested.returncode:
            raise RuntimeError(ingested.stderr.strip() or "daily review candidate ingest failed")
        claim = json.loads(ingested.stdout)["id"]
        if claim not in existing:
            new.append(claim)
        rows.append("- [ ] " + relative + " | " + digest(content) + " | candidate " + claim)
    queue = ["# Daily context review queue", "", "This is a local-vault review queue, not an upstream completeness guarantee.", "Review every listed note before creating any report-visible factual record.", ""]
    queue.extend(rows or ["- No Daily notes in the configured review window."])
    atomic_write(vault / "CEO/reports/context/daily-review-queue.md", "\n".join(queue) + "\n")
    return {"new_candidates": new, "reviewed_sources": len(rows), "coverage": "local-vault-only"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault", type=Path, required=True)
    parser.add_argument("--context-script", type=Path, default=Path(__file__).with_name("ceo-context.py"))
    parser.add_argument("--today", default=date.today().isoformat())
    parser.add_argument("--lookback", type=int, default=int(os.environ.get("CEO_CONTEXT_DAILY_LOOKBACK_DAYS", "14")))
    args = parser.parse_args()
    try:
        if args.lookback < 1:
            raise ValueError("lookback must be positive")
        print(json.dumps(run(args.vault.resolve(strict=True), args.context_script.resolve(strict=True), date.fromisoformat(args.today), args.lookback)))
        return 0
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print("Daily context review unavailable: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
