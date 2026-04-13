# claude-ceo

Autonomous CEO agent for Claude Code. Reads your Obsidian vault, understands your priorities, proposes and executes work across domains.

## Requirements

- [Obsidian plugin](https://github.com/nhangen/claude-obsidian-plugin) v1.4.0+ with `VAULT.md` in your vault root
- `Profile.md` in your vault root (created by the Chief of Staff knowledge layer)
- `gh` CLI authenticated

## Commands

| Command | Description |
|---------|-------------|
| `/ceo` | Read vault, propose prioritized actions |
| `/ceo:status` | Show pending approvals, recent log, blocked items |
| `/ceo:brief` | Generate morning briefing (Phase 2b) |
| `/ceo:delegate` | Hand off a task (Phase 2b) |
| `/ceo:train` | Add a training rule or playbook (Phase 2b) |
| `/ceo:log` | Show today's execution log (Phase 2b) |

## Vault Structure

The CEO's brain lives in your Obsidian vault at `CEO/`:

```
CEO/
├── AGENTS.md        — global rules for ALL agents (tiers, constraints)
├── IDENTITY.md      — CEO-specific identity and personality
├── SKILLS.md        — dispatch table: task types -> playbooks
├── TRAINING.md      — rules learned from corrections
├── training/        — domain-specific training rules
├── playbooks/       — step-by-step workflows
├── repos.md         — registry of cloned repos
├── approvals/       — pending high-stakes proposals
└── log/             — daily execution logs
```

## Authority Tiers

| Tier | Actions | Approval |
|------|---------|----------|
| Read | Scan vault, read PRs, generate briefings | Auto |
| Low-stakes write | Create branches, run tests, post PR comments | Auto + report |
| High-stakes | Push code, merge PRs, create PRs | Propose + wait |
