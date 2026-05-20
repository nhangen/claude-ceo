---
name: pr-triage
description: Scan open PRs and prioritize review queue
trigger: cron
schedule: "3 10 * * 1-5"
model: sonnet
preflight: has_prs_to_review
tier: read
status: active
---

# PR Triage

Scan open PRs across repos, categorize by urgency, surface stale or blocked PRs.

## Steps

1. Read CEO/TRAINING.md and CEO/training/pr-review.md for review rules.
2. Use the pre-gathered PR data injected by the shell (PR_REVIEW_REQUESTED, PR_AUTHORED — JSON arrays per repo). Do NOT run `gh` yourself — the shell already fetched this data.
3. Categorize each PR using the JSON fields available (number, title, createdAt, repository, statusCheckRollup):
   - **Urgent:** review requested from @me (any PR in PR_REVIEW_REQUESTED), or open > 7 days
   - **Needs attention:** CI failing (statusCheckRollup) or stale (createdAt > 3 days)
   - **On track:** everything else
4. Output the triage in the LOG_ENTRY Output section (the shell will write it to the log):
   ```
   **Urgent (N):**
   - repo#number — title (age, status)

   **Needs attention (N):**
   - repo#number — title (reason)

   **On track (N):**
   - repo#number — title
   ```

## Constraints

- Read-only. Do not post comments, review, or modify PRs.
- All GitHub data comes from pre-gathered shell variables — never run `gh` directly.
- If a PR is urgent and would benefit from full review, note it as a suggested delegation to pr-review.
