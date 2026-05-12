---
name: ceo-brief
description: Generate a morning briefing summarizing priorities, open PRs, pending approvals, and relevant questions. Triggers on "/ceo:brief", "morning brief", "daily brief", "what's on my plate".
version: 0.1.0
---

# CEO Brief

Generate a morning briefing and write it to the CEO execution log.

## Config

Resolve `$VAULT` using this fallback chain (first match wins):
1. Environment variable `$CEO_VAULT` (if set)
2. Obsidian plugin config: `~/.claude/plugins/cache/nhangen/obsidian/*/obsidian.local.md` → read `vault_path`
3. Default: `~/Documents/Obsidian`

If `$VAULT/CEO/AGENTS.md` does not exist, ask the user where their Obsidian vault is installed and use that path.

Resolve `$WEEKLY_MERGES_DIR` (used by Step 10):
1. If `$VAULT/CEO/AGENTS.md` defines `weekly_merges_dir:`, use that value (resolved relative to `$VAULT`).
2. Default: `$VAULT/CEO/weekly-merges/`.

Example AGENTS.md override (when the producer skill writes elsewhere, e.g. under an org subfolder):

```yaml
weekly_merges_dir: Awesome Motive/weekly-merges/
```

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

10. **Read merged-PR trend** — surface a single line summarizing the user's own weekly merged-PR activity from the `am-weekly-merges` (external producer skill) INDEX files. The producer counts **PRs authored by its configured `gh` user that landed during the window** — not PRs merged on others' behalf, not tickets, not reviews. Render the line as first-person ("My merged PRs ...") to reflect that scope.

    **10a. Compute `<current-quarter>`** from today's UTC date as `YYYY-QN` (Q1=Jan–Mar, Q2=Apr–Jun, Q3=Jul–Sep, Q4=Oct–Dec). UTC is required so the value matches the `generated` timestamp in INDEX frontmatter. If current is Q1, the previous quarter is `(YYYY-1)-Q4`.

    **10b. INDEX frontmatter contract** (consumed fields; the producer is the external `am-weekly-merges` skill, no in-repo schema doc):
    - `latest_week` (string, ISO week e.g. `2026-W20`, or the literal string `none` for an empty quarter)
    - `latest_count` (int)
    - `rolling_avg_4w` (float)
    - `rolling_avg_n` (int, 0–4)

    **10c. Read INDEX files.** Let `CURRENT=$WEEKLY_MERGES_DIR/INDEX-<current-quarter>.md` and `PREVIOUS=$WEEKLY_MERGES_DIR/INDEX-<previous-quarter>.md`. Extract fields with `yq` (do not eyeball the YAML — extraction must be deterministic):
    ```bash
    yq -r '.latest_week'    "$CURRENT"
    yq -r '.latest_count'   "$CURRENT"
    yq -r '.rolling_avg_4w' "$CURRENT"
    yq -r '.rolling_avg_n'  "$CURRENT"
    ```
    Read `PREVIOUS` only when `CURRENT`'s `rolling_avg_n < 4`.

    **10d. Merge rule.** `latest_week` and `latest_count` always come from `CURRENT`. When `CURRENT.rolling_avg_n < 4` and `PREVIOUS` exists, replace `rolling_avg_4w` and `rolling_avg_n` with the values from `PREVIOUS` (these reflect a longer trailing window).

    **10e. Skip / diagnostic guards** (mirror the `if file exists` shape used in steps 8–9):
    - If neither `CURRENT` nor `PREVIOUS` exists: skip the line entirely.
    - If `CURRENT` exists with `latest_week == "none"` AND `PREVIOUS` is absent or also `latest_week == "none"`: skip the line.
    - If `yq` fails to parse either file's frontmatter: emit a muted diagnostic line instead of silent-skip — `My merged PRs: (index frontmatter unreadable for <file>)`. A stalled producer cron must be distinguishable from a genuine no-merges week.

    **10f. Render** the merged line (single template, no `==4` special case):
    `My merged PRs (last week, {latest_week}): {latest_count} — {rolling_avg_n}wk avg {rolling_avg_4w}`

11. **Write brief** — create or append to `$VAULT/CEO/log/YYYY-MM-DD.md`:

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

12. **Present brief to user** — print the brief to terminal. Do not write to the daily note directly.

## Constraints

- Max 10 bullet points in the brief
- Do not execute any actions — this is read-only
- If `gh` is unavailable, skip PR scan and note "GitHub CLI unavailable"
- Step 10 requires `yq` (`brew install yq` on macOS; not preinstalled). If `yq` is unavailable, skip Step 10 and note "yq unavailable — merged-PR trend skipped" in the brief.
