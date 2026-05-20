---
name: eod-summary
description: End of day summary — what was done, what carries over
trigger: cron
schedule: "47 17 * * 1-5"
model: sonnet
preflight: has_log_entries_after_4pm
tier: read
status: active
---

# End of Day Summary

Summarize the day's CEO activity and carryover items.

## Steps

1. Read CEO/TRAINING.md and CEO/training/briefings.md for summary rules.
2. Read CEO/log/YYYY-MM-DD.md — gather all entries from today.
3. Read CEO/approvals/pending.md — count outstanding items.
4. Read today's daily note if it exists — check Tasks for incomplete items.
5. Output the summary in the LOG_ENTRY Output section — the shell will write it to CEO/log/YYYY-MM-DD.md:
   ```
   **Today's activity:**
   - N actions executed (N completed, N failed, N partial)
   - N proposals written to pending approvals
   - N audibles logged
   
   **Pending approvals:** N items awaiting Nathan's review
   
   **Carryover for tomorrow:**
   - [items from daily note Tasks still unchecked]
   - [any failed actions that need retry]
   - [pending questions not yet answered]
   
   **Errors:** [any unresolved errors, or "none"]
   ```

## Constraints

- Read-only. The shell handles all log writes from your LOG_ENTRY block.
- Keep the summary under 15 lines.
