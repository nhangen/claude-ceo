---
name: token-intake
description: Daily RTK + token-scope spend intake — drops one inbox item linking to today's report, and escalates a week tracking over the credit cap
trigger: cron
schedule: "45 8 * * 1-5"
preflight: none
tier: read
status: active
scope: each
runner: script
script: ceo-token-intake.sh
artifact: CEO/reports/token/{TODAY}-{HOST}.md
---

# Token Intake

Shell-only playbook. The dispatcher invokes `scripts/ceo-token-intake.sh` directly — no LLM call.

## What it does

Captures command outputs into `CEO/reports/token/<TODAY>-<HOST>.md`:

- `rtk gain` — global RTK savings
- `npx ccusage monthly` — Claude Code monthly spend
- `token-scope --since 1d` — Claude Code spend for the last 24h
- `token-scope --credits --since 8w` — weekly credits against the plan cap
- **credit cap check** — reads `--credits --json` and names where the week stands
- **auth health** — flags a host that ran sessions but produced no successful turns

Then idempotently appends one line to `CEO/inbox/<HOST>.md` (per-host, so two
Syncthing peers can't race on the same path):

```
- [ ] Review daily token report [[CEO/reports/token/<TODAY>-<HOST>]]
```

## Declared outputs

- `CEO/reports/token/{TODAY}-{HOST}.md` — the report
- `CEO/inbox/{HOST}.md` — the review line, plus up to two escalations below

## Escalations

Two conditions get their own inbox item, because they are actionable rather than
informational:

| Condition | Marker keyed on | Re-alerts when |
|---|---|---|
| Week is over (or projected over) the credit cap | the ISO week | a **new** week goes over |
| Host produced no successful Claude turns in 48h | the host | the prior alert was checked off |

Both dedupe on the **unchecked** marker, so a condition that persists doesn't
re-append daily but a genuine state transition does alert. This is the
`ceo-automated-writers-are-playbooks` rule in practice — the disk-monitor
incident appended 64 identical hourly alerts because it had no such gate.

**Why credits and not dollars.** The plan's cap is denominated in credits, so a
dollar total can't answer "am I over?". `--credits` reports weighted tokens per
ISO week against the cap; the alert carries the ratio and names the lever, which
is context size per turn — cache reads and writes are ~90% of a weighted week,
so shorter sessions and `/clear` move the number and shorter answers don't.

**A token-scope too old to have `--credits`** is escalated as its own inbox item
naming `/plugin update`, and the credits capture is skipped rather than attempted.
`capture` treats a non-zero exit as a run failure, so attempting it would redden
cron telemetry every morning for something only the user can fix — training them
to ignore the failure channel.

## Install

Registered automatically by `ceo playbook scan`. Repo playbooks under `docs/playbooks/` are picked up alongside vault playbooks; a vault playbook with the same `name` shadows the repo copy.

Note: cron entries for repo playbooks bake in `$INSTALL_DIR` at scan time. If the repo moves (re-clone, worktree shuffle), re-run `ceo playbook scan` to refresh the crontab.

## Disable

Set `status: inactive` in this file (or in a vault override at `$CEO_VAULT/CEO/playbooks/token-intake.md`) and re-scan.
