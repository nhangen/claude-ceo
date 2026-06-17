---
name: story-points
description: Weekly AwesomeMotive PR-review + backlog story-points report — by reviewer and by author, sorted high to low, written to the vault alongside the existing story-points reports
trigger: cron
schedule: "0 17 * * 5"
preflight: none
tier: read
status: active
runner: skill
skill: story-points
out_pattern: Awesome Motive/reports/story-points/${TODAY}-backlog-pr-story-points.md
requires: [ZENHUB_TOKEN, ZENHUB_WORKSPACE_ID]
---

# Story Points

Skill-backed playbook. The dispatcher invokes the `story-points` skill directly via
`runner: skill` — no LLM call. Every Friday 17:00 it produces one markdown report with
two tables, each sorted by story points high→low:

- **PR Review Story Points** — PRs updated in the current quarter, credited to reviewer.
- **Backlog Story Points** — closed PRs + closed issues in the quarter, by author/assignee.

Runs one hour before the `am-weekly-merges` launchd job, mirroring that weekly cadence.

## Origin

Requested 2026-06-17: the same report the `backlog-pr-story-points` skill prints to the
terminal, but saved weekly to `Awesome Motive/reports/story-points/` (where the existing
manual captures live). Built as a CEO playbook rather than a hand-rolled cron so
`ceo playbook scan` owns scheduling and credential injection.

## Credentials

`requires: [ZENHUB_TOKEN, ZENHUB_WORKSPACE_ID]` — ceo-cron sources
`~/.config/ceo/credentials.env` and validates both are set before exec. GitHub auth is
resolved by the skill via `gh auth token -u nhangenam` (awesomemotive org access).

## Outputs

| File | Mode | When |
|---|---|---|
| `Awesome Motive/reports/story-points/${TODAY}-backlog-pr-story-points.md` | create | Every Friday 17:00 |

The quarter is recorded in the report body and frontmatter tags (the `out_pattern`
filename carries the date, not the quarter).

## Install

Run `ceo playbook scan` **on ML-1 only** (the `ceo-scan-only-on-ml1` rule). The skill
lives in llm-tools at `home/.claude/skills/story-points/`; ML-1 must have that pulled.

## ZenHub → GitHub Projects migration

The skill bundles a copy of the ZenHub analyzer. When optin-monster-app moves ZH → GitHub
Projects, swap the bundled `analyzer/` for a GH-Projects equivalent; this playbook is
unchanged.

## Disable

Set `status: inactive` here (or in a vault override at
`$CEO_VAULT/CEO/playbooks/story-points.md`) and re-scan on ML-1.
