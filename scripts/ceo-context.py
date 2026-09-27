#!/usr/bin/env python3
"""Evidence-backed context ledger and deterministic report projection."""
import argparse
from collections import defaultdict
from datetime import date, datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def day(value):
    if date.fromisoformat(value).isoformat() != value:
        raise ValueError("dates must use YYYY-MM-DD")
    return value


def evidence(vault, source, quote):
    path = Path(source)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError("source must be vault-relative")
    resolved = (vault / path).resolve()
    relative = resolved.relative_to(vault).as_posix()
    if relative.startswith(("CEO/reports/", "CEO/log/", "CEO/alerts/")):
        raise ValueError("generated output cannot authorize context")
    content = resolved.read_text()
    if not quote or quote not in content:
        raise ValueError("evidence quote must match the source")
    return dict(source=relative, quote=quote, source_hash=digest(content))


def validate_evidence(record):
    for key in ("source", "quote", "source_hash"):
        if not isinstance(record.get(key), str) or not record[key]:
            raise ValueError("invalid evidence field")
    path = Path(record["source"])
    if path.is_absolute() or ".." in path.parts or path.as_posix().startswith(("CEO/reports/", "CEO/log/", "CEO/alerts/")):
        raise ValueError("invalid evidence path")
    if len(record["source_hash"]) != 64 or any(c not in "0123456789abcdef" for c in record["source_hash"]):
        raise ValueError("invalid evidence hash")


def validate_events(events):
    records = observations(events)
    for event in events.values():
        datetime.fromisoformat(event["recorded_at"])
        payload = event["payload"]
        kind = payload["kind"]
        if kind == "observation":
            if set(payload) != {"kind", "record"}:
                raise ValueError("unknown observation field")
            record = payload["record"]
            required = {"subject", "key", "value", "effective_from", "authority", "visibility", "supersedes", "source", "quote", "source_hash"}
            if not required <= set(record) or set(record) - required - {"effective_until", "review_after"}:
                raise ValueError("invalid observation fields")
            validate_evidence(record)
            for key in ("subject", "key", "value"):
                if not isinstance(record[key], str) or not record[key].strip():
                    raise ValueError("invalid claim field")
            for key in ("effective_from", "effective_until", "review_after"):
                if key in record:
                    day(record[key])
            if record.get("effective_until", record["effective_from"]) < record["effective_from"]:
                raise ValueError("invalid effective interval")
            if record["authority"] not in ("document", "direct-user", "inferred") or record["visibility"] not in ("report", "private"):
                raise ValueError("invalid claim enum")
            if not isinstance(record["supersedes"], list):
                raise ValueError("invalid supersession")
            for predecessor in record["supersedes"]:
                old = records.get(predecessor)
                if not old or predecessor == event["id"] or (old["subject"], old["key"]) != (record["subject"], record["key"]) or old["effective_from"] > record["effective_from"]:
                    raise ValueError("invalid predecessor")
        elif kind == "decision":
            if set(payload) != {"kind", "claim", "action", "actor", "authorization"}:
                raise ValueError("invalid decision fields")
            if payload["action"] not in ("accept", "reject", "withdraw") or payload["claim"] not in records:
                raise ValueError("invalid decision")
            if not isinstance(payload["actor"], str) or not payload["actor"].strip():
                raise ValueError("missing decision actor")
            if payload["action"] == "accept" and records[payload["claim"]]["authority"] == "inferred":
                raise ValueError("inferred claim cannot be accepted")
            validate_evidence(payload["authorization"])
        else:
            raise ValueError("unknown event kind")


def read_events(root):
    events = {}
    if not root.exists():
        return events
    if any("sync-conflict" in p.name for p in root.rglob("*")):
        raise ValueError("context ledger has an unresolved sync conflict")
    for path in sorted(root.glob("*.md")):
        for line in path.read_text().splitlines():
            if not line.startswith("- "):
                raise ValueError("context ledger is corrupt")
            event = json.loads(line[2:])
            ident = digest(canonical(event["payload"]))
            if event["id"] != ident:
                raise ValueError("context ledger checksum mismatch")
            events[ident] = event
    validate_events(events)
    return events


def append_event(root, payload):
    root.mkdir(parents=True, exist_ok=True)
    with (root / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        events = read_events(root)
        ident = digest(canonical(payload))
        if ident not in events:
            now = datetime.now(timezone.utc)
            event = dict(id=ident, recorded_at=now.isoformat(), payload=payload)
            validate_events(events | {ident: event})
            with (root / (now.strftime("%Y-%m") + ".md")).open("a") as out:
                out.write("- " + canonical(event) + "\n")
                out.flush()
                os.fsync(out.fileno())
        return ident


def observations(events):
    return {ident: event["payload"]["record"] for ident, event in events.items()
            if event["payload"]["kind"] == "observation"}


def ingest(vault, root, path):
    record = json.loads(Path(path).read_text())
    allowed = {"subject", "key", "value", "effective_from", "effective_until", "review_after",
               "authority", "visibility", "source", "quote", "supersedes"}
    if set(record) - allowed:
        raise ValueError("unknown record fields")
    for key in ("subject", "key", "value", "effective_from", "source", "quote"):
        if not isinstance(record.get(key), str) or not record[key].strip():
            raise ValueError("missing or invalid record field: " + key)
    record.setdefault("authority", "document")
    record.setdefault("visibility", "private")
    record.setdefault("supersedes", [])
    if record["authority"] not in ("document", "direct-user", "inferred"):
        raise ValueError("unknown authority")
    if record["visibility"] not in ("private", "report"):
        raise ValueError("unknown visibility")
    for key in ("effective_from", "effective_until", "review_after"):
        if record.get(key):
            day(record[key])
    if record.get("effective_until", record["effective_from"]) < record["effective_from"]:
        raise ValueError("effective_until precedes effective_from")
    known = observations(read_events(root))
    if not isinstance(record["supersedes"], list):
        raise ValueError("supersedes must be a list")
    for predecessor in record["supersedes"]:
        old = known.get(predecessor)
        if not old or (old["subject"], old["key"]) != (record["subject"], record["key"]):
            raise ValueError("supersession requires an existing claim for the same key")
        if old["effective_from"] > record["effective_from"]:
            raise ValueError("supersession cannot precede its predecessor")
    record["supersedes"] = sorted(set(record["supersedes"]))
    record.update(evidence(vault, record["source"], record["quote"]))
    if len(canonical(record)) > 16000:
        raise ValueError("record exceeds 16000 characters")
    return append_event(root, dict(kind="observation", record=record))


def projection(vault, root, as_of):
    events = read_events(root)
    records = observations(events)
    decisions = defaultdict(set)
    diagnostics = []
    for event in events.values():
        payload = event["payload"]
        if payload["kind"] == "decision":
            if payload["claim"] not in records:
                raise ValueError("decision references missing claim")
            decisions[payload["claim"]].add(payload["action"])
    suppressed = set()
    eligible = defaultdict(list)
    for ident, record in records.items():
        actions = decisions[ident]
        if record["effective_from"] > as_of:
            continue
        if "accept" in actions:
            suppressed.update(record["supersedes"])
        if "withdraw" in actions:
            continue
        if record.get("effective_until", "9999-12-31") < as_of:
            continue
        if "accept" in actions and "reject" in actions:
            diagnostics.append("Disputed decision: " + ident)
            eligible[(record["subject"], record["key"])].append((ident, record, False))
        elif "accept" in actions and "withdraw" not in actions:
            eligible[(record["subject"], record["key"])].append((ident, record, True))
    facts = []
    for claims in eligible.values():
        claims = [c for c in claims if c[0] not in suppressed]
        if len(claims) > 1:
            diagnostics.append("Conflicting claims: " + ", ".join(sorted(c[0] for c in claims)))
            continue
        for ident, record, accepted in claims:
            if not accepted:
                continue
            if record.get("effective_until", "9999-12-31") < as_of or record.get("review_after", "9999-12-31") < as_of:
                diagnostics.append("Review required: " + ident)
                continue
            try:
                source = (vault / record["source"]).resolve()
                source.relative_to(vault)
                changed = digest(source.read_text()) != record["source_hash"]
            except (OSError, ValueError):
                changed = True
            if changed:
                diagnostics.append("Evidence changed or unavailable; retained accepted snapshot: " + ident)
            if record["visibility"] == "report":
                facts.append({k: record[k] for k in ("subject", "key", "value", "effective_from")} | {"id": ident})
    return dict(schema=1, as_of=as_of, facts=sorted(facts, key=lambda f: f["id"]), diagnostics=sorted(diagnostics))


def render(view):
    lines = ["Current accepted context (evidence snapshots; never infer tasks from domains):"]
    for fact in view["facts"]:
        lines.append(f'- {fact["subject"]}.{fact["key"]}: {fact["value"]} (effective {fact["effective_from"]}; claim {fact["id"]})')
    if not view["facts"]:
        lines.append("No report-visible accepted facts. Do not infer current roles or priorities from history.")
    lines.extend("Context diagnostic: " + d for d in view["diagnostics"])
    text = "\n".join(lines) + "\n"
    if len(text.encode()) > 12000:
        raise ValueError("report context exceeds 12000 bytes; review the active claims")
    return text


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text() == content:
        return
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".context-")
    try:
        with os.fdopen(fd, "w") as out:
            out.write(content)
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault", type=Path)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("ingest").add_argument("--record", required=True)
    sub.add_parser("show").add_argument("id")
    sub.add_parser("inventory")
    for action in ("accept", "reject", "withdraw"):
        command = sub.add_parser(action)
        command.add_argument("id")
        command.add_argument("--actor", required=True)
        command.add_argument("--authorization-source", required=True)
        command.add_argument("--authorization-quote", required=True)
    for action in ("list", "render", "build", "check"):
        sub.add_parser(action).add_argument("--as-of", default=date.today().isoformat())
    args = parser.parse_args()
    if not args.vault:
        parser.error("--vault is required")
    vault = args.vault.resolve(strict=True)
    root = vault / "CEO/log/context"
    try:
        if args.command == "ingest":
            result = dict(id=ingest(vault, root, args.record))
        elif args.command == "inventory":
            events = read_events(root)
            states = defaultdict(set)
            for event in events.values():
                payload = event["payload"]
                if payload["kind"] == "decision":
                    states[payload["claim"]].add(payload["action"])
            result = []
            for ident, record in observations(events).items():
                actions = states[ident]
                state = ("withdrawn" if "withdraw" in actions else "disputed" if {"accept", "reject"} <= actions
                         else "accepted" if "accept" in actions else "rejected" if "reject" in actions else "candidate")
                result.append(dict(id=ident, subject=record["subject"], key=record["key"], state=state,
                                   visibility=record["visibility"], effective_from=record["effective_from"]))
        elif args.command in ("accept", "reject", "withdraw", "show"):
            records = observations(read_events(root))
            if args.id not in records:
                raise ValueError("unknown claim")
            if args.command == "show":
                result = dict(id=args.id, record=records[args.id])
            else:
                if args.command == "accept" and records[args.id]["authority"] == "inferred":
                    raise ValueError("inferred claims require a new evidence-backed observation")
                authorization = evidence(vault, args.authorization_source, args.authorization_quote)
                result = dict(id=append_event(root, dict(kind="decision", claim=args.id,
                              action=args.command, actor=args.actor, authorization=authorization)))
        else:
            result = projection(vault, root, day(args.as_of))
            if args.command == "render":
                print(render(result), end="")
                return 0
            if args.command == "build":
                text = render(result)
                atomic_write(vault / "CEO/reports/context/current.json", json.dumps(result, indent=2) + "\n")
                atomic_write(vault / "CEO/reports/context/current.md", text)
                status = "firing" if result["diagnostics"] else "clear"
                atomic_write(vault / "CEO/alerts/context.md", f"---\nstatus: {status}\nas_of: {args.as_of}\n---\n" + "\n".join(result["diagnostics"]) + "\n")
        print(json.dumps(result, indent=2))
        return 0
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        message = "Context unavailable: ledger or evidence validation failed. Do not infer current roles or priorities."
        if args.command == "build":
            atomic_write(vault / "CEO/alerts/context.md", "---\nstatus: unknown\n---\n" + message + "\n")
            atomic_write(vault / "CEO/reports/context/current.json", json.dumps(dict(schema=1, facts=[], diagnostics=[message])) + "\n")
            atomic_write(vault / "CEO/reports/context/current.md", message + "\n")
        print(message, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
