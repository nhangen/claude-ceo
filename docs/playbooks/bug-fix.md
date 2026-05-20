---
name: bug-fix
description: Investigate and fix a reported bug following structured workflow
trigger: both
model: opus
preflight: none
tier: low-stakes write
status: active
---

# Bug Fix

Investigate and fix a bug in a repo. Delegated via /ceo:delegate.

## Input

A bug description — either a GitHub issue number, a PR with failing tests, or a free-text description.

## Steps

1. Read CEO/TRAINING.md and CEO/training/repos.md for repo-specific rules.
2. **Identify the repo** — parse the issue/PR reference or ask if unclear.
3. **Clone if needed** — if the repo isn't cloned:
   ```bash
   git clone git@github.com:<org>/<repo>.git ~/repos/<org>/<repo>
   ```
   Add entry to CEO/repos.md.
4. **Create a worktree** — from the repo:
   ```bash
   git fetch origin master
   git worktree add ../repo-<slug> -b ceo/bug/<issue>-<short-desc> origin/master
   ```
5. **Read the issue/PR** — gather context:
   ```bash
   gh issue view <number> --json title,body,labels,comments
   ```

6. **Dispatch Implementer** — delegate the investigation and fix to an Implementer subagent (vault-mediated):
   - Task: "Fix <bug description> in <org>/<repo>. Issue: #<number>."
   - Context: issue body from step 5, repo path, CEO/training/repos.md, worktree path from step 4
   - The Implementer will return: status, fix summary, files changed, test results, commit hash, recommendations

7. **Review the result** — read the Implementer's output.
   - If STATUS is "completed": proceed to propose push + PR
   - If STATUS is "failed" or "needs-help": log the failure, escalate to Nathan
   - If tests failed: do NOT proceed. Log and stop.

8. **Propose push + PR** — pushing and creating a PR are high-stakes actions. Write to CEO/approvals/pending.md:
    ```
    - [ ] **Push and create PR for bug fix**
      - repo: <org>/<repo>
      - branch: ceo/bug/<issue>-<short-desc>
      - playbook: bug-fix
      - reasoning: <what the fix does, test results>
    ```
9. **Log result** — append to CEO/log/YYYY-MM-DD.md.

## Constraints

- Do NOT push code or create PRs — those are high-stakes. Always write a proposal.
- If the fix is too complex or touches too many files, escalate to the user.
- If tests fail after the fix, log the failure and stop — do not push broken code.
