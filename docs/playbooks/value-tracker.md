---
name: value-tracker
description: Daily MCP tool-call value report — analyses Claude Code + Cursor sessions for used vs wasted tool calls
trigger: cron
schedule: "0 6 * * 1-5"
preflight: none
tier: read
status: active
runner: script
script: ceo-value-tracker.sh
artifact: CEO/reports/value-tracker/{TODAY}.md
---

# Value Tracker

Shell-only playbook. The dispatcher invokes `scripts/ceo-value-tracker.sh` directly — no LLM call.

## What it does

Runs `lib/value-tracker` against the last 24h of Claude Code session JSONLs and Cursor SQLite tool bubbles, classifies each MCP tool call as plausibly-used, trivially-wasted, or unclear, and writes:

- `<VAULT>/CEO/reports/value-tracker/<TODAY>.md` — the report (sanctioned `reports/` location per `ceo-automated-writers-are-playbooks`)
- A JSON snapshot under the tracker's default snapshot dir
- One idempotent line in `CEO/inbox/<host>.md`:

```
- [ ] Review daily value-tracker report [[CEO/reports/value-tracker/<TODAY>]]
```

The chat-triggered `inbox` playbook surfaces the line via `ceo chat inbox`.

## Why daily, not weekly

Daily cron means tool-use drift surfaces inside one work-cycle; a weekly digest becomes wallpaper. The inbox line keeps it visible without requiring you to open the vault.

## Install

Registered automatically by `ceo playbook scan`. Requires `bun` on PATH (resolved via `command -v` at runtime; the script aborts cleanly if missing).

## Disable

Set `status: inactive` in this file (or in a vault override at `$CEO_VAULT/CEO/playbooks/value-tracker.md`) and re-scan.

## Source

The analyser lives at `lib/value-tracker/` — TypeScript + Bun, 50 unit tests. See `lib/value-tracker/README.md` for the engine layout. The directory keeps a clean boundary (no ceo imports) so it can be extracted to a standalone CLI later if the use case grows beyond personal analytics.
