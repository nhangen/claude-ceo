---
name: token-intake
description: Daily RTK + token-scope spend intake — drops one inbox item linking to today's report
trigger: cron
schedule: "45 8 * * 1-5"
preflight: none
tier: read
status: active
runner: script
script: ceo-token-intake.sh
artifact: CEO/reports/token/{TODAY}-{HOST}.md
---

# Token Intake

Shell-only playbook. The dispatcher invokes `scripts/ceo-token-intake.sh` directly — no LLM call.

## What it does

Captures four command outputs into `CEO/reports/token/<TODAY>.md`:

- `rtk gain` — global RTK savings
- `rtk gain -p` — RTK savings scoped to current project
- `rtk cc-economics` — ccusage spend vs RTK savings
- `token-scope --since 1d` — Claude Code spend for the last 24h

Then idempotently appends one line to `CEO/inbox.md`:

```
- [ ] Review daily token report [[CEO/reports/token/<TODAY>]]
```

The chat-triggered `inbox` playbook picks the line up next time `ceo chat inbox` runs.

## Install

Registered automatically by `ceo playbook scan`. Repo playbooks under `docs/playbooks/` are picked up alongside vault playbooks; a vault playbook with the same `name` shadows the repo copy.

Note: cron entries for repo playbooks bake in `$INSTALL_DIR` at scan time. If the repo moves (re-clone, worktree shuffle), re-run `ceo playbook scan` to refresh the crontab.

## Disable

Set `status: inactive` in this file (or in a vault override at `$CEO_VAULT/CEO/playbooks/token-intake.md`) and re-scan.
