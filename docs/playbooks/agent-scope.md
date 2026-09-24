---
name: agent-scope
description: Weekly agent engagement scorecard — analyzes persona consult ledgers and rewrites the current month's engagement snapshot in place
trigger: cron
schedule: "0 7 * * 1"
preflight: none
tier: read
status: active
scope: single
runner: script
script: ceo-agent-scope.sh
artifact: CEO/reports/agent-scope/{MONTH}.md
---

# Agent Scope

Shell-only playbook. The dispatcher invokes `scripts/ceo-agent-scope.sh` directly — no LLM call.

## What it does

Runs `agent-scope` (from `~/.claude/skills/agent-scope/` in `nhangen/llm-tools`) against the persona consult ledgers (`CEO/agents/<name>/YYYY-MM.md`). Computes longitudinal engagement metrics across custom agent personas and writes:

- `<VAULT>/CEO/reports/agent-scope/<YYYY-MM>.md` — the monthly engagement snapshot report (sanctioned `reports/` location per `ceo-automated-writers-are-playbooks`). Declared as `{MONTH}` so `ceo doctor`'s cross-check looks at the file the tool actually writes.

## Scope and scheduling

- **Single scope**: Runs only on the owner host (**ML-1**) because it reads the synced CEO vault and produces a shared vault report.
- **Weekly schedule**: Runs weekly on Monday morning (`0 7 * * 1`). Consult ledgers are low-frequency, so weekly is enough to keep the scorecard current.
- **The snapshot is monthly and rewritten in place.** Roughly 4.3 runs land on the same `<YYYY-MM>.md`, each replacing the last — there is no per-run history. On a degraded run (a ledger file or directory it cannot read, an empty ledger root, or zero ranked agents), the tool exits 3 and writes nothing (nhangen/llm-tools#770, closing #767), and the runner fails the run without touching the snapshot. The runner relies on that exit code alone, so the host's llm-tools clone must include #770; an older launcher exits 0 on unreadable input and the run would record `fired`.
- **No inbox lines**: Output is written directly to the declared artifact under `CEO/reports/agent-scope/`.

## Install

`scope: single`, so it runs nowhere until an owner is assigned — registration alone does not schedule it:

```bash
ceo playbook assign agent-scope ML-1   # or: ceo swarm doctor
ceo playbook scan                      # host-local; rewrites ~/.ceo/registry.json
```

Verify with `ceo playbook list`: an unassigned single-scope playbook shows `owner: (none) ⚠`. Repo playbooks under `docs/playbooks/` are synced to `$CEO_VAULT/CEO/playbooks/` via `ceo playbook sync`.

## Dependencies

- Python 3 with standard library.
- `agent-scope` installed at `~/.claude/skills/agent-scope/scripts/agent-scope` (or inside `llm-tools` clone).
