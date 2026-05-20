---
name: morning-brief
description: Generate a prioritized overview of the day's work
trigger: cron
schedule: "57 8 * * 1-5"
model: sonnet
preflight: none
tier: read
status: active
---

# Morning Brief

Generate a prioritized overview of the day's work.

## Steps

**This playbook is fully pre-gathered. Do NOT call Read, Grep, or Glob.**
Every input below is already injected into the prompt by the shell. Synthesize the brief from those values; the cap is `--max-turns 5` and tool calls burn turns.

1. Apply the briefing-specific rules from `<external-data>` `Briefing-specific training`.
2. Use the priority order in `<external-data>` `Active Domains priority order`.
3. Use pre-gathered PR data: `PR_REVIEW_COUNT`, `PR_AUTHORED_COUNT`, `PR_REVIEW_REQUESTED`, `PR_AUTHORED`.
4. Use `Pending approvals: N pending` from PRE-GATHERED DATA for the outstanding count.
5. Pick 1–2 questions from `<external-data>` `Pending [ask] questions` relevant to today's likely focus domain.
6. Use `Yesterday's log summary` for carryover items.
7. Use `Daily note Top 3` and `Daily note Tasks` if non-empty.
8. Output the brief in the LOG_ENTRY Output section — the shell will write it to CEO/log/YYYY-MM-DD.md.

## Output Format

Max 10 bullet points:
- Open PR count and oldest PR age
- PRs needing your review (count + list top 3)
- Pending approvals count
- Top 3 priorities (from daily note or inferred from PR urgency + domain priority)
- 1-2 questions from Pending.md if relevant to today's focus
- Carryover items from yesterday

Then append a Personal section sourced from the `<external-data>` `Blessings today:` field. If the field is empty, omit the entire section.

## Personal

### Blessings
<reproduce each bullet from `Blessings today:` verbatim>

_Add one?_ Run `count-blessings add "your blessing"` from a terminal.

## Constraints

- This is a read-only playbook. Do not execute any write actions.
- All GitHub data comes from pre-gathered shell variables — never run `gh` directly.
