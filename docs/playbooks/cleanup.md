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
   - Reports every merged branch it could NOT reap (`REAP_FAILED`)
   - Reports state it could not trust or clean up (`STALE_STATE`) — a failed
     fetch of the default branch, or an ownership marker left behind
   - Clears a worktree whose directory is gone, so the branch delete can proceed
   - Identifies orphaned branches (no PR, >7 days old)
   - Counts sync conflict files
   - Counts old log files (>30 days)
   - Reports whether AI judgment is needed

3. **If AI_NEEDED: yes** — the line names every reason, separated by `;`, and
   there may be more than one. `AI_NEEDED: yes` no longer implies an
   `ORPHAN_SUMMARY` exists, so read the reasons rather than assuming.

   - **"review orphaned branches"** — an `ORPHAN_SUMMARY` block is present. For
     each branch: if the name suggests abandoned work, propose deletion in
     CEO/approvals/pending.md; if it might hold unsaved work, log it as "needs
     review" and do not propose deletion.
   - **"merged branch(es) failed to reap"** — the branch is merged on the remote
     but `git branch -d` refused, usually because the local default branch lags
     `origin` or a worktree still holds it. Look for `BRANCH_DELETE_FAILED` and
     `WORKTREE_REMOVE_FAILED` above. Do not propose deleting these; they are a
     host-state problem, not abandoned work.
   - **"stale-state warning(s)"** — look for `FETCH_FAILED` (the merge decisions
     in this run were made against a possibly stale view of the remote) or
     `MARKER_DELETE_FAILED` (a branch was reaped but its `refs/ceo-loop/owned/*`
     marker leaked). Log both; neither is a deletion proposal.

4. **If sync conflicts found** — log them as errors. These indicate Syncthing write-domain violations.

5. **Output cleanup summary** in the LOG_ENTRY Output section — the shell will write it to CEO/log/YYYY-MM-DD.md:
   ```
   - N merged branches reaped (MERGED_TOTAL), N failed to reap (REAP_FAILED)
   - N stale-state warnings (STALE_STATE)
   - N orphaned branches found (N proposals written)
   - N sync conflicts detected
   - N log files older than 30 days
   ```

## Constraints

- Do NOT delete remote branches — that's high-stakes. Only clean up local branches and worktrees.
- Do NOT delete log files — only report age.
- Propose remote branch deletion via CEO/approvals/pending.md if needed.
