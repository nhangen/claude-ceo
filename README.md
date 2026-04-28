# claude-ceo

Autonomous CEO agent for Claude Code. Reads your Obsidian vault, understands your priorities, proposes and executes work across domains. Triage conversations on demand, scheduled cron playbooks, and a small executive-assistant feature set.

## Table of contents

- [What it does](#what-it-does)
- [Architecture at a glance](#architecture-at-a-glance)
- [Requirements](#requirements)
- [Install](#install)
- [Daily flow](#daily-flow)
- [CLIs](#clis)
  - [`ceo` — agent system management](#ceo--agent-system-management)
  - [`count-blessings` — gratitude list (EA feature)](#count-blessings--gratitude-list-ea-feature)
- [Slash skills (in Claude Code)](#slash-skills-in-claude-code)
- [Vault structure](#vault-structure)
- [Playbooks](#playbooks)
- [Authority tiers](#authority-tiers)
- [Tests](#tests)
- [Troubleshooting](#troubleshooting)

## What it does

The CEO is a small set of shell scripts plus playbook files in your Obsidian vault. Cron fires playbooks on a schedule (morning scan, morning brief, inbox, EOD summary, etc.). Each playbook gets a curated context payload and produces output that the shell appends to a daily report file. Interactive triage runs from `ceo chat`. Higher-stakes actions (writes, pushes, merges) are gated through an approvals workflow.

## Architecture at a glance

```
┌─────────────────────────────────────────────────────────────┐
│  Cron / interactive trigger                                 │
│       │                                                     │
│       ▼                                                     │
│  ceo-cron.sh  ──►  ceo-config.sh   (resolve $CEO_VAULT)     │
│                ──►  ceo-gather.sh   (pre-gather context)    │
│                       └─►  blessings-lib.sh                 │
│                              └─► CEO/cache/blessings-today  │
│                ──►  ceo-scan.sh    (vault diff for scan)    │
│                ──►  registry.json  (dispatch lookup)        │
│                ──►  preflight_<name>()                      │
│                ──►  read-tier SINGLE_PROMPT (one claude run)│
│                     OR three-phase PLAN/FILTER/EXECUTE      │
│                ──►  ceo-report.sh  (flock-guarded append)   │
│                                                             │
│  Output:  CEO/reports/YYYY-MM-DD.md                         │
│  State:   CEO/log/, CEO/approvals/, CEO/cache/              │
└─────────────────────────────────────────────────────────────┘
```

Playbooks self-register: `ceo playbook scan` walks `CEO/playbooks/*.md`, extracts each frontmatter block via `yq`, rewrites `registry.json`, and updates the user's crontab between `# CEO Agent START/END` markers.

`tier: read` playbooks run a single `claude --print --max-turns 1 --disallowedTools Bash,Write,Edit` call. `tier: low-stakes-write` and above use the three-phase PLAN → FILTER → EXECUTE pipeline (high-stakes actions are written to `CEO/approvals/pending.md` instead of executed).

## Requirements

- [Obsidian](https://obsidian.md/) with a vault synced across all machines
- [Syncthing](https://syncthing.net/) installed and running on every machine (Mac, WSL, Windows)
- [Obsidian plugin](https://github.com/nhangen/claude-obsidian-plugin) v1.4.0+ with `VAULT.md` in your vault root
- `Profile.md` in your vault root (created by the Chief of Staff knowledge layer)
- `gh` CLI authenticated
- `jq` for JSON processing
- `yq` for YAML frontmatter parsing ([install](https://github.com/mikefarah/yq#install))
- Claude Code with a subscription (`claude --print`)

### Syncthing setup

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

## Install

1. Clone this repo somewhere persistent (e.g. `~/ML-AI/claude/ceo`).
2. Run `scripts/ceo setup` — installs deps where it can, walks you through git/ssh/cron, creates `~/.ceo/config` with the resolved vault path.
3. Symlink the CLIs to a directory on `PATH`:
   ```bash
   ln -s "$(pwd)/scripts/ceo"             ~/bin/ceo
   ln -s "$(pwd)/scripts/count-blessings.sh" ~/bin/count-blessings
   ```
4. Run `scripts/ceo doctor` to verify everything resolves (yq, gh auth, vault, cron).
5. Run `ceo playbook scan` to build `registry.json` and install the crontab entries.

## Daily flow

Default schedule (active playbooks; see `CEO/registry.json` for the live truth):

| Time | Trigger | Tier | Notes |
|------|---------|------|-------|
| 8:50 AM | `morning-brief` | read | Surfaces priorities, PR queue, blessings (`## Personal / ### Blessings`) |
| 8:57 AM | `morning-scan` | read | Vault-diff digest of overnight changes |
| every 15 min | `inbox` | read | Processes unchecked items in `CEO/inbox.md` (preflight-gated) |
| 10:03 AM weekdays | `pr-triage` | read | If you have PRs needing review |
| daily | `pending-drip` | read | Dripping reminders from `Pending.md` |
| 5:47 PM weekdays | `eod-summary` | read | If there are log entries after 4pm |
| weekly | `cleanup` | low-stakes-write | Branch / worktree hygiene |

All output lands in `CEO/reports/YYYY-MM-DD.md` via `ceo-report.sh`. The interactive `/ceo` (or `ceo chat`) reads the day's report and converses about it.

## CLIs

### `ceo` — agent system management

```
ceo setup        First-time machine setup (deps, git, ssh, cron)
ceo next         Redisplay post-setup steps (survives terminal clear)
ceo doctor       Check system health (deps, vault, cron, auth)
ceo test         Smoke test: trigger morning-brief, check log
ceo cron <name>  Manually run a cron trigger (e.g. ceo cron pr-triage)
ceo chat [name]  Interactive playbook (no cron); empty arg = triage conversation
ceo playbook scan|list|info  Self-registering playbook management
ceo preflight    Preview what cron would run vs skip
```

### `count-blessings` — gratitude list (EA feature)

A small executive-assistant feature: keep a gratitude list in your vault and have the morning brief surface three random entries each day under `## Personal / ### Blessings`.

```
count-blessings add "text"   Append a blessing to the list
count-blessings list         Show all blessings, numbered
count-blessings show         Show today's three picks
```

**Data files** (in your Obsidian vault):
- `CEO/blessings.md` — the persistent list, one bullet per blessing
- `CEO/cache/blessings-today.md` — auto-generated daily cache holding the three picks

**How it surfaces:**
1. `ceo-gather.sh` calls `ensure_blessings_cache` (in `scripts/blessings-lib.sh`) on every cron run. Picks 3 at random into the cache file once per day; idempotent fast path on same-day cache.
2. `BLESSINGS_TODAY` is exported into the read-tier `SINGLE_PROMPT` inside a separate `<external-data>` block (sealed against prompt injection by the existing untrusted-content guard). Three-phase playbooks (`tier: low-stakes-write` and above) do not receive blessings data.
3. The `morning-brief` playbook renders the bullets verbatim under `## Personal / ### Blessings` with a footer pointing at the CLI.

**First-run UX:** `count-blessings add "..."` works on a fresh machine — it bootstraps `$CEO_DIR` automatically. No `ceo setup` required just to seed blessings.

**Portability:** macOS (BSD userland), Linux/WSL (GNU userland). No `shuf`, no `sort -R`, no `flock`, no GNU-only `sed -i`. Atomic tmp + `mv -f` writes; `mkdir`-based locks; `mktemp` for tmp filenames.

## Slash skills (in Claude Code)

Skills surface as `<plugin>:<skill>` once the plugin is installed via the marketplace.

| Command | Description |
|---------|-------------|
| `/ceo` | Read vault, propose prioritized actions (triage conversation) |
| `/ceo:status` | Show pending approvals, recent log, blocked items |
| `/ceo:brief` | Generate morning briefing on demand |
| `/ceo:delegate` | Hand off a task |
| `/ceo:train` | Add a training rule or playbook |
| `/ceo:log` | Show today's execution log |

`count-blessings` is intentionally CLI-only — running `count-blessings add "..."` from a terminal is fewer keystrokes than any slash-command equivalent.

## Vault structure

The CEO's brain lives in your Obsidian vault at `CEO/`:

```
CEO/
├── AGENTS.md          — global rules for ALL agents (tiers, constraints)
├── IDENTITY.md        — CEO-specific identity and personality
├── TRAINING.md        — rules learned from corrections
├── training/          — domain-specific training rules
├── playbooks/         — step-by-step workflows (frontmatter drives registration)
├── registry.json      — derived dispatch table (built by `ceo playbook scan`)
├── settings.json      — runtime config (cooldown, branch_prefix, …)
├── repos.md           — registry of cloned repos
├── inbox.md           — task queue for the inbox playbook
├── blessings.md       — gratitude list (EA feature)
├── approvals/         — pending high-stakes proposals
├── cache/             — derived state (blessings-today.md, …)
├── delegations/       — task hand-offs
├── reports/           — daily report files (ceo-report.sh writes here)
└── log/               — execution logs (per-trigger timestamps, errors)
```

## Playbooks

Each playbook is a markdown file in `CEO/playbooks/` with frontmatter that drives registration:

```yaml
---
name: morning-brief
description: Prioritized overview of the day's work
trigger: cron
schedule: "50 8 * * 1-5"
model: sonnet
preflight: none
tier: read
status: active
---
```

Run `ceo playbook scan` after editing any playbook to refresh `registry.json` and the user's crontab. Use `ceo playbook list` to see what's registered, `ceo playbook info <name>` for the full record.

To disable a playbook without deleting it: change `status: active` → `status: inactive` and rescan.

## Authority tiers

| Tier | Actions | Execution path | Approval |
|------|---------|----------------|----------|
| `read` | Scan vault, read PRs, generate briefings | Single-call (1 model call, no Bash/Write/Edit) | Auto |
| `low-stakes-write` | Create branches, run tests, post PR comments | Three-phase PLAN/FILTER/EXECUTE | Auto + report |
| `high-stakes` | Push code, merge PRs, create PRs | Filtered out of EXECUTE; written to `approvals/pending.md` | Propose + wait |

## Tests

```bash
bash scripts/count-blessings.test.sh   # 22 self-contained TDD tests for the CLI + cache
```

The harness is portable across BSD (macOS) and GNU (Linux/WSL) userlands. `count-blessings.sh` and `blessings-lib.sh` use no `shuf`, no `sort -R`, no `flock`, no GNU-only extensions. Each test runs in an isolated `mktemp -d` directory.

## Troubleshooting

### Vault path detection issues

As of v0.5.0, the CEO system uses a persistent config file at `~/.ceo/config` to store the vault path, instead of relying on environment-specific path discovery.

**If vault path detection fails during `ceo setup`:**
1. Verify Syncthing is running and the vault has synced: `ls $VAULT/CEO/inbox.md`
2. Run `ceo setup` again to write the config file
3. Verify the config was created: `cat ~/.ceo/config`
4. Verify vault detection: `ceo doctor`

**If you need to roll back to inline discovery loops** (temporarily, for debugging):

```bash
cd /path/to/claude-ceo
git checkout HEAD -- \
  scripts/ceo \
  scripts/ceo-cron.sh \
  scripts/ceo-gather.sh \
  scripts/ceo-report.sh
```

This restores the hardcoded discovery loops in each script. This is a **temporary measure** for debugging only. After restoring, re-run `ceo setup` to regenerate the config file and re-enable the persistent config system.

### Cron not firing

```bash
ceo doctor                              # checks crontab + dependencies
crontab -l | grep -A1 -B1 'CEO Agent'   # show installed entries
tail -n 50 ~/Documents/Obsidian/CEO/log/cron-skips.log
```

**WSL2 caveat:** WSL2 does not auto-start cron at boot. Either add a `[boot] command = service cron start` stanza to `/etc/wsl.conf`, or set up a Windows Task Scheduler job that runs `wsl.exe -u <user> -- /etc/init.d/cron start` at logon.

### Playbook not running on schedule

```bash
ceo playbook info <name>     # frontmatter snapshot
jq '.playbooks[] | select(.name == "<name>")' ~/Documents/Obsidian/CEO/registry.json
```

If the playbook frontmatter changed but `registry.json` is stale: `ceo playbook scan`.
If `status: inactive` in `registry.json`: flip frontmatter and rescan.
If preflight is gating the run: `ceo preflight <name>` to see why.

### count-blessings produces no Personal section in the brief

1. Is `CEO/blessings.md` populated? `count-blessings list` should show entries.
2. Did `morning-brief` run? `tail -n 50 ~/Documents/Obsidian/CEO/log/cron-runs.log`.
3. Is the cache today's? `count-blessings show` (frontmatter `date:` should match today).
4. Is `morning-brief.md` in `CEO/playbooks/` updated to reproduce the `Blessings today:` external-data block under `## Personal / ### Blessings`?

For production issues, file a bug report with your OS, WSL version (if applicable), and the output of `ceo doctor`.

## License

MIT.
