# claude-ceo

Autonomous CEO agent for Claude Code. Reads your Obsidian vault, understands your priorities, proposes and executes work across domains.

## Requirements

- [Obsidian](https://obsidian.md/) with a vault synced across all machines
- [Syncthing](https://syncthing.net/) installed and running on every machine (Mac, WSL, Windows)
- [Obsidian plugin](https://github.com/nhangen/claude-obsidian-plugin) v1.4.0+ with `VAULT.md` in your vault root
- `Profile.md` in your vault root (created by the Chief of Staff knowledge layer)
- `gh` CLI authenticated
- Claude Code with a subscription (`claude --print`)

### Syncthing Setup

Syncthing syncs the Obsidian vault between machines. Install it separately — the CEO setup script does **not** install it for you.

| Platform | Install |
|----------|---------|
| macOS | `brew install syncthing && brew services start syncthing` |
| WSL/Linux | [Add the APT repo](https://apt.syncthing.net/), then `sudo apt install syncthing` |
| Windows | [Download installer](https://syncthing.net/downloads/) or `choco install syncthing` |

After installing on all machines:
1. Open `http://localhost:8384` on each machine
2. Add devices to each other
3. Share the Obsidian vault folder (Send & Receive on all machines)
4. Copy `syncthing/shared.stignore` to `~/Documents/Obsidian/.stignore` on each machine
5. Wait for initial sync, then verify `CEO/AGENTS.md` exists on all machines

See `syncthing/README.md` for write-domain rules and conflict handling.

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
