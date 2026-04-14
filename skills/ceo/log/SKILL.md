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

1. **Run the log script** — execute the shell script that handles all log display:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/ceo-log.sh" <date-argument>
   ```
   - No argument or "today" → today's log
   - "yesterday" → yesterday's log
   - "2026-04-10" → specific date

2. **If the user asks for analysis** — only then use AI judgment to summarize patterns, trends, or recommendations from the log output. Otherwise, the shell script output is sufficient.
