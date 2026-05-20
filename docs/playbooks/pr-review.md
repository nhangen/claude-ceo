---
name: pr-review
description: Review a specific PR — read diff, analyze changes, draft review
trigger: both
model: opus
preflight: none
tier: low-stakes write
status: active
---

# PR Review

Review a pull request: read the diff, check tests, post a review comment.

## Input

A PR identifier — either a number (#6980) or a full repo reference (org/repo#6980).

## Steps

1. **Identify the repo** — parse the PR reference. If no repo specified, check CEO/repos.md for recently used repos, or ask.

2. **Clone if needed** — if the repo isn't cloned on this machine:
   - `git clone git@github.com:<org>/<repo>.git ~/repos/<org>/<repo>`
   - Add entry to CEO/repos.md

3. **Checkout PR** — from the repo directory:
   ```bash
   gh pr checkout <number>
   ```

4. **Read the PR** — gather context:
   ```bash
   gh pr view <number> --json title,body,labels,reviewRequests,statusCheckRollup
   gh pr diff <number>
   ```

5. **Read training** — read CEO/TRAINING.md for general rules, then CEO/training/pr-review.md for review-specific rules.

6. **Dispatch Code Reviewer** — delegate the review analysis to a Code Reviewer subagent (vault-mediated):
   - Task: "Review PR #<number> in <org>/<repo>. PR title: <title>."
   - Context: the PR diff output from step 4, CEO/training/pr-review.md, CI status
   - The Code Reviewer will return: verdict, summary, issues, draft review body

7. **Review the draft** — read the Code Reviewer's result.
   - In interactive mode: present the draft to Nathan for approval/editing
   - In cron mode: write to CEO/approvals/pending.md with the draft body (all review posting is high-stakes)

8. **Log result** — append to CEO/log/YYYY-MM-DD.md:
    ```markdown
    ## HH:MM — pr-review

    **Status:** completed
    **Playbook:** playbooks/pr-review.md
    **PR:** <org>/<repo>#<number> — <title>
    **Verdict:** approved | requested changes | commented
    **Actions:**
    - Cloned <repo> (if applicable)
    - Posted review comment
    ```

## Constraints

- Do NOT merge the PR — that's a high-stakes action. If the PR should be merged, write a proposal to CEO/approvals/pending.md.
- Do NOT push any code changes — review only.
- If the PR is too large or complex to review confidently, say so and escalate to the user.
