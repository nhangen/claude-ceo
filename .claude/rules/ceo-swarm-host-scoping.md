---
description: CEO swarm host scoping — ceo-schedulerd is the sole scheduler; scan is host-local and safe on any host; a non-owner host enables only each-scope telemetry playbooks, never single-scope scanner tasks
---

# CEO Swarm: Host Scoping

The CEO swarm schedules work through one daemon per host, `ceo-schedulerd`
(`lib/scheduler/`, claude-ceo). It is the **sole scheduler** — the pre-D1
per-playbook launchd/crontab install path is retired. Each host's daemon reads
the **host-local** `~/.ceo/registry.json` + `~/.ceo/enabled.json` and the
**synced** `CEO/swarm.json` owners map, then dispatches only the playbooks this
host is responsible for.

Two scopes decide where a playbook runs:

- **`scope: single`** — runs only on its **owner** host (the `owners{}` entry in
  `swarm.json`). All the scanner/automation playbooks (bug-fix, pr-review,
  pr-triage, morning-scan, git-monitor, value-tracker, …) are single-owned by
  **ML-1**.
- **`scope: each`** — runs on **every host that has enabled it** locally
  (`ceo playbook enable <name>` → `~/.ceo/enabled.json`). These are per-host
  **telemetry** playbooks with a `{HOST}`-keyed artifact (e.g. `token-intake`,
  `artifact: CEO/reports/token/{TODAY}-{HOST}.md`).

## The rule

- **`ceo playbook scan` is host-local and safe to run on any host.** Post-D1 it
  writes only `~/.ceo/registry.json`; it installs **no** launchd/cron, and it does
  **not** write the synced `swarm.json` (that is `ceo swarm doctor` / the
  host/owner-assignment commands). The earlier "scan only on ML-1" prohibition is
  **retired** — both of its hazards (launchd spray, synced-`registry.json`
  rewrite) no longer exist.
- **A non-owner host enables only each-scope telemetry playbooks.** On any host
  that is not the owner (e.g. the MacBook), `ceo playbook enable` **only** the
  each-scope telemetry playbooks (today: `token-intake`). Never enable a
  single-scope scanner task there — it belongs to its owner (ML-1) and, being
  single-scope, will not fire on a non-owner host anyway.
- **ML-1 remains the owner of all single-scope playbooks.** Editing/registering a
  single-scope playbook's ownership is still an ML-1-side action via
  `ceo swarm doctor`; the file change can be made anywhere and synced.
- **Make a playbook each-scope deliberately.** A playbook that should run on every
  host must be `scope: each` **and** carry a `{HOST}`-keyed artifact, or two hosts
  collide on one file. Converting a single-scope playbook to each-scope is its own
  change (e.g. PR #219 converted `token-intake`).

## How to apply

Setting up CEO on a new host:

1. `ceo setup` (or hand-write `~/.ceo/config`: `CEO_VAULT`, `CEO_OS`, `CEO_HOSTNAME`).
2. `ceo playbook scan` — host-local, safe; generates `~/.ceo/registry.json`.
3. `ceo playbook enable <name>` for **only** the each-scope telemetry playbooks.
4. Install `ceo-schedulerd` (launchd `com.ceo.schedulerd` on macOS, systemd user
   unit on Linux/WSL; templates in `lib/scheduler/deploy/`). Run `bun install` in
   `lib/scheduler` first or it crash-loops on a `croner` ENOENT.
5. Remove any legacy `# CEO Agent` crontab block — it double-fires the daemon
   (`ceo doctor` flags it). Back it up, then delete.
6. Verify with `ceo doctor`: `ceo-schedulerd alive`, no per-playbook OS entries.

## Why

2026-06-04 incident: registering the `reconcile` draft, `ceo playbook scan` on the
MacBook created 40 `com.ceo.*.plist` launchd agents and fired a notification storm.
That per-playbook install backend was **retired** in D1 (#136 / #142 / #144):
`ceo-schedulerd` became the sole scheduler and scan stopped installing anything.
Re-verified 2026-06-29 while finalizing the MacBook (MBP-2026) swarm host: scan
writes only `~/.ceo/registry.json`, leaves `swarm.json` untouched, and the daemon
dispatches only `token-intake` (the one each-scope playbook enabled there). The
enduring lesson is about **scope, not host**: a non-owner host runs only each-scope
telemetry, never single-scope scanner tasks.

## Sibling rules

- `ceo-automated-writers-are-playbooks` — same family: control what runs against
  the CEO vault. This rule controls *which host* runs *which scope* of playbook.
