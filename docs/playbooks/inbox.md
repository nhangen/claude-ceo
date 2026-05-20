---
name: inbox
description: Check CEO/inbox.md for new tasks and process them
trigger: chat
model: haiku
preflight: has_unchecked_inbox
tier: read
status: active
---

# Inbox Processing

Check CEO/inbox.md for new tasks and process them.

## Steps

1. Read CEO/TRAINING.md for general rules.
2. Read CEO/inbox.md.
3. Find all unchecked items (`- [ ]`). Skip items marked `[x]` (user cancelled) or `[done]` (already processed).
4. If no unchecked items: log "inbox empty" and stop.
5. For each unchecked item, in order:
   a. Match to a playbook via CEO/SKILLS.md dispatch table (same keyword matching as /ceo:delegate).
   b. If matched: dispatch per the playbook (may involve subagent dispatch).
   c. If no match: attempt the task without a playbook using authority tiers. For read-only tasks, execute directly. For write tasks, propose in approvals/pending.md.
   d. After completion: format the item as `- [done] <task> — <brief result> (<YYYY-MM-DD>)`, remove it from `CEO/inbox.md`, and append it to `CEO/inbox-archive.md` (create a `## YYYY-MM-DD` header if it's the first item of the day).
   e. On failure: replace `- [ ]` with `- [failed] ` and append the error.
6. Output the inbox results in the LOG_ENTRY Output section — the shell will write it to CEO/log/YYYY-MM-DD.md:
   ```
   **Items processed:** N
   **Results:**
   - <task> — completed | failed | proposed
   ```

## Inbox Item Format After Processing

```markdown
- [done] Review PR #7010 in optin-monster-app — reviewed, draft posted to approvals (2026-04-15)
- [failed] Check NRX inventory — gh auth expired (2026-04-15)
- [x] Draft LinkedIn post — cancelled by user
```

## Constraints

- Process items in order (top to bottom).
- When an item is completed successfully, remove it from `CEO/inbox.md` and move it to `CEO/inbox-archive.md`. Leave `[failed]` and `[x]` items in `CEO/inbox.md` so the user sees what happened.
- Respect authority tiers. High-stakes actions from inbox items go to approvals/pending.md.
- If inbox has more than 5 unchecked items, process only the first 5 per cycle to stay within budget.
