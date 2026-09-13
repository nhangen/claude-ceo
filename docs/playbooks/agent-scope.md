---
name: agent-scope
description: Weekly agent engagement scorecard — analyzes persona consult ledgers and writes a monthly engagement snapshot
trigger: cron
schedule: "0 7 * * 1"
preflight: none
tier: read
status: active
scope: single
runner: script
script: ceo-agent-scope.sh
artifact: CEO/reports/agent-scope/{TODAY}.md
---

# Agent Scope

Shell-only playbook. The dispatcher invokes `scripts/ceo-agent-scope.sh` directly — no LLM call.

## What it does

Runs `agent-scope` (from `~/.claude/skills/agent-scope/` in `nhangen/llm-tools`) against the persona consult ledgers (`CEO/agents/<name>/YYYY-MM.md`). Computes longitudinal engagement metrics across custom agent personas and writes:

- `<VAULT>/CEO/reports/agent-scope/<YYYY-MM>.md` — the monthly engagement snapshot report (sanctioned `reports/` location per `ceo-automated-writers-are-playbooks`).

## Scope and scheduling

- **Single scope**: Runs only on the owner host (**ML-1**) because it reads the synced CEO vault and produces a shared vault report.
- **Weekly schedule**: Runs weekly on Monday morning (`0 7 * * 1`). Consult ledgers are low-frequency, so weekly refresh keeps the scorecard current without churning snapshots.
- **No inbox lines**: Output is written directly to the declared artifact under `CEO/reports/agent-scope/`.

## Install

Registered automatically by `ceo playbook scan`. Repo playbooks under `docs/playbooks/` are synced to `$CEO_VAULT/CEO/playbooks/` via `ceo playbook sync`.

## Dependencies

- Python 3 with standard library.
- `agent-scope` installed at `~/.claude/skills/agent-scope/scripts/agent-scope` (or inside `llm-tools` clone).
