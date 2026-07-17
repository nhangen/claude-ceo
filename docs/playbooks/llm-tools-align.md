---
name: llm-tools-align
description: Daily pull and re-apply of llm-tools config symlinks on this host. Silent on routine success.
trigger: cron
schedule: "30 9 * * *"
preflight: none
tier: low-stakes write
status: active
scope: each
runner: script
script: ceo-llm-tools-align.sh
---

# llm-tools Align

Shell-only playbook. Runs the canonical llm-tools align script from the local
checkout, which fast-forwards the repo only when safe and re-applies the
configured symlinks with `scripts/migrate.sh --apply`.

## Outputs

- `~/.local/state/llm-tools-align.log` — append-only local run log.
- No CEO vault output on routine success. The script writes `noop` to
  `CEO_RUNNER_OUTCOME_FILE` so scheduled success notifications stay quiet.

## Failure behavior

The run exits nonzero when the pull step fails, symlink creation is unavailable,
or migration exits nonzero. CEO records that as a scheduled playbook failure.
