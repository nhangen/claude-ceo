---
name: ceo-log
description: Show the CEO's execution log for today or a specified date. Triggers on "/ceo:log", "what did the ceo do", "show ceo log", "ceo activity".
version: 0.1.0
---

# CEO Log

Display the CEO's execution log entries.

## Config

Read vault path from the obsidian plugin config: `~/.claude/plugins/cache/nhangen/obsidian/*/obsidian.local.md`

Set `$VAULT` to the vault_path value.

## Arguments

Optional date argument:
- `/ceo:log` — show today's log
- `/ceo:log yesterday` — show yesterday's log
- `/ceo:log 2026-04-10` — show a specific date's log

## Steps

1. **Determine date** — parse the argument. Default to today (YYYY-MM-DD format).

2. **Read log file** — read `$VAULT/CEO/log/YYYY-MM-DD.md`.
   - If the file doesn't exist, say "No CEO activity logged for YYYY-MM-DD."

3. **Present log** — print the full log content to terminal. If long, summarize:
   - Total actions count
   - Completed / failed / partial breakdown
   - Any audibles (deviations from playbooks)
   - Any errors

4. **Offer navigation** — "Want to see a different date? Or check `/ceo:status` for the full overview."
