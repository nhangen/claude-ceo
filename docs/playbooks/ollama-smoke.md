---
name: ollama-smoke
description: Weekly live-stack canary for local ollama / ccr / oll-code integration
trigger: cron
schedule: "0 8 * * 1"
preflight: none
tier: read
status: active
scope: single
runner: script
script: ceo-ollama-smoke.sh
artifact: CEO/alerts/ollama-smoke.md
---

# Ollama Smoke Canary

Shell-only playbook. The dispatcher invokes `scripts/ceo-ollama-smoke.sh` directly — no LLM call.

## What it does

Runs `ollama-agent/tests/integration_smoke.sh` against the local model stack (`ollama`, `claude-code-router`, and `oll-code`). Manages state and escalation:

- Writes `<VAULT>/CEO/alerts/ollama-smoke.md` with standard alert frontmatter (`status: clear|firing`, `since`, `last_check`, and `pass`/`fail`/`skip` counts).
- On transition to `firing` (a real `FAIL > 0`), idempotently appends an actionable escalation to `CEO/inbox.md`.
- When all checks skip (`PASS=0` and `FAIL=0`), records `status: clear` with `stack: absent` to distinguish an unconfigured stack from verified health.

## Scope and scheduling

- **Single scope**: Runs only on the ollama host (**ML-1**).
- **Weekly schedule**: Runs weekly on Monday morning (`0 8 * * 1`).

## Install

Registered automatically by `ceo playbook scan`. Repo playbooks under `docs/playbooks/` are synced to `$CEO_VAULT/CEO/playbooks/` via `ceo playbook sync`.
