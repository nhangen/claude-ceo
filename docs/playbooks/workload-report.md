---
name: workload-report
description: Twice-weekly Zenhub team workload report — current sprint, next sprint, other, by assignee and pipeline with story-point totals
trigger: cron
schedule: "0 7 * * 1,3"
preflight: none
tier: read
status: active
runner: script
script: ceo-workload-report.sh
---

# Workload Report

Shell-only playbook. The dispatcher invokes `scripts/ceo-workload-report.sh` directly — no LLM call.

## What it does

Runs the `workload-report` Claude Code skill (`~/.claude/skills/workload-report/scripts/run-report.sh`) and lands the markdown report at:

```
CEO/reports/workload/<YYYY-MM-DD>-<host>.md
```

Each fire writes a fresh dated snapshot so trends across sprints stay diffable. The skill itself queries Zenhub GraphQL + GitHub: per-assignee, per-pipeline counts and story-point totals, bucketed into Current Sprint / Next Sprint / Other.

No inbox line. Workload is reference material, not a `- [ ]` task — surfaced via `ceo report` or direct file open.

## Schedule

Monday and Wednesday, 07:00 local. Monday seeds the week's starting picture post-weekend; Wednesday is a mid-sprint pulse before the typical Thursday/Friday sprint flip.

## Credentials

Resolved at runtime from the user's environment:

- `GITHUB_TOKEN` ← `gh auth token`
- `ZENHUB_TOKEN` + `ZENHUB_WORKSPACE_ID` ← `~/.cursor/mcp.json` (Zenhub MCP config)

Both are user-scoped — the playbook is host-local (Mac), not portable to ML-1 unless those credentials are mirrored.

## Install

Registered automatically by `ceo playbook scan`. Cron entries for repo playbooks bake in `$INSTALL_DIR` at scan time. If the claude-ceo repo moves (re-clone, worktree shuffle), re-run `ceo playbook scan` to refresh the crontab.

## Output retention

Files accumulate forever by design — explicitly chose history over overwrite for trend analysis. Add a retention sweep later if `CEO/reports/workload/` gets unwieldy.

## Troubleshooting

- **No output or empty report:** check `cron-stderr.log` for the skill's stderr. Common cause: `~/.cursor/mcp.json` missing or `ZENHUB_TOKEN` resolved to the literal string `"null"`.
- **`WARN: no assignee rows`:** auth succeeded but Zenhub returned zero items — likely a wrong `ZENHUB_WORKSPACE_ID` or the gh user has no access to the workspace.
- **Wrong host in filename:** `CEO_HOSTNAME` overrides `hostname -s` if set.

## Disable

Set `status: inactive` in this frontmatter or remove the file, then re-run `ceo playbook scan`.
