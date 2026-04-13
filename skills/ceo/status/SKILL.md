---
name: ceo-status
description: Show CEO agent status — pending approvals, recent log entries, blocked items. Triggers on "/ceo:status", "ceo status", "what has the ceo done", "pending approvals".
version: 0.1.0
---

# CEO Status

Show what the CEO has done, what's pending approval, and what's blocked.

## Config

Read vault path from the obsidian plugin config: `~/.claude/plugins/cache/nhangen/obsidian/*/obsidian.local.md`

Set `$VAULT` to the vault_path value.

## Steps

1. **Read CEO identity** — read `$VAULT/CEO/AGENTS.md` and `$VAULT/CEO/IDENTITY.md` (first 20 lines of each for context).

2. **Check pending approvals** — read `$VAULT/CEO/approvals/pending.md`.
   - Count items: total, approved (`[x]`), pending (`[ ]`)
   - List each pending item with its description

3. **Read today's log** — read `$VAULT/CEO/log/YYYY-MM-DD.md` (today's date).
   - If it exists, summarize: how many actions, any errors, any audibles
   - If it doesn't exist, say "No CEO activity logged today."

4. **Read yesterday's log** — read `$VAULT/CEO/log/` for yesterday's date.
   - Brief summary of yesterday's activity if it exists.

5. **Check for errors** — scan today's and yesterday's logs for entries with `**Status:** failed` or `**Errors:**` sections.
   - Surface any unresolved errors.

6. **Present status report**:
   ```
   ## CEO Status
   
   ### Pending Approvals (N items)
   - [ ] Merge PR #6980 — awaiting your approval
   - [x] Push branch nh/bug/7001 — approved, will execute next cycle
   
   ### Today's Activity
   - 08:57 morning-brief: completed (3 PRs found, brief written)
   - 10:03 pr-triage: completed (no new PRs needing review)
   
   ### Errors
   - None
   
   ### Pending Questions (from Pending.md)
   - What is Slava's exact title at OM?
   ```
