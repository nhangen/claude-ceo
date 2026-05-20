---
name: cleanup
description: Clean merged branches, detect orphans, resolve sync conflicts
trigger: cron
schedule: "7 3 * * 0"
model: haiku
preflight: has_ceo_branches
tier: low-stakes write
status: active
---

# Cleanup

Weekly maintenance: clean up branches, worktrees, and review CEO log history.

## Steps

1. Read CEO/TRAINING.md and CEO/training/repos.md for repo-specific rules.
2. **Run cleanup script** — execute the shell script that handles all deterministic cleanup:
   ```bash
   bash <plugin-path>/scripts/ceo-cleanup.sh
   ```
   The script:
   - Reads CEO/repos.md for cloned repos
   - Lists CEO branches and worktrees per repo
   - Removes merged branches and their worktrees automatically
   - Identifies orphaned branches (no PR, >7 days old)
   - Counts sync conflict files
   - Counts old log files (>30 days)
   - Reports whether AI judgment is needed

3. **If AI_NEEDED: yes** — review the orphaned branches listed in ORPHAN_SUMMARY. For each:
   - If the branch name suggests abandoned work, propose deletion in CEO/approvals/pending.md
   - If the branch might have unsaved work, log it as "needs review" but do not propose deletion

4. **If sync conflicts found** — log them as errors. These indicate Syncthing write-domain violations.

5. **Output cleanup summary** in the LOG_ENTRY Output section — the shell will write it to CEO/log/YYYY-MM-DD.md:
   ```
   - N worktrees removed (merged)
   - N orphaned branches found (N proposals written)
   - N sync conflicts detected
   - N log files older than 30 days
   ```

## Constraints

- Do NOT delete remote branches — that's high-stakes. Only clean up local branches and worktrees.
- Do NOT delete log files — only report age.
- Propose remote branch deletion via CEO/approvals/pending.md if needed.
