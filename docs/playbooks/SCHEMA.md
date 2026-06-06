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
| `model` | depends on `runner` | string | Claude model (e.g. `haiku`, `sonnet`) for `runner: claude`; Ollama tag for `runner: ollama` / `runner: ollama-think`. Ignored for `runner: script` / `runner: skill`. |
| `preflight` | recommended | function name | Bash function defined in `scripts/ceo-cron.sh` that gates whether the playbook runs (e.g. `has_unchecked_inbox`, `has_pending_items`, `none`). Missing/unknown preflight short-circuits to skip. |
| `tier` | yes | enum: `read`, `low-stakes-write`, `high-stakes` | Controls notification posture and approval gating. `read` posts the full report to Discord; writes go to an approvals queue. |
| `status` | recommended | enum: `active`, `draft`, `disabled` | See [Status semantics](#status-semantics) below. Empty/missing is treated as "not active" for back-compat but is **discouraged** — be explicit. |
| `runner` | no | enum: `claude`, `script`, `ollama`, `ollama-think`, `skill` | Dispatch shape. Default is `claude`. `script` runs `script:` directly without an LLM call. |
| `script` | required when `runner: script` | string | Relative path under `scripts/` (e.g. `ceo-value-tracker.sh`). The dispatcher resolves to `$INSTALL_DIR/scripts/<script>`. |
| `skill` | required when `runner: skill` | string | Skill name passed to the Claude Code skill invoker. |
| `bin` | no | string | If set, `ceo playbook scan` installs a `~/.local/bin/<bin-without-.sh>` symlink pointing at `scripts/<bin>`. Only created for `status: active`. |
| `inputs` | no | JSON array | Pre-gather keys the dispatcher injects into the prompt context. Empty array = no pre-gathered context. Absent = all keys (back-compat default). Unknown keys warn-and-skip at dispatch. Valid keys: `pr_data`, `pending_count`, `today_log`, `yesterday_log`, `daily_note`, `briefings_training`, `active_domains`, `pending_ask`, `scan_data`, `blessings`. |
| `requires` | no | JSON array of env-var names | Credentials the playbook needs (e.g. `["HUBSPOT_REFRESH_TOKEN"]`). `ceo creds check <name>` reports missing values. Non-array entries are warned and dropped. |
| `hosts` | no | JSON array of host names | Which machines the playbook runs on. Absent or `["*"]` → all hosts. **Recorded in the registry but not yet enforced** — the Phase-1.5 daemon consumes it; see [Host scoping](#host-scoping). Malformed values (scalar, empty array, blank element) warn and default to `["*"]`. |
| `artifact` | recommended for `runner: script` | string template | Expected output path relative to the vault. Must start with `CEO/`. Supports `{TODAY}` (YYYY-MM-DD) and `{HOST}` (short hostname). Unknown tokens reject at parse. `ceo doctor` cross-checks declared artifact vs disk for every active script that logged "completed" today. |
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

### Host scoping

The `hosts` field declares which machines a playbook may run on:

| `hosts` value | Meaning |
|---|---|
| absent | all hosts (recorded as `["*"]`) |
| `["*"]` | all hosts |
| `["ml-1", "mac-mini"]` | only those named hosts (matched against the short hostname) |
| `["*", "ml-1"]` | `*` mixed with names is reserved to mean **all hosts** — the wildcard dominates |
| scalar / `[]` / blank element | **malformed** — `ceo playbook scan` warns and records `["*"]` |

`ceo playbook scan` validates the shape at parse time and never silently scopes a playbook to nowhere or to a typo'd host: any malformed value defaults to `["*"]` with a `WARN` (per [`enum-config-typo-fallback`](../../../.claude/rules/enum-config-typo-fallback.md)). To stop a playbook entirely, use `status: disabled`, not an empty `hosts` list.

**Phase 1 records `hosts` but does not enforce it** — every host still runs every playbook regardless of scope. Enforcement arrives with the Phase-1.5 daemon, which will bump the registry `schema_version` so a non-enforcing peer binary can't run a host-scoped playbook everywhere.

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
