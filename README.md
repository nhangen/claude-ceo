# claude-ceo

**Autonomous CEO agent for Claude Code. Reads your Obsidian vault, dispatches specialized subagents, runs scheduled playbooks, and gates writes by authority tier.**

## Why

A solo operator has more domains than hours: code repos, research, ops, career, personal. Day-to-day, most of the work isn't doing — it's deciding what to do next, where you left off, and what's safe to ship without you. claude-ceo reads your Obsidian vault (the source of truth), runs prioritized scans on a cron schedule, and proposes work in tiers: read-only digests run automatically, low-stakes writes execute with a report, high-stakes actions queue for approval.

## How it works

```
Cron / interactive trigger
  │
  ▼
ceo-cron.sh ──► ceo-config.sh        (resolve $CEO_VAULT)
            ──► ceo-gather.sh         (pre-gather context → env)
            ──► ceo-scan.sh           (vault diff)
            ──► registry.json         (dispatch lookup)
            ──► preflight_<name>()
            ──► runner:
                 • claude (default)   — read tier = single call,
                                        write tiers = PLAN/FILTER/EXECUTE
                 • script              — deterministic shell, no LLM
            ──► ceo-report.sh         (flock-guarded append)

Output: CEO/reports/YYYY-MM-DD.md
State:  CEO/log/, CEO/approvals/, CEO/cache/
```

Playbooks self-register: `ceo playbook scan` walks `CEO/playbooks/*.md`, extracts each frontmatter block via `yq`, rewrites `registry.json`, and updates the crontab between `# CEO Agent START/END` markers.

## Subagents

Skills under `skills/ceo/agents/` define six specialized subagents the CEO can dispatch for domain-specific work. Each declares its authority and domain scope; high-stakes actions (push, publish, send) are always returned as drafts.

| Subagent | Authority | Domains | Use for |
|----------|-----------|---------|---------|
| `analyst` | read + reports | Career, Academics, all | Evaluating options, thesis planning, cost-benefit, tool comparison |
| `code-reviewer` | read + draft (post is high-stakes) | Awesome Motive, any code repo | PR review — diff analysis, CI check, draft comments |
| `implementer` | read + low-stakes write | Awesome Motive, any code repo | Bug fix — branch, commit, test; push/PR returned as recommendation |
| `ops-manager` | read + low-stakes write | NRX Research | Inventory, hiring pipeline, SOP execution, runbook compliance |
| `researcher` | read only | Academics, Career, NRX Research, any | Vault / web / claude-mem / academic source investigation |
| `writer` | read + draft | Career, Academics, NRX Research, Personal | LinkedIn posts, cover letters, emails, academic writing, docs |

## Playbooks

Active playbooks shipped with the plugin (live in `docs/playbooks/`; copy into `$CEO_VAULT/CEO/playbooks/` to enable, then `ceo playbook scan`):

| Playbook | Trigger | Tier | Runner | Purpose |
|----------|---------|------|--------|---------|
| `morning-brief` | `50 8 * * 1-5` | read | claude | Prioritized day overview — PR queue, top-3 tasks, blessings |
| `morning-scan` | `57 8 * * 1-5` | read | claude | Vault-diff digest of overnight changes |
| `inbox` | every 15 min | read | claude | Process unchecked items in `CEO/inbox.md` and `CEO/inbox/<host>.md` (preflight-gated) |
| `pr-triage` | `03 10 * * 1-5` | read | claude | Surface PRs needing review |
| `pending-drip` | daily | read | claude | Drip reminders from `Pending.md` into `CEO/inbox/<host>.md` |
| `eod-summary` | `47 17 * * 1-5` | read | claude | Recap if there are log entries after 4pm |
| `cleanup` | weekly | low-stakes-write | claude | Branch / worktree hygiene |
| `token-intake` | `45 8 * * 1-5` | read | script | Run `ceo-token-intake.sh` — token-scope snapshot to vault |

`tier: read` runs a single `claude --print --max-turns 5 --disallowedTools Bash,Write,Edit` call with pre-gathered context injected as `<external-data>` blocks. `tier: low-stakes-write` and above use the three-phase PLAN → FILTER → EXECUTE pipeline; high-stakes actions are written to `CEO/approvals/pending.md` instead of executed.

A playbook can declare `runner: script` to dispatch a shell script directly, skipping the LLM call entirely (token-intake is the canonical example). The script receives `CEO_VAULT`, `CEO_DIR`, `LOG_DIR`, `TODAY`, `NOW`, `TRIGGER` as env vars; the dispatcher does not parse stdout. Exit code 0 = success.

A playbook can also declare `bin: <script>.sh` in frontmatter to expose itself as a shell command: `ceo playbook scan` creates a `~/.local/bin/<name>` symlink to that script and removes stale ones when the playbook is deleted or set `inactive`. `ceo doctor` warns when a declared bin symlink is missing.

## Examples

Interactive triage from a Claude Code session:

```
/ceo
```

Reads today's report, walks the vault, and proposes prioritized actions in tier order.

Trigger a playbook by hand (no cron wait):

```bash
ceo cron morning-brief
ceo chat pr-triage          # same playbook, interactive instead of cron
```

Preview what the next cron tick would actually do:

```bash
$ ceo preflight
morning-brief    RUN     (read)
inbox            SKIP    (no unchecked items)
pr-triage        RUN     (3 reviews requested)
```

Read the day's report:

```bash
ceo chat                    # opens conversation about today's report
CEO_CHAT_EFFORT=high ceo chat # override chat effort (default: medium)
# or directly:
$EDITOR ~/Documents/Obsidian/CEO/reports/$(date +%F).md
```

Inspect a registered playbook:

```bash
ceo playbook list
ceo playbook info token-intake
```

## Install

1. Clone somewhere persistent (e.g. `~/ML-AI/claude/ceo`).
2. Run `scripts/ceo setup` — installs deps where it can, walks you through git/ssh/cron, creates `~/.ceo/config` with the resolved vault path.
3. Symlink the CLIs onto `PATH`:
   ```bash
   ln -s "$(pwd)/scripts/ceo"               ~/bin/ceo
   ln -s "$(pwd)/scripts/count-blessings.sh" ~/bin/count-blessings
   ```
4. Run `scripts/ceo doctor` to verify everything resolves (yq, gh auth, vault, cron).
5. Run `ceo playbook scan` to build `registry.json` and install the crontab.

### Requirements

- [Obsidian](https://obsidian.md/) vault synced across all machines
- [Syncthing](https://syncthing.net/) running on every machine (no installer ships with this plugin)
- [claude-obsidian-plugin](https://github.com/nhangen/claude-obsidian-plugin) v1.4.0+ with `VAULT.md` and `Profile.md` in the vault root
- `gh` CLI authenticated, `jq`, `yq` ([install](https://github.com/mikefarah/yq#install))
- Claude Code with subscription (`claude --print`)

### Syncthing

| Platform | Install |
|----------|---------|
| macOS | `brew install syncthing && brew services start syncthing` |
| WSL/Linux | [APT repo](https://apt.syncthing.net/), then `sudo apt install syncthing` |
| Windows | [Installer](https://syncthing.net/downloads/) or `choco install syncthing` |

Open `http://localhost:8384` on each machine, add devices, share the Obsidian vault (Send & Receive everywhere), copy `syncthing/shared.stignore` to `~/Documents/Obsidian/.stignore`. See `syncthing/README.md` for write-domain rules and conflict handling.

## Development

```bash
bash scripts/ceo-config.test.sh         # config loader / path helpers
bash scripts/ceo-cron.test.sh           # dispatch + tier semantics
bash scripts/ceo-notify.test.sh         # notification helper
bash scripts/ceo-discord-report.test.sh # full-report Discord webhook helper
bash scripts/ceo-schedule.test.sh       # schedule override + collision detection
bash scripts/ceo-token-intake.test.sh   # token-intake script runner
bash scripts/count-blessings.test.sh    # blessings CLI + cache
```

Tests are portable across BSD (macOS) and GNU (Linux/WSL): no `shuf`, no `sort -R`, no `flock`, no GNU-only `sed -i`. Each test runs in an isolated `mktemp -d`.

## Configuration

### `~/.ceo/config`

Persistent config file written by `ceo setup`. Stores resolved vault path so scripts don't need a discovery loop on every cron tick. Roll back to inline discovery (debugging only):

```bash
cd /path/to/claude-ceo
git checkout HEAD -- scripts/ceo scripts/ceo-cron.sh scripts/ceo-gather.sh scripts/ceo-report.sh
```

Then re-run `ceo setup` to regenerate the config.

### `CEO_VAULT`

Override the configured vault path for a single invocation:

```bash
CEO_VAULT="$HOME/Documents/Obsidian" bash scripts/ceo-token-intake.sh
```

### `ceo_augment_path`

Helper in `scripts/ceo-config.sh` that prepends `~/.bun/bin`, Homebrew, `~/.local/bin`, and `~/.cargo/bin` (OS-aware) to `PATH`. Cron starts with `PATH=/usr/bin:/bin`; any script that needs bun/Homebrew/user-installed CLIs sources `ceo-config.sh` and calls `ceo_augment_path` at the top. Validates `$HOME` is non-empty — `set -u` doesn't catch `HOME=""`.

### `ceo_resolve_plugin_cli` *(0.12.1)*

Resolves a Claude Code plugin-provided CLI from `~/.claude/plugins/cache/<owner>/<plugin>/<version>/` rather than relying on PATH. Plugins don't install symlinks on PATH; older standalone installs of the same tool can leave stale symlinks that resolve to deleted binaries, producing silent fall-through.

```bash
if out=$(ceo_resolve_plugin_cli "nhangen-tools/token-scope" "src/cli.ts"); then
  runtime=$(printf '%s\n' "$out" | sed -n '1p')
  entry=$(printf '%s\n' "$out" | sed -n '2p')
  "$runtime" "$entry" --since 1d
fi
```

Picks the highest version directory via `sort -V`. Returns 1 if the plugin isn't installed or the entry file is missing. `ceo-token-intake.sh` uses this resolver and emits a `WARN` to stderr when falling back to `token-scope` on `PATH` (introduced after a token-intake cron silently no-op'd against a stale symlink — see nhangen/claude-ceo#37 / #38).

### Per-user schedule overrides

Playbook frontmatter `schedule:` is the default. Per-user overrides live in `$CEO_DIR/schedules.json`:

```json
{
  "morning-scan": "50 8 * * 1-5",
  "morning-brief": "57 8 * * 1-5"
}
```

Unknown playbook names and invalid cron syntax warn to stderr and are ignored — never silently coerced. `ceo playbook scan` performs collision detection before installing the crontab; a refused scan leaves the previous good state intact. Use `ceo schedule <playbook>` for an interactive reschedule.

### Read-tier pre-gather

`ceo-gather.sh` exports (and `ceo-cron.sh` injects) these into the `SINGLE_PROMPT` as `<external-data>` blocks:

| Variable | Source |
|---|---|
| `PR_REVIEW_REQUESTED`, `PR_AUTHORED`, `PR_REVIEW_COUNT`, `PR_AUTHORED_COUNT` | `gh pr list` per repo |
| `PENDING_COUNT`, `APPROVED_COUNT` | `CEO/approvals/pending.md` |
| `TODAY_LOG_SUMMARY`, `YESTERDAY_LOG_SUMMARY` | `CEO/log/<date>.md` |
| `DAILY_NOTE_TOP3`, `DAILY_NOTE_TASKS` | `Daily/<date>.md` |
| `BRIEFINGS_TRAINING` | `CEO/training/briefings.md` |
| `ACTIVE_DOMAINS_CONTENT` | `Profile.md` → `## Active Domains` |
| `PENDING_ASK_QUESTIONS` | `Pending.md` lines containing `[ask]` (top 20) |
| `BLESSINGS_TODAY` | `CEO/cache/blessings-today.md` |
| `VAULT_CHANGES_BY_DOMAIN`, etc. | `ceo-scan.sh` (morning-scan only) |

When writing or editing a read-tier playbook, do not ask Claude to `Read` files. Reference pre-gathered values directly in the playbook's Steps section. New file in the prompt → add an export to `ceo-gather.sh` and an inject site to `ceo-cron.sh`.

### Discord full reports

Status/failure alerts use `discord_webhook`. Full report delivery uses a separate webhook so it can target a different Discord channel:

```json
{
  "discord_webhook": "https://discord.com/api/webhooks/...",
  "discord_report_webhook": "https://discord.com/api/webhooks/..."
}
```

Store that JSON at `~/.config/claude-ceo/secrets.json`, or set `CEO_DISCORD_REPORT_WEBHOOK` for one-off testing. By default, the full-report poster sends `morning-brief` only. Override the allowlist in `CEO/settings.json`:

```json
{
  "discord_report_triggers": ["morning-brief"]
}
```

The full report is split across multiple Discord messages when it exceeds Discord's message limit.

## Architecture

### Authority tiers

| Tier | Actions | Execution path | Approval |
|------|---------|----------------|----------|
| `read` | Scan vault, read PRs, generate briefings | Single call (no Bash/Write/Edit) | Auto |
| `low-stakes-write` | Create branches, run tests, post PR comments | Three-phase PLAN/FILTER/EXECUTE | Auto + report |
| `high-stakes` | Push code, merge PRs, create PRs | Filtered out of EXECUTE; written to `approvals/pending.md` | Propose + wait |

### Vault structure

```
CEO/
├── AGENTS.md          — global rules for ALL agents (tiers, constraints)
├── IDENTITY.md        — CEO-specific identity and personality
├── TRAINING.md        — rules learned from corrections
├── training/          — domain-specific training rules
├── playbooks/         — step-by-step workflows (frontmatter drives registration)
├── registry.json      — derived dispatch table
├── settings.json      — runtime config (cooldown, branch_prefix, …)
├── repos.md           — registry of cloned repos
├── inbox.md           — shared task queue for the inbox playbook
├── inbox/             — per-host task queues written by automated intakes
├── blessings.md       — gratitude list
├── approvals/         — pending high-stakes proposals
├── cache/             — derived state
├── delegations/       — task hand-offs
├── reports/           — daily report files
└── log/               — execution logs
```

### CLIs

`ceo`:

```
ceo setup            First-time machine setup (deps, git, ssh, cron)
ceo next             Redisplay post-setup steps
ceo doctor           Check system health (deps, vault, cron, auth)
ceo test             Smoke test: trigger morning-brief, check log
ceo cron <name>      Manually run a cron trigger
ceo chat [name]      Interactive playbook (no cron); empty = triage conversation; defaults to --effort medium
ceo playbook scan|list|info     Self-registering playbook management
ceo schedule [name]  List effective schedules; with name, reschedule one
ceo preflight        Preview what cron would run vs skip
```

Override interactive chat effort with `CEO_CHAT_EFFORT=low|medium|high|xhigh|max`.

`count-blessings` — gratitude list surfaced in the morning brief under `## Personal / ### Blessings`:

```
count-blessings add "text"   Append a blessing
count-blessings list         Show all blessings, numbered
count-blessings show         Show today's three picks
```

### Slash skills (Claude Code)

| Command | Description |
|---------|-------------|
| `/ceo` | Read vault, propose prioritized actions |
| `/ceo:status` | Pending approvals, recent log, blocked items |
| `/ceo:brief` | Generate morning briefing on demand |
| `/ceo:delegate` | Hand off a task |
| `/ceo:train` | Add a training rule or playbook |
| `/ceo:log` | Today's execution log |

## Known Limitations

- **WSL2 cron does not auto-start at boot.** Add `[boot] command = service cron start` to `/etc/wsl.conf`, or set up a Windows Task Scheduler job that runs `wsl.exe -u <user> -- /etc/init.d/cron start` at logon.
- **Portable timeout.** `ceo-cron.sh` uses `timeout` (Linux) or `gtimeout` (macOS via `brew install coreutils`). If neither is installed, the wrapper degrades to no wall-clock cap (`--max-turns` and API timeout still apply) and a `WARN` is logged.
- **Schedule collisions are refused, not coerced.** Two cron-trigger playbooks on the same minute would race the global `/tmp/ceo-cron.lock`; `ceo playbook scan` refuses to install the crontab until you resolve via `ceo schedule <playbook>` or by editing `schedules.json`.

## License

MIT.
