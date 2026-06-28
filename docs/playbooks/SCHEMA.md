# Playbook Frontmatter Schema

Every playbook is a markdown file in `$CEO_VAULT/CEO/playbooks/` (or `docs/playbooks/` in this repo for the default seed) with a YAML frontmatter block. `ceo playbook scan` reads each file, validates the frontmatter, and writes a normalized entry into `$CEO_VAULT/CEO/registry.json`.

Unknown values for enum fields are **rejected at parse time** with a `SKIP` diagnostic per [`enum-config-typo-fallback`](../../../.claude/rules/enum-config-typo-fallback.md). The dispatcher never silently coerces a typo to a default.

## Fields

| Field | Required | Type | Notes |
|---|---|---|---|
| `name` | yes | string | Unique playbook ID. Used as `ceo-cron.sh <name>` and as the cron-runs.log key. No newlines, no whitespace-only. Vault entries shadow same-named repo entries. |
| `description` | recommended | string | Free text. Surfaced by `ceo playbook info` and used by `ceo doctor` reporting. |
| `trigger` | yes | enum: `cron`, `manual` | Only `cron` entries get installed by `ceo playbook scan`. `manual` is runnable via `ceo-cron.sh <name>` on demand but never installed. |
| `schedule` | required when `trigger: cron` and `status: active` | 5-field cron expression | Validated with [`_validate_cron_expr`](../../scripts/ceo). User-level overrides live in `$CEO_VAULT/CEO/schedules.json` and win at scan time. |
| `model` | depends on `runner` | string | Claude model (e.g. `haiku`, `sonnet`) for `runner: claude`; Ollama tag for `runner: ollama` / `runner: ollama-think`. For `runner: script` and `runner: skill` it is optional and exported as `CEO_MODEL` so an artifact that itself drives an LLM (e.g. `ticket-triage-autopilot`, `weekly-synthesis`) pins it and reports it in its Discord embed — rendered as a `declared` claim (e.g. `skill: weekly-synthesis (opus, declared)`) since the cron harness does not invoke the model itself; omit it for pure-shell scripts and model-less skills. |
| `preflight` | recommended | function name | Bash function defined in `scripts/ceo-cron.sh` that gates whether the playbook runs (e.g. `has_unchecked_inbox`, `has_pending_items`, `none`). Missing/unknown preflight short-circuits to skip. |
| `tier` | yes | enum: `read`, `low-stakes-write`, `high-stakes` | Controls notification posture and approval gating. `read` posts the full report to Discord; writes go to an approvals queue. |
| `status` | recommended | enum: `active`, `draft`, `disabled` | See [Status semantics](#status-semantics) below. Empty/missing is treated as "not active" for back-compat but is **discouraged** — be explicit. |
| `runner` | no | enum: `claude`, `script`, `ollama`, `ollama-think`, `ollama-agent`, `skill` | Dispatch shape. Default is `claude`. `script` runs `script:` directly — the cron harness makes no LLM call, though the script itself may shell out to one. `ollama-agent` shells to the tool-using local-model bridge (`ollama-agent/cli.py`) — a governed agentic loop, distinct from the single-call `ollama` / `ollama-think` runners. |
| `script` | required when `runner: script` | string | Relative path under `scripts/` (e.g. `ceo-value-tracker.sh`). The dispatcher resolves to `$INSTALL_DIR/scripts/<script>`. |
| `skill` | required when `runner: skill` | string | Skill name passed to the Claude Code skill invoker. |
| `registry` | required when `runner: ollama-agent` | string | The bridge task registry, as a path to a JSON file **or** an inline single-line JSON string (`{"tasks":{"<task>":{...}}}`). Passed to the bridge's `--registry`; `load_registry` parses a non-existent path as inline JSON, so inline JSON keeps the task spec host-portable in the playbook itself. |
| `task` | no (`runner: ollama-agent`) | string | The bridge task-registry entry selected via `--task-name` (applies its model/tier/tools/rules). Defaults to the playbook `name`. The playbook **body** (markdown after the frontmatter) is the natural-language `--task` instruction. Two-axis tier model: the playbook `tier` is the cron-side notification posture; the bridge task's own `tier` (in `registry`) is the delegation gate. |
| `bin` | no | string | If set, `ceo playbook scan` installs a `~/.local/bin/<bin-without-.sh>` symlink pointing at `scripts/<bin>`. Only created for `status: active`. |
| `inputs` | no | JSON array | Pre-gather keys the dispatcher injects into the prompt context. Empty array = no pre-gathered context. Absent = all keys (back-compat default). Unknown keys warn-and-skip at dispatch. Valid keys: `pr_data`, `pending_count`, `today_log`, `yesterday_log`, `daily_note`, `briefings_training`, `active_domains`, `pending_ask`, `scan_data`, `blessings`. |
| `requires` | no | JSON array of env-var names | Credentials the playbook needs (e.g. `["HUBSPOT_REFRESH_TOKEN"]`). `ceo creds check <name>` reports missing values. Non-array entries are warned and dropped. |
| `scope` | no | enum: `each`, `single` | How the playbook fans out across the swarm. Absent defaults to `single` (safe: a single-scope playbook runs nowhere until an owner is assigned). `each` runs on every host where locally enabled; `single` runs on exactly one owner host. Unknown values are **rejected at parse** with a `SKIP` and a non-zero scan exit. See [Swarm selection model](#swarm-selection-model). |
| `hosts` | no | JSON array of host names | **DEPRECATED** — no longer consulted for scheduling. Selection is now `scope` plus host-local enablement (`each`) or `swarm.json` ownership (`single`); `selectRunnable` does not read `hosts`. `ceo playbook scan` still parses and normalizes it (malformed → `["*"]` with a `WARN`) but warns-and-ignores it for scheduling. See [Swarm selection model](#swarm-selection-model) and [Host scoping (legacy)](#host-scoping-legacy). |
| `artifact` | recommended for `runner: script` | string template | Expected output path relative to the vault. Must start with `CEO/`. Supports `{TODAY}` (YYYY-MM-DD) and `{HOST}` (short hostname). Unknown tokens reject at parse. `ceo doctor` cross-checks declared artifact vs disk for every active `script` or `ollama-agent` playbook that logged "completed" today. |
| `out_pattern` | no | string | Legacy reporting pattern (output filename hint). Kept for back-compat with older playbooks. New playbooks should use `artifact`. |

## Status semantics

| status | `ceo-cron.sh <name>` (on-demand) | `ceo playbook scan` installs cron line? | `ceo playbook list` shows? | `ceo doctor` surfaces? |
|---|---|---|---|---|
| `active` | yes | yes | yes | inferred from health checks |
| `draft` | yes | **no** | yes (with `status: draft`) | yes, in the **Drafts** section, with a hint to flip to `active` |
| `disabled` | yes | **no**; rescan removes any previously-installed line | yes (with `status: disabled`) | no special surface |
| missing / empty | yes | no (treated as inactive) | yes (`status: -`) | no special surface |
| anything else | **rejected at parse** with `SKIP <basename> (unknown status: ...)` — entry is dropped from the registry, no fallback to a default | — | — | — |

### Run modes — on-demand vs scheduled

`ceo-cron.sh` distinguishes who is invoking it:

| Invocation | Mode | Status enforcement |
|---|---|---|
| `ceo-cron.sh <name>` (bare) or `--manual` | manual (on-demand) | runs any valid status — the "on-demand" column above |
| `ceo-cron.sh <name> --scheduled` | scheduled (cron/daemon) | runs `status: active` only; `draft` / `disabled` / missing are skipped |

The default is **manual**, so a bare `ceo-cron.sh <name>` is the on-demand path the table documents. The scheduler (the Phase-1.5 daemon, and any cron line that opts in) passes `--scheduled` to enforce `active`. Because `ceo playbook scan` installs cron lines for `active` playbooks only, a real cron line never targets a non-active playbook regardless of mode.

`--scheduled` and `--manual` are mutually exclusive. `--force` (manual-only) bypasses the per-trigger cooldown for iterative smoke-testing; it is rejected with `--scheduled`.

`--dry-run` is a preview mode, orthogonal to run-mode. It runs every **read-only** phase (gather, the PLAN call, a read-tier model call) but mutates **no CEO state**: the EXECUTE phase is skipped, `runner: script` / `runner: skill` are not executed, and nothing is written to the approvals queue, Discord, the report intake, the host inbox, the synced daily log (`CEO/log/<TODAY>.md`), `.last-run`, `.last-scan`, the fail-counter, or `cron-runs.log`. What *would* happen is written to a preview file at `CEO/log/preview/<trigger>-<TODAY>.md`.

That preview is **host-local**: `CEO/log/preview/` is excluded from Syncthing in `syncthing/shared.stignore`, so a dry-run on one host never propagates to the others. The rest of `CEO/log/` *is* synced — the daily log and the operational diagnostic journals (`cron-skips.log`, `cron-stderr.log`) — which is why the daily-log header write is also skipped in dry-run. A dry-run still appends clearly-labelled diagnostic lines to `cron-skips.log` (e.g. the `--scheduled` WARN below); that journal is the dispatcher's operational debug channel, not CEO decision-state.

`--dry-run` bypasses the cooldown so it can be run iteratively, and is allowed under `--scheduled` (with a WARN to `cron-skips.log`) so a daemon can smoke-test without acting. Non-guarantee: read-only external calls still run and still cost tokens — `--dry-run` skips effects, not reads.

### Fleet sweep — `--test-all`

`ceo-cron.sh --test-all` dry-runs **every registered playbook** in one pass and writes a single aggregate report. It takes no positional trigger and always implies `--dry-run` (it never performs a side effect). Each playbook is swept by re-invoking `ceo-cron.sh <name> --dry-run --depth <depth>`, so it reuses the same preview/no-side-effect machinery as a single dry-run.

```bash
ceo-cron.sh --test-all                       # cheap fleet health check (preflight depth)
ceo-cron.sh --test-all --depth deep          # exercise every model call
ceo-cron.sh --test-all --depth deep --model haiku   # …against an override model
```

| Flag | Meaning |
|---|---|
| `--depth preflight` | **Default.** Stop after each playbook's preflight passes — answers "would this fire right now?" with **no model call, no tokens spent**. |
| `--depth plan` | Run the planning phase where one exists: tier:write playbooks make their PLAN call; read-tier playbooks preview the call they *would* make without spending tokens. |
| `--depth deep` | Full dry-run: read-tier playbooks make their read-only call; write-tier playbooks run PLAN+FILTER. EXECUTE is still skipped (it's a dry-run). |
| `--model <tag>` | Override the model for any playbook that makes a model call (plan/deep depth). The override is applied uniformly; passing a model incompatible with a playbook's runner (e.g. an Ollama tag to a claude-runner playbook) surfaces as a `FAILED` row — which is the intended smoke-test signal ("this config wouldn't run"), not a dispatcher bug. Unset = each playbook's configured `model:`. |
| `--all-hosts` | **Phase-1.5 stub.** Warns it is not yet implemented and sweeps the local host only. (Cross-host fan-out arrives with the daemon.) |

Unknown `--depth` values are rejected at parse (no silent default). `--depth` / `--model` / `--all-hosts` are preview-only and require `--dry-run` or `--test-all`.

**Output:** `CEO/log/preview/test-all/<TODAY>.md` — host-local (under the stignored `CEO/log/preview/` tree, like a single dry-run's preview), so a fleet smoke-test stays on the host that ran it. The report has a per-playbook result table (`would run` / `skip: no work` / `FAILED`) plus each playbook's individual preview inline.

> **Note on `--model` vs the original design.** The issue proposed "unset → local Ollama default." Forcing Ollama globally would break tier:write playbooks (the three-phase pipeline requires Claude; Ollama is rejected for non-read tiers), so unset keeps each playbook's configured model. The cheap-sweep goal is met by the `preflight` default, which makes no model call at all.

### Swarm selection model

`scope` replaces `hosts` as the mechanism that decides which host runs a playbook. The daemon's run predicate (`selectRunnable`, `lib/scheduler/src/select.ts`) is:

> A host runs a playbook iff it is an **active** `cron` playbook with a non-blank schedule **and** either:
> - `scope: each` **and** the playbook is in this host's local `~/.ceo/enabled.json`, **or**
> - `scope: single` **and** this host equals the playbook's owner in `CEO/swarm.json` (`owners[name] === host`).

| `scope` value | Meaning |
|---|---|
| absent | `single` (the safe default — runs nowhere until an owner is assigned) |
| `single` | runs on exactly **one** owner host; assigned via `ceo playbook assign <name> <host>`, recorded in the synced `CEO/swarm.json`. Guarantees no double token spend; an empty owner = runs nowhere. |
| `each` | runs on **every** host where locally enabled, selected per-host via `ceo playbook enable` / `disable` (host-local `~/.ceo/enabled.json`). |
| any other value | **unknown** — `ceo playbook scan` skips the entry with a `SKIP` diagnostic and a non-zero exit. |

`ceo playbook scan` validates `scope` at parse time and never coerces an unknown value to a default (per [`enum-config-typo-fallback`](../../../.claude/rules/enum-config-typo-fallback.md)); a typo'd value counts toward the scan's failure exit, the same as an unknown `status`. Ownership is authoritative for `single` scope — local enablement does not gate it.

Selection verbs:

- `ceo playbook enable <name>` / `ceo playbook disable <name>` — toggle an `each`-scope playbook in this host's `~/.ceo/enabled.json` (rejected for `single` scope).
- `ceo playbook assign <name> <host>` — set the owner of a `single`-scope playbook in `CEO/swarm.json` (rejected for `each` scope).
- `ceo playbook list` — per-host view: shows each playbook's scope, status, and current state (`✓ enabled here` / `· disabled here` for `each`; `owner: <host>` / `owner: (none) ⚠` for `single`).

`swarm.json` is synced across the fleet and has the shape `{schema_version, hosts: [], owners: {}}` — `owners` maps a single-scope playbook name to its owning host. Because it is synced, two hosts editing it can produce Syncthing conflict copies; `ceo swarm doctor [--fix]` self-heals by merging `swarm.sync-conflict-*.json` copies: `hosts` union, `owners` live-wins-per-key (for live-absent keys the most-recent conflict wins), max `schema_version`. `ceo swarm owners-health` flags single-scope playbooks whose owner host's synced heartbeat has gone stale (presumed offline → those playbooks run nowhere), escalating to the inbox once on a fresh→stale transition.

### Host scoping (legacy)

> **Deprecated.** The `hosts` field below describes the pre-swarm selection mechanism. It is no longer consulted for scheduling — see [Swarm selection model](#swarm-selection-model). `ceo playbook scan` still parses and normalizes `hosts` for back-compat, but warns-and-ignores it; `selectRunnable` does not read it.

The `hosts` field formerly declared which machines a playbook may run on:

| `hosts` value | Meaning |
|---|---|
| absent | all hosts (recorded as `["*"]`) |
| `["*"]` | all hosts |
| `["ml-1", "mac-mini"]` | only those named hosts (matched against the short hostname) |
| `["*", "ml-1"]` | `*` mixed with names is reserved to mean **all hosts** — the wildcard dominates |
| scalar / `[]` / blank element | **malformed** — `ceo playbook scan` warns and records `["*"]` |

`ceo playbook scan` still validates the shape at parse time and defaults any malformed value to `["*"]` with a `WARN` (per [`enum-config-typo-fallback`](../../../.claude/rules/enum-config-typo-fallback.md)), but the normalized value no longer affects whether any host runs the playbook. To scope a playbook to specific hosts, use `scope` + `assign` / `enable`; to stop it entirely, use `status: disabled`.

### Generated registry is host-local

`ceo playbook scan` reads the playbook `.md` definitions from the synced vault (`$CEO_VAULT/CEO/playbooks/`) but writes the generated `registry.json` host-local to `~/.ceo/registry.json`. The vault holds only the definitions; the registry is per-host. Two machines scanning a shared vault would otherwise both rewrite the synced `registry.json` and produce Syncthing `.sync-conflict` copies. The scheduler daemon (`lib/scheduler/`) reads the same host-local path.

### Use draft for WIP playbooks

`draft` exists for "exists, runnable on demand, not ready for cron." Author iteratively via `bash scripts/ceo-cron.sh <name>` (optionally `--force` to bypass the cooldown between runs) until happy with the behavior, then flip frontmatter to `status: active` and re-run `ceo playbook scan` to install.

### Use disabled to durably tear down

`disabled` is "I previously had this installed and want it removed everywhere." Flipping `active → disabled` and running `ceo playbook scan` removes the cron line on the next scan. Unlike a draft, `disabled` is the explicit "stop running" signal, distinct from "still working on it."

## Validation

`ceo playbook scan` validates frontmatter in order:
1. `name` present and well-formed.
2. Duplicate `name` (vault vs repo or within either tree) → shadow / skip.
3. `runner` (if set) is in `CEO_VALID_RUNNERS`.
4. `status` (if set) is in `CEO_VALID_STATUSES`.
5. `artifact` (if set) starts with `CEO/` and contains only `{TODAY}` / `{HOST}` tokens.
6. `requires`, `inputs` shapes are valid JSON arrays.
7. For `runner: ollama` / `ollama-think`, the model must be locally available (unless `CEO_OLLAMA_SKIP_PROBE=1`).

Any failure: the playbook is skipped with a diagnostic line. The dispatcher will not run a skipped playbook; the registry will not list it.

## Preview a scan

```bash
ceo playbook scan --dry-run
```

Walks the same parse path and prints the cron block that would be installed, without touching the crontab or rewriting the registry. Useful when iterating on a draft, or when verifying what a sibling machine would do after a `git pull`.

## Related

- [`ceo-automated-writers-are-playbooks`](../../../.claude/rules/ceo-automated-writers-are-playbooks.md) — registered playbooks are the only sanctioned writers under `$CEO_VAULT/CEO/`.
- [`enum-config-typo-fallback`](../../../.claude/rules/enum-config-typo-fallback.md) — the parse-time rejection discipline this schema enforces.
- nhangen/claude-ceo#90 — the issue that introduced `draft` / `disabled` and the `--dry-run` flag.
