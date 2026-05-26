---
name: pending-drip
description: Check pending approvals and surface items needing attention
trigger: cron
schedule: "33 9 * * *"
model: haiku
preflight: has_pending_items
tier: read
status: active
---

# Pending Drip

Surface 1-2 outstanding `- [ ]` questions from Pending.md, matched to the current context.

## Steps

1. Read CEO/TRAINING.md and CEO/training/communication.md for communication rules.
2. Read Profile.md Active Domains to determine priority domains.
3. Read Pending.md - scan all outstanding `- [ ]` entries.
4. Match entries to today's likely focus:
   - If today's daily note has a Top 3, match pending questions to those domains.
   - If no daily note, use the highest-priority domain from Profile.md.
5. Pick 1-2 relevant questions. Prefer questions that:
   - Relate to active work (same domain as today's focus)
   - Are quick to answer (role, title, date - not essay questions)
   - Haven't been surfaced recently (check CEO/log/ for last 3 days)
6. Output in the LOG_ENTRY Output section. For `pending-drip`, the shell will turn this into one unchecked item in `CEO/inbox/<host>.md` instead of appending it to the daily CEO report:
   ```
   **Questions to ask Nathan:**
   - [from People/slava.md] What is Slava's exact title at OM?
   - [from Profile.md] Expected MS graduation date?
   ```

## Constraints

- Read-only. Do not answer questions or modify Pending.md.
- Max 2 questions per drip. Don't overwhelm.
- If no questions match the current context, log "No relevant pending questions today" and stop.
- Write only the questions Nathan should answer; the cron wrapper owns the inbox append.
