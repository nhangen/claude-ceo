---
name: workload-report
description: Twice-weekly Zenhub team workload report — current sprint, next sprint, other, by assignee and pipeline with story-point totals
trigger: cron
schedule: "0 7 * * 1,3"
preflight: none
tier: read
status: disabled
runner: skill
skill: workload-report
out_pattern: CEO/reports/workload/${TODAY}-${HOSTNAME}.md
requires: [ZENHUB_TOKEN, ZENHUB_WORKSPACE_ID]
---

# Workload Report

> ⚠ **Non-functional since 2026-06-29.** This playbook reads from ZenHub (see
> `requires: [ZENHUB_TOKEN, ZENHUB_WORKSPACE_ID]`), which was retired that day.
> The underlying skill was **not** migrated to GitHub Projects (unlike
> `story-points`), so it produces no usable report. **Disabled 2026-07-08**
> (`status: disabled`) so the scheduler stops firing a job that can only fail.
> To restore it, migrate the skill to GitHub Projects (mirror `story-points`'s
> `ghp-estimates.js` pattern) and flip `status` back to `active`. Applying the
> disable requires `ceo playbook scan` **on ML-1** (per `ceo-scan-only-on-ml1`);
> until then the installed scheduler line lingers on hosts that already scanned.

Skill-backed playbook. The dispatcher invokes the `workload-report` skill directly via `runner: skill` — no LLM call.

## What it does

Runs the `workload-report` Claude Code skill and lands the markdown report at:

```
CEO/reports/workload/<YYYY-MM-DD>-<host>.md
```

Each fire writes a fresh dated snapshot so trends across sprints stay diffable. The skill itself queries Zenhub GraphQL + GitHub: per-assignee, per-pipeline counts and story-point totals, bucketed into Current Sprint / Next Sprint / Other.

No inbox line. Workload is reference material, not a `- [ ]` task — surfaced via `ceo report` or direct file open.

## Schedule

Monday and Wednesday, 07:00 local. Monday seeds the week's starting picture post-weekend; Wednesday is a mid-sprint pulse before the typical Thursday/Friday sprint flip.

## Install

Add the following keys to `~/.config/ceo/credentials.env`:

- `ZENHUB_TOKEN`: Zenhub API token (create at app.zenhub.com).
- `ZENHUB_WORKSPACE_ID`: Your target Zenhub Workspace ID.

(The skill will still opportunistically read `~/.claude.json` or `~/.cursor/mcp.json` if run manually, but CEO strictly requires these in `credentials.env`.)

## Verify

To verify credentials and execution in read-only mode:

```bash
ceo cron workload-report
```

## Output retention

Files accumulate forever by design — explicitly chose history over overwrite for trend analysis. Add a retention sweep later if `CEO/reports/workload/` gets unwieldy.

## Troubleshooting

- **No output or empty report:** check `cron-stderr.log` for the skill's stderr. Common cause: `~/.cursor/mcp.json` missing or `ZENHUB_TOKEN` resolved to the literal string `"null"`.
- **`WARN: no assignee rows`:** auth succeeded but Zenhub returned zero items — likely a wrong `ZENHUB_WORKSPACE_ID` or the gh user has no access to the workspace.
- **Wrong host in filename:** `CEO_HOSTNAME` overrides `hostname -s` if set.

## Disable

Set `status: inactive` in this frontmatter or remove the file, then re-run `ceo playbook scan`.
