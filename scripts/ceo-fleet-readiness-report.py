#!/usr/bin/env python3
"""Persist the checker contract and notify only changed verified problems."""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def atomic_write(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(body)
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


STATE_MARKER = "\n<!-- fleet-readiness-state -->\n```json\n"


def read_state(path, host):
    if not path.exists():
        return None
    text = path.read_text()
    if text.count(STATE_MARKER) != 1:
        raise ValueError("invalid prior decision record")
    prior = json.loads(text.split(STATE_MARKER)[1].split("\n```", 1)[0])
    if prior.get("host") != host or not isinstance(prior.get("active_failures"), list):
        raise ValueError("invalid prior state")
    return prior


def validate(report):
    if report.get("schema_version") != 1 or report.get("status") not in {"pass", "fail", "unknown"} or report.get("read_only") is not True:
        raise ValueError("invalid report")
    for field in ("failures", "unknown"):
        if not isinstance(report.get(field), list) or any(not isinstance(x, str) or not re.fullmatch(r"[a-zA-Z0-9:./_-]+", x) for x in report[field]):
            raise ValueError("invalid finding identities")
    stamp = datetime.datetime.fromisoformat(report["checked_at"].replace("Z", "+00:00"))
    if stamp.tzinfo is None or not -60 <= (datetime.datetime.now(datetime.timezone.utc) - stamp).total_seconds() <= 600:
        raise ValueError("stale report")
    if report["status"] == "pass" and (report["failures"] or report["unknown"]):
        raise ValueError("inconsistent pass")
    if report["status"] == "fail" and not report["failures"]:
        raise ValueError("inconsistent failure")
    if not isinstance(report.get("machines"), list) or not report["machines"]:
        raise ValueError("missing machine evidence")
    evidence = {}
    for machine in report["machines"]:
        if not re.fullmatch(r"[a-z0-9-]+", machine["id"]) or not isinstance(machine.get("checks"), dict):
            raise ValueError("invalid machine evidence")
        for key, value in machine["checks"].items():
            if not re.fullmatch(r"[a-zA-Z0-9:./_-]+", key) or value not in {"pass", "fail", "unknown", "not-required"}:
                raise ValueError("invalid check evidence")
            identity = machine["id"] + ":" + key
            if identity in evidence:
                raise ValueError("duplicate evidence")
            evidence[identity] = value
    if sorted(k for k, v in evidence.items() if v == "fail") != report["failures"] or sorted(k for k, v in evidence.items() if v == "unknown") != report["unknown"]:
        raise ValueError("summary disagrees with evidence")
    return evidence


def publish(report, vault, host, outcome):
    evidence = validate(report)
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    root = vault / "CEO"
    latest = root / "reports" / ("fleet-readiness-" + host + ".json")
    alert_path = root / "alerts" / ("fleet-readiness-" + host + ".md")
    prior = read_state(alert_path, host)
    previous = set(prior["active_failures"]) if prior else set()
    failures = set(report["failures"])
    active = failures | {key for key in previous if evidence.get(key) != "pass"}
    changed = prior is not None and (active != previous or report["unknown"] != prior.get("unknown"))
    state = "firing" if active else "unknown" if report["status"] == "unknown" else "clear"
    since = prior.get("since", now) if prior and prior.get("state") == state else now
    saved = {"host": host, "state": state, "since": since, "last_check": now, "active_failures": sorted(active), "status": report["status"], "observed_failures": sorted(failures), "unknown": report["unknown"], "read_only": True, "schema_version": 1}
    saved["machines"] = [{"id": m["id"], "checks": m["checks"], **({"primary_status": m["primary_status"]} if m.get("primary_status") in {"pass", "fail", "unknown"} else {})} for m in report["machines"]]
    saved["telemetry"] = {}
    for context, metrics in report.get("telemetry", {}).items():
        if not re.fullmatch(r"[a-z0-9-]+", context) or not isinstance(metrics, dict):
            raise ValueError("invalid telemetry")
        clean = {}
        for key in ("disk_free_bytes", "ram_available_bytes", "memory_pressure_free_pct"):
            if type(metrics.get(key)) is int and 0 <= metrics[key] <= 2**64:
                clean[key] = metrics[key]
        for key in ("gpu_temperatures_c", "gpu_power_limits_w"):
            if isinstance(metrics.get(key), list) and all(type(x) in {int, float} and 0 <= x <= 1000 for x in metrics[key]):
                clean[key] = metrics[key]
        clean["versions"] = {key: value for key, value in metrics.get("versions", {}).items() if key in {"git", "gh", "node", "python", "python3", "uv", "bun", "rg", "rtk", "claude", "codex", "opencode"} and isinstance(value, str) and re.fullmatch(r"\d+\.\d+(?:\.\d+)?", value)}
        clean["volumes_free_bytes"] = {key: value for key, value in metrics.get("volumes_free_bytes", {}).items() if re.fullmatch(r"[A-Z]:", key) and type(value) is int and 0 <= value <= 2**64}
        saved["telemetry"][context] = clean
    alert = "---\nstatus: " + state + "\nsince: " + since + "\nlast_check: " + now + "\nhost: " + host + "\n---\n\n# Fleet readiness\n\n"
    alert += "Current observation: " + report["status"] + ". Unknown observations never clear a previously verified failure.\n\n"
    alert += "## Verified problems\n\n" + ("\n".join("- " + x for x in sorted(active)) or "None observed.")
    alert += "\n\n## Unverified checks\n\n" + ("\n".join("- " + x for x in report["unknown"]) or "None.") + "\n"
    alert += STATE_MARKER + json.dumps(saved, sort_keys=True) + "\n```\n"
    log = root / "log" / "fleet-readiness" / (now[:7] + ".md")
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("a", encoding="utf-8") as stream:
        stream.write(now + " host=" + host + " status=" + report["status"] + " verified_failures=" + str(len(active)) + " unknown=" + str(len(report["unknown"])) + "\n")
    observation = {"schema_version": 1, "authoritative": False, "decision_record": "CEO/alerts/" + alert_path.name, "checked_at": now, "status": report["status"], "failures": report["failures"], "unknown": report["unknown"], "machines": saved["machines"], "telemetry": saved["telemetry"]}
    atomic_write(latest, json.dumps(observation, sort_keys=True) + "\n")
    if outcome:
        atomic_write(outcome, "fired" if changed else "noop")
    atomic_write(alert_path, alert)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--vault", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--checker", required=True)
    parser.add_argument("--registry", required=True)
    parser.add_argument("--local-context", default="")
    parser.add_argument("--outcome-file", default="")
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[a-zA-Z0-9_.-]+", args.host):
            raise ValueError("invalid host identity")
        command = [sys.executable, args.checker, "--registry", args.registry, "--live", "--local-context", args.local_context]
        result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        if result.returncode not in {0, 1}:
            raise ValueError("checker unavailable")
        report = json.loads(result.stdout)
        registry = json.loads(Path(args.registry).read_text())
        if {m["id"] for m in report.get("machines", [])} != {m["id"] for m in registry["machines"]}:
            raise ValueError("incomplete fleet observation")
        publish(report, Path(args.vault), args.host, Path(args.outcome_file) if args.outcome_file else None)
        return 0
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.TimeoutExpired):
        print("ERROR: readiness observation or persistence failed; this run cannot establish recovery", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
