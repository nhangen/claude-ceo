---
name: morning-scan
description: Scan vault for overnight changes, new notes, unresolved items, carryover
trigger: cron
schedule: "50 8 * * 1-5"
runner: ollama
model: gemma4:12b-it-qat
preflight: none
tier: read
status: disabled
---

# Morning Scan

Read everything that changed since your last scan. Understand the full picture. Present findings by urgency:

- **Needs decision** — new items requiring Nathan's input
- **Needs attention** — items aging or approaching deadlines
- **FYI** — status updates on known items, no action needed

For repeat items (things you've surfaced before that haven't been addressed), mention them briefly under FYI unless their urgency has escalated. Don't nag.

If today's daily note has no priorities set, note that for the triage conversation.
If there are carryover items from yesterday, cross-reference them against today's data (e.g., open PR counts). Do not surface resolved items (like a PR that is no longer in the open list) as carryover. Only flag items that are verifiably still unresolved and relevant.

## Data Available

The shell has pre-gathered the following data and injected it into your prompt. Do not re-fetch any of this.

- Vault file changes since last scan (grouped by domain). Excludes `CEO/log/`, `CEO/reports/`, `CEO/alerts/`, and `CEO/inbox/` — those have dedicated surfacing rules below.
- Yesterday's daily note (full content)
- Today's daily note (full content)
- Pending questions (from Pending.md)
- Pending approvals (unchecked items)
- Yesterday's CEO report (full content, including any carryover)
- Failed actions from yesterday
- PR counts and details (from ceo-gather.sh)
- **Currently firing alerts** (`ALERTS_FIRING`) — list of monitor state files in `CEO/alerts/` with `status: firing`, plus host and `since:` timestamp. Surface these under **Needs attention** with the firing duration; do not surface clear alerts.

## Output rules for alerts

- **First firing** (since < 24h ago): surface under FYI with the alert name and host.
- **Sustained firing** (since >= 24h ago): surface under Needs attention; the responsible playbook will have already appended a `- [ ]` task to `CEO/inbox/<host>.md`, so flag that the inbox has the action.
- Do not surface clear alerts. Do not surface state-file mutations as generic vault changes.

## Output

Write your findings as the content for an [intake] report entry. The shell will write it to the daily report file. Focus on what Nathan needs to know, not on being comprehensive.
