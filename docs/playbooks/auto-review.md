---
name: auto-review
description: Scan team PRs, dispatch 2-round review pipeline, write drafts to Obsidian
trigger: cron
schedule: "17 9,13 * * 1-5"
model: sonnet
preflight: has_auto_review_prs
tier: read
status: draft
---

# Auto PR Review

Scan all team repos for qualifying PRs, run the 2-round review pipeline (Agent A verify + Agent B independent + expert panel), write actionable drafts to Obsidian. Never posts comments — that's a separate interactive action.

## Steps

1. Read `CEO/TRAINING.md` and `CEO/training/pr-review.md` for review rules.

2. The preflight has already run `scan-prs.sh` and saved the qualifying PR JSON to `/tmp/auto-review-scan.json`. Read it now to confirm there is work:

   ```bash
   QUALIFYING=$(jq 'length' /tmp/auto-review-scan.json)
   ```

   If `$QUALIFYING == 0`, log "no qualifying PRs" and exit (this should never happen — preflight gates on > 0).

3. **Invoke the `/auto-review` skill** with mode `process-prefetched`:
   - The skill should NOT re-scan; it should read `/tmp/auto-review-scan.json` directly
   - For each qualifying PR, run the 2-round pipeline: Agent A (verify existing review comments), Agent B (independent review), Expert panel (reconcile)
   - Write the consolidated report to `~/Documents/Obsidian/Awesome Motive/reviews/<date>-<HHMM>-auto-review.md`
   - Update `~/.config/auto-review/reviewed.json`

4. After the skill completes, output the LOG_ENTRY summary:

   ```
   **Auto Review:**
   - Scanned: N PRs across M repos
   - Qualifying: N
   - Reviewed: N
   - Skipped: N
   - Report: <path>
   - PRs needing your action: <list of repo#number with recommendation>
   ```

5. If any PR has recommendation `Changes requested` or unresolved decisions, note it as a suggested follow-up — the human acts on the draft via "show me the draft for PR #NNN" in a separate session.

## Constraints

- **Read-only tier.** This playbook NEVER posts comments, approves, or modifies any PR. All it does is write a Markdown file to Obsidian and update a local JSON state file.
- The skill handles all the AI work (agent dispatch, synthesis). The playbook is a thin wrapper.
- Never run `gh` directly — the skill does it.
- If the skill fails or times out on a single PR, that PR is added to the skipped list with a reason. Other PRs continue.
- No Slack, email, or external notifications. The Obsidian write is the only output.

## Token Budget

- Preflight scan: 0 AI tokens (pure shell).
- Per qualifying PR: ~50-100k tokens (Agent A + Agent B + 3 experts + synthesis).
- Typical run with 2-3 qualifying PRs: ~200-300k tokens.
- High-water mark with 5+ PRs: ~500k+ tokens — log a warning and consider extending the cron interval.

## Failure Modes

- **`gh auth` failed:** Preflight returns no-work. Log "scan-prs.sh exit 2: auth failure" and skip.
- **Zero qualifying PRs:** Preflight returns no-work. No log entry needed (already common).
- **Skill error mid-run:** Some PRs may be partially reviewed. The reviewed.json is only updated for PRs that completed successfully — others retry on next cron.
- **Obsidian vault unreachable:** Skill writes to `/tmp` as fallback and logs the alternate path.
