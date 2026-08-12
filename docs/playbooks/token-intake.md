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
| Week is over cap **and worse than the worst full week in the window** | the ISO week | a **new** week beats the baseline |
| Host produced no successful Claude turns in 48h | the host | the prior alert was checked off |

The auth marker keys on the host, so a re-alert after check-off *is* the state
transition. The cap marker already keys on the ISO week, so it dedupes regardless
of checkbox state — checking it off must not make the same week report twice.

Neither escalation carries the report wikilink. The daily review line is counted
*by* wikilink to prove it appends exactly once, so a second line carrying the same
link would break that invariant every week the alert fired.

## Why the cap alert has a baseline

A bare "over cap" trigger is useless on a host that is chronically over — it
reports the baseline back as news every week, which is the nag
`ceo-automated-writers-are-playbooks` exists to prevent. So the alert fires only
when the week is over cap **and** above the worst *full* week in the 8-week window.
Truncated weeks hold only part of their spend, so counting them would understate
the bar.

When the window contains no full week at all — a fresh host, or `--since` too
short — there is no bar to clear, so the alert falls back to plain "over cap". That
fires at most once for that week and only when genuinely over, which is the right
trade for a host with no history to compare against.

The metric is `--credits`'s projection when it has one and spend-so-far otherwise.
The report suppresses its projection until a fifth of the week has elapsed, so a
Monday-morning cron run judges what has actually been spent rather than
extrapolating from a few hours.

**Why credits and not dollars.** The plan's cap is denominated in credits, so a
dollar total can't answer "am I over?". The alert names the lever: cache reads and
writes are ~90% of a weighted week, so shorter sessions and `/clear` move the
number and shorter answers don't.

## Failure modes it distinguishes

| Situation | What happens |
|---|---|
| `token-scope` missing from PATH entirely | the `--since 1d` capture fails, run exits non-zero — a real failure |
| `token-scope` present but predates `--credits` | credits capture skipped, one inbox item naming `/plugin update`, run exits **0** |
| `--credits --json` returns an unexpected shape | reported as a contract error, not as "no data" |
| `weekly_cap` is 0 or missing | refused rather than printed as "0M cap" |
| no started week in the window | reported as such; a future-dated week (clock skew) is never judged |

The stale-plugin case deliberately does not fail the run: `capture` treats a
non-zero exit as a run failure, and reddening cron every morning for something
only a `/plugin update` fixes trains the reader to ignore the failure channel.

## Install

Registered automatically by `ceo playbook scan`. Repo playbooks under `docs/playbooks/` are picked up alongside vault playbooks; a vault playbook with the same `name` shadows the repo copy.

Note: cron entries for repo playbooks bake in `$INSTALL_DIR` at scan time. If the repo moves (re-clone, worktree shuffle), re-run `ceo playbook scan` to refresh the crontab.

## Disable

Set `status: inactive` in this file (or in a vault override at `$CEO_VAULT/CEO/playbooks/token-intake.md`) and re-scan.
