---
name: ceo-agents
description: List available agent roles and recent delegation history. Triggers on "/ceo:agents", "show agents", "delegation history", "who can I delegate to", "list agents".
version: 0.1.0
---

# CEO Agents

List available specialized agent roles and recent delegation history.

## Config

Read vault path from the obsidian plugin config: `~/.claude/plugins/cache/nhangen/obsidian/*/obsidian.local.md`

Set `$VAULT` to the vault_path value.

## Steps

1. **List available roles** — scan the plugin's `skills/ceo/agents/` directory for role template files. For each `.md` file, read the frontmatter and present:

   ```
   ## Available Agent Roles

   | Role | Authority | Domains |
   |------|-----------|---------|
   | Code Reviewer | read + draft | Awesome Motive, any code repo |
   | Implementer | read + low-stakes write | Awesome Motive, any code repo |
   | Researcher | read only | Academics, Career, NRX, any |
   | Writer | read + draft | Career, Academics, NRX, Personal |
   | Ops Manager | read + low-stakes write | NRX Research |
   | Analyst | read + report | Career, Academics, all |
   ```

2. **Show recent delegations** — read files in `$VAULT/CEO/delegations/` from the last 7 days. For each, show:
   - Date, role, task summary, status

   ```
   ## Recent Delegations (last 7 days)

   | Date | Role | Task | Status |
   |------|------|------|--------|
   | 2026-04-14 | code-reviewer | PR #6980 review | completed |
   | 2026-04-14 | writer | LinkedIn post draft | completed |
   ```

   If no delegations exist: "No delegations yet. Use `/ceo:delegate` to dispatch an agent."

3. **Show active delegations** — filter for `status: in-progress`.
   If any exist, list them prominently at the top.
