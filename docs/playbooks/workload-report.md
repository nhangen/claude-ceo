---
name: workload-report
description: Twice-weekly GitHub Projects team workload report — current sprint, next sprint, other, by assignee and Status/pipeline with story-point (Estimate) totals
trigger: cron
schedule: "0 7 * * 1,3"
preflight: none
tier: read
status: active
runner: skill
skill: workload-report
out_pattern: CEO/reports/workload/${TODAY}-${HOSTNAME}.md
---

# Workload Report

Skill-backed playbook. The dispatcher invokes the `workload-report` skill directly via `runner: skill` — no LLM call.

## What it does

Runs the `workload-report` Claude Code skill and lands the markdown report at:

```
CEO/reports/workload/<YYYY-MM-DD>-<host>.md
```

Each fire writes a fresh dated snapshot so trends across sprints stay diffable. The skill queries **GitHub Projects v2 project 80** (`awesomemotive`) — the consolidated board that replaced the retired per-product ZenHub workspaces on 2026-06-29 (covers OptinMonster, TrustPulse, and Beacon). It produces per-assignee, per-Status/pipeline counts and story-point (Estimate) totals, bucketed into Current Sprint / Next Sprint / Other by the project's iteration field.

No inbox line. Workload is reference material, not a `- [ ]` task — surfaced via `ceo report` or direct file open.

## Schedule

Monday and Wednesday, 07:00 local. Monday seeds the week's starting picture post-weekend; Wednesday is a mid-sprint pulse before the typical Thursday/Friday sprint flip.

## Install / credentials

The skill reads project 80 over the GitHub GraphQL API and needs a token with `project` scope:

- `GH_PROJECT_TOKEN` (or `GITHUB_TOKEN`) in the environment takes precedence.
- If neither is set, `run-report.sh` falls back to `gh auth token --user nhangenam` (the `nhangenam` gh token already carries `project` scope).

No ZenHub token, no `ZENHUB_WORKSPACE_ID`, no `.env` file, no ZenHub MCP — that data source was removed 2026-06-29.

## Verify

To verify credentials and execution in read-only mode:

```bash
ceo cron workload-report
```

## Output retention

Files accumulate forever by design — explicitly chose history over overwrite for trend analysis. Add a retention sweep later if `CEO/reports/workload/` gets unwieldy.

## Troubleshooting

- **No output or empty report:** check `cron-stderr.log` for the skill's stderr. Common cause: no GitHub token on PATH — set `GH_PROJECT_TOKEN`/`GITHUB_TOKEN` or run `gh auth login`.
- **Zero assignee rows:** auth succeeded but project 80 returned no items — usually the gh user lacks access to the org project, or the token is missing `project` scope.
- **Most point totals show 0:** the Estimate field is sparsely populated on project 80 (most items are unsized). Expected, not a bug.
- **Wrong host in filename:** `CEO_HOSTNAME` overrides `hostname -s` if set.

## Disable

Set `status: inactive` in this frontmatter or remove the file, then re-run `ceo playbook scan`.
