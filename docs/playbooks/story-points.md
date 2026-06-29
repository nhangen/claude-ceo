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

`requires: [GH_PROJECT_TOKEN]` — ceo-cron sources `~/.config/ceo/credentials.env` and the
`requires:` credential gate (distinct from the `preflight:` function, which is `none`)
aborts the run with a non-zero exit before exec if it is unset. `GH_PROJECT_TOKEN` must
carry the `project` scope: story points are read from the org GitHub Projects boards
(projects 72–75), not ZenHub.

GitHub PR/issue auth uses a separate `GITHUB_TOKEN`, resolved by the skill from env or
`gh auth token -u nhangenam` (awesomemotive org access). **`GITHUB_TOKEN` is not in
`requires:`, so cron does not pre-validate it** — for unattended ML-1 runs put it in
`~/.config/ceo/credentials.env` (or have `gh` logged in as `nhangenam`), or the skill
aborts at its own token guard. A `GH_PROJECT_TOKEN` that is present but lacks `project`
scope does not silently pass: the skill's all-zero trip-wire exits 3 and writes no report
rather than emitting a zeroed one.

## Outputs

| File | Mode | When |
|---|---|---|
| `Awesome Motive/reports/story-points/${TODAY}-backlog-pr-story-points.md` | create | Every Friday 17:00 |

The quarter is recorded in the report body and frontmatter tags (the `out_pattern`
filename carries the date, not the quarter).

A successful run writes exactly one `${TODAY}-backlog-pr-story-points.md`. If that file is
absent after 17:00 Friday, the run failed — analyzer error (exit 1) or the all-zero / scope
trip-wire (exit 3), which writes no file. Check the ceo-cron run log for the non-zero exit
and stderr.

## Install

Run `ceo playbook scan` **on ML-1 only** (the `ceo-scan-only-on-ml1` rule). The skill
lives in llm-tools at `home/.claude/skills/story-points/`; ML-1 must have that pulled.

## ZenHub → GitHub Projects migration (complete)

The ZenHub cutover is done: the bundled `analyzer/` reads story points from the org
GitHub Projects boards (projects 72–75) via `ghp-estimates.js`. The playbook contract is
unchanged apart from `requires:` (now `GH_PROJECT_TOKEN` instead of the ZenHub vars).
Before the next `ceo playbook scan` on ML-1, add `GH_PROJECT_TOKEN` (project scope) to
ML-1's `~/.config/ceo/credentials.env` or the `requires:` credential gate will fail the run.

## Disable

Set `status: inactive` here (or in a vault override at
`$CEO_VAULT/CEO/playbooks/story-points.md`) and re-scan on ML-1.
