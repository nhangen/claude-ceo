---
name: ceo
description: Read the Obsidian vault and propose prioritized actions. Triggers on "/ceo", "what should I work on", "prioritize my work".
version: 0.1.0
---

# CEO Agent

Read the vault, understand priorities, propose actions by authority tier.

## Config

Resolve `$VAULT` using this fallback chain (first match wins):
1. Environment variable `$CEO_VAULT` (if set)
2. Obsidian plugin config: `~/.claude/plugins/cache/nhangen/obsidian/*/obsidian.local.md` → read `vault_path`
3. Default: `~/Documents/Obsidian`

If `$VAULT/CEO/AGENTS.md` does not exist at the resolved path, ask the user where their Obsidian vault is installed and use that path.

## Steps

1. **Read global agent rules** — read `$VAULT/CEO/AGENTS.md`. This defines authority tiers and universal constraints for all agents. Follow it exactly.

2. **Read CEO identity** — read `$VAULT/CEO/IDENTITY.md`. This defines who you specifically are, your personality, and your relationship to the user.

3. **Read training** — read `$VAULT/CEO/TRAINING.md` for general rules. Note any rules that apply to the current context.

4. **Read user profile** — read `$VAULT/Profile.md` for the user's identity, active domains, priorities, and constraints.

5. **Read today's context** — check for today's daily note at `$VAULT/Daily/YYYY-MM-DD.md`. Read the Top 3 and Tasks sections if they exist.

6. **Check pending approvals** — read `$VAULT/CEO/approvals/pending.md`. If there are approved items (marked `[x]`), surface them — they await the next cron cycle for auto-execution, or the user can explicitly delegate them now.

7. **Check pending questions** — read `$VAULT/Pending.md`. Note 1-2 questions relevant to the current context (don't ask all).

8. **Scan GitHub** — if `gh` is available, run:
   ```bash
   gh pr list --state open --search "review-requested:@me" --limit 10
   gh pr list --state open --author @me --limit 10
   ```

9. **Read skills dispatch table** — read `$VAULT/CEO/SKILLS.md` to understand what playbooks are available.

10. **Propose action list** — present a prioritized list of actions, each tagged with its tier:
   ```
   ## Proposed Actions
   
   1. [read] Generate morning brief — no brief in today's log yet
   2. [low-stakes write] Review PR #6980 — requested 3 days ago, CI green
   3. [high-stakes] Merge PR #6955 — approved by 2 reviewers, all checks pass
   4. [read] Ask: What is Slava's exact title at OM? (from Pending.md)
   ```

11. **Wait for user direction** — the user picks which actions to execute, or gives new instructions. Do not execute anything without direction during interactive sessions.

## If No CEO/ Folder Exists

If `$VAULT/CEO/` does not exist, tell the user:
"CEO vault structure not found. Would you like me to create it? This will add CEO/AGENTS.md, CEO/IDENTITY.md, CEO/SKILLS.md, CEO/TRAINING.md, and supporting folders to your Obsidian vault."

If they confirm, create the structure (AGENTS.md, IDENTITY.md, SKILLS.md, TRAINING.md, training/, playbooks/, approvals/, log/, repos.md).
