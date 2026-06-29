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
requires: [GH_PROJECT_TOKEN]
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

`requires: [GH_PROJECT_TOKEN]` — ceo-cron sources `~/.config/ceo/credentials.env` and
validates it is set before exec. `GH_PROJECT_TOKEN` must carry the `project` scope: story
points are read from the org GitHub Projects boards (projects 72–75), not ZenHub. GitHub
PR/issue auth is resolved by the skill via `gh auth token -u nhangenam` (awesomemotive org
access); if that token already has `project` scope, the skill falls back to it for the
board read, but the playbook requires an explicit `GH_PROJECT_TOKEN` for unattended runs.

## Outputs

| File | Mode | When |
|---|---|---|
| `Awesome Motive/reports/story-points/${TODAY}-backlog-pr-story-points.md` | create | Every Friday 17:00 |

The quarter is recorded in the report body and frontmatter tags (the `out_pattern`
filename carries the date, not the quarter).

## Install

Run `ceo playbook scan` **on ML-1 only** (the `ceo-scan-only-on-ml1` rule). The skill
lives in llm-tools at `home/.claude/skills/story-points/`; ML-1 must have that pulled.

## ZenHub → GitHub Projects migration (complete)

The ZenHub cutover is done: the bundled `analyzer/` reads story points from the org
GitHub Projects boards (projects 72–75) via `ghp-estimates.js`. The playbook contract is
unchanged apart from `requires:` (now `GH_PROJECT_TOKEN` instead of the ZenHub vars).
Before the next `ceo playbook scan` on ML-1, add `GH_PROJECT_TOKEN` (project scope) to
ML-1's `~/.config/ceo/credentials.env` or the preflight will fail.

## Disable

Set `status: inactive` here (or in a vault override at
`$CEO_VAULT/CEO/playbooks/story-points.md`) and re-scan on ML-1.
