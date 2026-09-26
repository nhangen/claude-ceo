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

Runs `ollama-agent/tests/integration_smoke.sh` against the local model stack (`ollama`, `claude-code-router`, and `oll-code`), under a wall-clock cap (`OLLAMA_SMOKE_TIMEOUT`, default 900 seconds), and records the result as a state machine.

The smoke skips a check when its service is unreachable. On the owner host a skipped check means part of the stack is down, so only a run with no failures and no skips is healthy:

| `stack` | Meaning | `status` |
|---|---|---|
| `present` | Every check ran and passed | `clear` |
| `failing` | At least one check failed | `firing` |
| `degraded` | Some checks passed, some were skipped | `firing` |
| `absent` | Every check was skipped | `firing` |
| `harness-error` | The smoke timed out, exited 2 (missing tool), or printed no summary | `firing` |

The inbox task is appended only on a transition into `firing`, and marked `[done]` only when a previously firing stack comes back `present`. A state file with no readable `status` never touches the inbox.

## Outputs

| File | Mode | When |
|---|---|---|
| `CEO/alerts/ollama-smoke.md` | overwrite | Every run. Frontmatter carries `stack`, `pass_count`, `fail_count`, `skip_count`, and `timeout` (`<cap>s` or `none`); the body carries the smoke output with color codes stripped, plus a warning notice if run uncapped. |
| `CEO/inbox/ollama-smoke.md` | append `- [ ]` line; rewrite it to `[done]` | Append on a transition into `firing`. Rewrite on `firing → clear`. Idempotent. |

The runner outcome is `fired` only when the inbox changed, so a healthy week and a still-firing week are both silent.

## Scope and scheduling

- **Single scope**: runs only on the host that owns it in `swarm.json`. Assign it to a host that passes the Install gate below.
- **Weekly schedule**: Monday 08:00 (`0 8 * * 1`).

## Install

The owner host must run the whole stack, or every run reports `degraded` and the canary never sees a transition:

- `ollama` serving the smoke model. The smoke defaults to `gpt-oss:20b`; set `OLLAMA_SMOKE_MODEL` in the scheduler's environment to use another.
- `claude-code-router` (`ccr`) running as a service on its default port.
- `claude` and `oll-code` on the scheduler's `PATH`.

On the candidate host:

```bash
ceo playbook sync                          # repo → vault copy
ceo playbook scan                          # host-local; rewrites ~/.ceo/registry.json
bash scripts/ceo-ollama-smoke.sh           # one manual run
grep '^stack:' "$CEO_VAULT/CEO/alerts/ollama-smoke.md"   # must read: stack: present
ceo playbook assign ollama-smoke <host>    # only after a present run; unowned, it never fires
```

## Disable

Set `status: inactive` in this file and run `ceo playbook scan`.

## Origin

Issue #276: the live stack (ollama daemon, model presence, ccr transformers, the oll-code toolset cap) was only exercised by `integration_smoke.sh`, which nothing ran on a schedule, so the README's measured claims could rot silently when ollama or ccr updated underneath them.
