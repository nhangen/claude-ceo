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
import uuid
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

FINDING_REASONS = {
    "collector-unsupported": (False, "Collector check not implemented; this is a coverage gap, not a verified outage.", "Add a tested provider probe."),
    "probe-timeout": (True, "Management probe exceeded its time budget; dependent checks have no evidence.", "Inspect the bounded probe and retry."),
    "ssh-authentication": (True, "The monitor SSH identity was rejected.", "Verify the dedicated monitor key and account."),
    "ssh-host-key": (True, "Strict SSH host-key verification rejected the connection.", "Verify the fingerprint before updating trust."),
    "ssh-unreachable": (True, "The monitor could not establish an SSH connection.", "Check the management route and SSH service."),
    "probe-exit": (True, "The management probe exited unsuccessfully.", "Inspect the fixed helper exit and retry."),
    "probe-invalid-output": (True, "The probe returned an invalid observation.", "Check the helper protocol and shell startup output."),
    "probe-unavailable": (True, "The collector could not start its probe executable.", "Check the collector runtime and dependencies."),
    "login-executable-unverified": (True, "Login executable wrapper was refused or could not be safely inspected; not proof of absence.", "Verify an installed native executable without automatic installation."),
    "dependency-unverified": (True, "GitHub read could not run because login-shell gh was unverified.", "Verify the gh executable and repeat the private read."),
    "workflow-skipped": (False, "Latest workflow was skipped, not failed or successfully validated.", "Inspect its condition if validation was expected."),
    "workflow-incomplete": (True, "No completed workflow with valid timestamp evidence was established.", "Inspect the workflow state and timestamps."),
    "workflow-inconclusive": (True, "Workflow conclusion does not establish success or failure.", "Inspect the recorded conclusion."),
    "evidence-missing": (True, "Required observation was absent or inconclusive.", "Rerun the named probe and inspect its evidence."),
    "check-failed": (True, "Negative evidence was returned for this required check.", "Correct the named capability and verify it passes."),
}


def clean_finding_details(report):
    supplied = report.get("finding_details", {})
    if not isinstance(supplied, dict):
        raise ValueError("invalid finding details")
    failures = set(report.get("failures", [])) | set(report.get("active_failures", []))
    details = {}
    for identity in failures | set(report.get("unknown", [])):
        if identity not in supplied:
            continue
        entry = supplied[identity]
        code = entry.get("code") if isinstance(entry, dict) else None
        if not isinstance(code, str) or code not in FINDING_REASONS:
            code = "evidence-missing"
        if identity in failures:
            code = "check-failed"
        elif code == "collector-unsupported" and not identity.endswith((":serving-readiness", ":trust-state")):
            code = "evidence-missing"
        elif code == "workflow-skipped" and ":local-ci:workflow:" not in identity:
            code = "evidence-missing"
        actionable, summary, next_step = FINDING_REASONS[code]
        details[identity] = {"code": code, "actionable": actionable, "summary": summary, "next_step": next_step}
        exit_code = entry.get("exit_code") if isinstance(entry, dict) else None
        if type(exit_code) is int and -255 <= exit_code <= 255:
            details[identity]["exit_code"] = exit_code
    return details


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


def validate(report, registry):
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
    workflow_evidence = report.get("workflow_evidence", {})
    if not isinstance(workflow_evidence, dict):
        raise ValueError("invalid workflow evidence")
    clean_workflows = {}
    local_ci = registry.get("local_ci", {})
    workflow_machine = local_ci.get("machine_id") if isinstance(local_ci, dict) else None
    workflow_repos = local_ci.get("repos") if isinstance(local_ci, dict) else None
    for repo, workflow in workflow_evidence.items():
        if not isinstance(repo, str) or not re.fullmatch(r"[a-zA-Z0-9_-]+", repo) or not isinstance(workflow, dict) or set(workflow) != {"completed_at", "age_seconds"} or not isinstance(workflow["completed_at"], str):
            raise ValueError("invalid workflow evidence")
        identity = str(workflow_machine) + ":local-ci:workflow:" + repo
        if not isinstance(workflow_repos, list) or repo not in workflow_repos or identity not in evidence:
            raise ValueError("invalid workflow evidence")
        completed = datetime.datetime.fromisoformat(workflow["completed_at"].replace("Z", "+00:00"))
        age = workflow["age_seconds"]
        actual_age = int((stamp - completed).total_seconds()) if completed.tzinfo is not None else -1
        if type(age) is not int or not 0 <= age <= 2**63 or completed > stamp or abs(actual_age - age) > 2:
            raise ValueError("invalid workflow evidence")
        clean_workflows[repo] = {"completed_at": completed.isoformat(), "age_seconds": age}
    return evidence, clean_workflows


def publish(report, registry, vault, host, outcome):
    evidence, workflow_evidence = validate(report, registry)
    finding_details = clean_finding_details(report)
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    publication_id = uuid.uuid4().hex
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
    saved = {"host": host, "state": state, "since": since, "last_check": now, "publication_id": publication_id, "active_failures": sorted(active), "status": report["status"], "observed_failures": sorted(failures), "unknown": report["unknown"], "read_only": True, "schema_version": 1}
    saved["machines"] = [{"id": m["id"], "checks": m["checks"], **({"primary_status": m["primary_status"]} if m.get("primary_status") in {"pass", "fail", "unknown"} else {})} for m in report["machines"]]
    saved["workflow_evidence"] = workflow_evidence
    saved["finding_details"] = finding_details
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
    alert += "\n\n## Unverified checks\n\n" + ("\n".join("- " + x + (": " + finding_details[x]["summary"] + " Next: " + finding_details[x]["next_step"] + (" [informational]" if not finding_details[x]["actionable"] else "") if x in finding_details else ": reason unavailable from this collector version." ) for x in report["unknown"]) or "None.") + "\n"
    alert += STATE_MARKER + json.dumps(saved, sort_keys=True) + "\n```\n"
    log = root / "log" / "fleet-readiness" / (now[:7] + ".md")
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("a", encoding="utf-8") as stream:
        stream.write(now + " host=" + host + " status=" + report["status"] + " verified_failures=" + str(len(active)) + " unknown=" + str(len(report["unknown"])) + "\n")
    observation = {"schema_version": 1, "authoritative": False, "decision_record": "CEO/alerts/" + alert_path.name, "publication_id": publication_id, "checked_at": now, "status": report["status"], "failures": report["failures"], "unknown": report["unknown"], "finding_details": finding_details, "machines": saved["machines"], "telemetry": saved["telemetry"], "workflow_evidence": workflow_evidence}
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
        publish(report, registry, Path(args.vault), args.host, Path(args.outcome_file) if args.outcome_file else None)
        return 0
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.TimeoutExpired):
        print("ERROR: readiness observation or persistence failed; this run cannot establish recovery", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
