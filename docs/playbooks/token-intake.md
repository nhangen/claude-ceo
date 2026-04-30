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

Copy this file into the vault, then re-scan:

```
cp docs/playbooks/token-intake.md "$CEO_VAULT/CEO/playbooks/"
ceo playbook scan
```

## Disable

Set `status: inactive` and re-scan.
