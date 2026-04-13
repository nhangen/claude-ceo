---
name: ceo-brief
description: Generate a morning briefing summarizing priorities, open PRs, pending approvals, and relevant questions. Triggers on "/ceo:brief", "morning brief", "daily brief", "what's on my plate".
version: 0.1.0
---

# CEO Brief

Generate a morning briefing and write it to the CEO execution log.

## Config

Read vault path from the obsidian plugin config: `~/.claude/plugins/cache/nhangen/obsidian/*/obsidian.local.md`

Set `$VAULT` to the vault_path value.

## Steps

1. **Read global agent rules** — read `$VAULT/CEO/AGENTS.md`.

2. **Read CEO identity** — read `$VAULT/CEO/IDENTITY.md`.

3. **Read training** — read `$VAULT/CEO/TRAINING.md` and `$VAULT/CEO/training/briefings.md` if it exists.

4. **Read user profile** — read `$VAULT/Profile.md` Active Domains for priority order.

5. **Scan open PRs** — read `$VAULT/CEO/repos.md` for known repos. For each repo (and as a global fallback):
   ```bash
   gh pr list --state open --search "review-requested:@me" --repo <org>/<repo> --limit 10
   gh pr list --state open --author @me --repo <org>/<repo> --limit 10
   ```
   If repos.md is empty, run without `--repo` flag (searches across all accessible repos).
   Note: PR count, oldest PR age, any with failing CI.

6. **Check pending approvals** — read `$VAULT/CEO/approvals/pending.md`. Count outstanding items.

7. **Check pending questions** — read `$VAULT/Pending.md`. Pick 1-2 questions relevant to the day's likely focus domain.

8. **Read yesterday's log** — if `$VAULT/CEO/log/` has yesterday's file, read the EOD summary for carryover items.

9. **Read today's daily note** — if `$VAULT/Daily/YYYY-MM-DD.md` exists, read Top 3 and Tasks sections.

10. **Write brief** — create or append to `$VAULT/CEO/log/YYYY-MM-DD.md`:

    ```markdown
    ## HH:MM — morning-brief

    **Status:** completed
    **Playbook:** playbooks/morning-brief.md

    ### Brief
    - **Open PRs:** N total (oldest: N days, repo/PR#)
    - **PRs needing your review:** N
    - **Pending approvals:** N items in CEO/approvals/pending.md
    - **Top priorities:**
      1. [priority from daily note or inferred]
      2. [priority]
      3. [priority]
    - **Questions:** [1-2 from Pending.md if relevant]
    ```

11. **Present brief to user** — print the brief to terminal. Do not write to the daily note directly.

## Constraints

- Max 10 bullet points in the brief
- Do not execute any actions — this is read-only
- If `gh` is unavailable, skip PR scan and note "GitHub CLI unavailable"
