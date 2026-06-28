---
name: ticket-triage-autopilot
description: Refresh the portable ticket-triage cache per owner, then escalate newly-appeared high-priority tickets to inbox as one line each (transition-gated). Silent on no transition — no top-N append on a clock.
trigger: cron
schedule: "0 9,13,17 * * 1-5"
preflight: none
tier: low-stakes write
status: active
runner: script
script: ceo-triage-autopilot.sh
model: ""
---

# Ticket Triage Autopilot

Shell-only adapter over the portable `ticket-triage` skill (nhangen/llm-tools, `home/.claude/skills/ticket-triage`). The skill owns the work; this playbook routes its output to the CEO inbox.

Per owner (default `nhangen`), each tick:

1. **`triage_update.py <owner>`** — silently refreshes the skill's per-host event-sourced cache. The skill owns its own cursor, change detection, and per-repo recompute (gitnexus + claude-mem-graph structural adjacency). Exit 1 means an incomplete reconcile (the skill held its cursor); recorded, not fatal.
2. **`triage_surface.py <owner>`** (preview) — reads the high-priority tickets that have *newly appeared* since the last surface. One inbox line per new ticket (deduped by a `<!-- triage-surface:<slug>#<num> -->` marker).
3. **`triage_surface.py <owner> --mark`** — consumes the transition, but **only after** the inbox write succeeded, so a failed append is retried next tick rather than lost (credential-rotation-atomicity ordering).

State machine, not signal generator. A tick with no new high-priority transition writes only the state file + a log line. This is the anti-nag contract: surfacing fires on a transition (a high-priority ticket landing), never on a clock — the every-30-min v1 poller is gone.

## v1 → v2

v1 polled merged PRs every 30 minutes, spawned `claude --print /ticket-triage`, and appended the top-3 adjacency-scored tickets to inbox on every merge. v2 moves cursor/detection/recompute/dedup into the skill (event-sourced cache, #104) and adds transition-gated surfacing (#107). The adapter no longer parses merges, classifies owners, or manages a cursor — it refreshes the cache and escalates only genuine high-priority transitions.

## Outputs

| File | Mode | When |
|---|---|---|
| `CEO/alerts/triage-autopilot-<host>.md` | overwrite | Every run. Frontmatter: `status: firing\|clear`, `since:`, `last_check:`, `host:`, `events_total:`, `incomplete:`, `failed_owners:`, `last_error:`. |
| `CEO/log/triage-autopilot/YYYY-MM.md` | append | Every run. One line. |
| `CEO/inbox.md` | append `- [ ]` lines | One line per newly-surfaced high-priority ticket; one per-owner-per-day line if a closed-set priority source reports unrecognized values. Idempotent via `<!-- triage-surface:... -->` markers. |

## State-machine semantics

- **No new high-priority ticket**: status `clear`, state + log only, no inbox write.
- **One or more newly-surfaced**: status `firing`, one inbox line each (deduped), `--mark` consumes the transition. `since` resets only on a real `clear → firing` transition.
- **Skill not installed** (`triage_update.py`/`triage_surface.py` absent at `CEO_TRIAGE_SKILL_DIR`): config error, not a transition — `last_error: skill_not_found:<dir>` on the state file, log line, exit 0 (scheduler not wedged).
- **`update` incomplete / `surface` or `mark` fails for an owner**: recorded in `incomplete` / `failed_owners` / `last_error`; other owners still processed. The skill's own failure-aware staleness (`last_error` on a repo entry) is surfaced by the reader.
- **Closed-set priority unknowns** (ZenHub/Projects seam): the skill reports them under `unknown` rather than silently mis-tiering; the adapter escalates one inbox line per owner per day (enum-config-typo-fallback).

## Idempotency

`inbox.md` is the canonical inbox. Every line carries a `<!-- triage-surface:<slug>#<num> -->` marker; the adapter greps for it before appending, so multi-host vault sync and re-previews never double-write. `--mark` advances the skill's surfaced snapshot so standalone (non-CEO) callers also don't re-fire.

## Environment overrides (test seams)

- `CEO_TRIAGE_SKILL_DIR` — directory holding `triage_update.py` / `triage_surface.py` (default `$HOME/.claude/skills/ticket-triage/scripts`). Tests point this at a stub dir.
- `CEO_TRIAGE_OWNERS` — space-separated GitHub owners to triage (default `nhangen`). ML-1's `gh` is the `nhangen` personal account.
- `CEO_TRIAGE_PYTHON` — Python interpreter (default `python3`).

## Origin

Issues #125/#146 (v1). v2 rework 2026-06-27: kills the every-30-min over-firing (the real cause of "fires too often"), keeps the valuable structural adjacency, and adds transition-gated surfacing for the formerly-deferred auto-surface. See nhangen/llm-tools `home/.claude/skills/ticket-triage/DESIGN.md` and PRs #104 (cache) / #107 (surface).

## Disable

Set `status: disabled` in this file and re-scan **on ML-1** (`ceo playbook scan` rewrites the host-local registry; run only on ML-1 per the `ceo-scan-only-on-ml1` rule). Editing this file activates nothing on its own; the next ML-1 scan picks up the status change.
