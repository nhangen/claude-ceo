#!/usr/bin/env python3
"""Stage bounded vault updates as private context-review candidates."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text() == content:
        return
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix="." + path.name + ".", delete=False) as temp:
        temp.write(content)
        temp.flush()
        os.fsync(temp.fileno())
        temp_name = temp.name
    os.replace(temp_name, path)


def sources(vault):
    fixed = [vault / "CEO/from-nathan.md", vault / "Profile/goals.md", vault / "Profile.md"]
    inbox = vault / "Profile/_inbox"
    return [p for p in fixed + sorted(inbox.glob("*.md"))
            if p.is_file() and "sync-conflict" not in p.name]


def first_quote(content):
    for line in content.splitlines():
        text = line.strip()
        if text and text != "---" and not text.startswith(("#", "tags:", "type:", "date:")):
            return text[:500]
    raise ValueError("source has no quotable content")


def denied(vault, content):
    denylist = vault / "Profile/discretion-denylist.txt"
    terms = []
    if denylist.is_file():
        terms = [line.strip().lower() for line in denylist.read_text().splitlines()
                 if line.strip() and not line.lstrip().startswith("#")]
    lowered = content.lower()
    configured = [term.strip().lower() for term in os.environ.get("CEO_DISCRETION_DENY", "").split("|") if term.strip()]
    return any(term in lowered for term in terms + configured)


def stale_gate():
    configured = os.environ.get("CEO_VAULTKEEPER_STALENESS_CMD")
    if configured:
        command = shlex.split(configured)
    else:
        roots = [Path.home() / ".claude/plugins/cache", Path.home() / ".codex/plugins/cache"]
        matches = sorted(p for root in roots if root.exists()
                         for p in root.glob("*/obsidian/*/scripts/ask-staleness.sh"))
        if not matches:
            return "Vaultkeeper freshness checker is unavailable."
        command = ["bash", str(matches[-1])]
    result = subprocess.run(command, capture_output=True, text=True)
    text = (result.stdout + result.stderr).strip()
    if result.returncode or text:
        return text or "Vaultkeeper freshness check failed."
    return ""


def run(vault, context_script):
    freshness = stale_gate()
    alert = vault / "CEO/alerts/context-discover.md"
    if freshness:
        atomic_write(alert, "---\nstatus: unknown\n---\nVaultkeeper is not fresh; context discovery skipped.\n")
        return {"candidates": [], "held": [], "skipped": "vaultkeeper"}

    inventory = subprocess.run([sys.executable, str(context_script), "--vault", str(vault), "inventory"], capture_output=True, text=True)
    if inventory.returncode:
        raise RuntimeError(inventory.stderr.strip() or "context inventory failed")
    existing = {item["id"] for item in json.loads(inventory.stdout)}
    candidates, held = [], []
    for source in sources(vault):
        content = source.read_text()
        source_hash = hashlib.sha256(content.encode()).hexdigest()
        if denied(vault, content):
            held.append(source_hash)
            continue
        relative = source.relative_to(vault).as_posix()
        record = {
            "subject": "context-source." + hashlib.sha256(relative.encode()).hexdigest()[:20],
            "key": "review",
            "value": "A changed source needs explicit context review.",
            "effective_from": "1970-01-01",
            "authority": "inferred",
            "visibility": "private",
            "source": relative,
            "quote": first_quote(content),
        }
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json") as record_file:
            json.dump(record, record_file)
            record_file.flush()
            result = subprocess.run([sys.executable, str(context_script), "--vault", str(vault), "ingest", "--record", record_file.name], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or "context candidate ingest failed")
        candidate = json.loads(result.stdout)["id"]
        if candidate not in existing:
            candidates.append(candidate)

    status = "firing" if candidates or held else "clear"
    body = ["---", "status: " + status, "---", "new_candidate_count: " + str(len(candidates)), "withheld_count: " + str(len(held))]
    if candidates:
        body.append("Review candidates through the context inventory before creating a source-backed replacement.")
    if held:
        body.append("One or more source updates matched the discretion denylist; content was not copied into the ledger.")
    atomic_write(alert, "\n".join(body) + "\n")
    return {"candidates": candidates, "held": held}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault", type=Path, required=True)
    parser.add_argument("--context-script", type=Path, default=Path(__file__).with_name("ceo-context.py"))
    args = parser.parse_args()
    try:
        print(json.dumps(run(args.vault.resolve(strict=True), args.context_script.resolve(strict=True))))
        return 0
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print("Context discovery unavailable: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
