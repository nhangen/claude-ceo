---
name: process-watchdog
description: Checks for known orphaned runaway processes and terminates only those beyond age/CPU thresholds
trigger: cron
schedule: "*/10 * * * *"
preflight: none
tier: low-stakes write
status: active
scope: each
runner: script
script: ceo-process-watchdog.sh
artifact: CEO/alerts/process-watchdog-{HOST}.md
---

# Process Watchdog

Shell-only playbook. Runs every ten minutes through `ceo-schedulerd`/Cronbird.

Default target:

- command contains `node /opt/homebrew/bin/gitnexus mcp`
- parent PID is `1`
- elapsed runtime is at least 30 minutes
- current CPU is at least 20%

The script sends `TERM` first, waits five seconds, then sends `KILL` only if the
same PID still matches the watchdog criteria. Attached MCP processes are ignored
because their parent PID is not `1`.

## Overrides

| Variable | Default |
|---|---|
| `CEO_PROCESS_WATCHDOG_MATCH` | `node /opt/homebrew/bin/gitnexus mcp` |
| `CEO_PROCESS_WATCHDOG_LABEL` | `gitnexus-mcp` |
| `CEO_PROCESS_WATCHDOG_MIN_AGE_MINUTES` | `30` |
| `CEO_PROCESS_WATCHDOG_MIN_CPU_PERCENT` | `20` |
| `CEO_PROCESS_WATCHDOG_TERM_GRACE_SECONDS` | `5` |
| `CEO_PROCESS_WATCHDOG_KILL_AFTER_TERM` | `1` |
| `CEO_PROCESS_WATCHDOG_DRY_RUN` | `0` |

## Outputs

| File | Mode | When |
|---|---|---|
| `CEO/alerts/process-watchdog-<host>.md` | overwrite | Every run. Current state and the PIDs acted on. |
| `CEO/log/process-watchdog/YYYY-MM.md` | append | Every run. One forensic summary line. |
| Discord alert webhook | post | Only when at least one process is actually killed. Clear/no-op checks are silent. |

The alert deliberately reports only the target label and thresholds, not the full
process command line. Some providers place credentials in process arguments.

Discord delivery uses the regular `discord_webhook` secret and honors
`notify_events: "off"`. It does not post on every ten-minute check, even when
`notify_events` is `"all"`.

## Install

Registered automatically by `ceo playbook scan`. On macOS, scan updates
`~/.ceo/registry.json`; the existing `ceo-schedulerd` daemon reads that registry.

## Disable

Set `status: disabled` in this file or a vault override at
`$CEO_VAULT/CEO/playbooks/process-watchdog.md`, then run `ceo playbook scan`.
