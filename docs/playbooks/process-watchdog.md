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

Shell-only playbook. Runs every ten minutes through `ceo-schedulerd` on each host
where it has been enabled (see Install).

Default target:

- command contains `node /opt/homebrew/bin/gitnexus mcp`
- parent PID is `1`
- elapsed runtime is at least 30 minutes
- current CPU is at least 20%

Immediately before each signal the script re-reads the PID and acts only if it
is still an orphan running the target command (see Documented gaps for the
window that leaves). It sends
`TERM`, waits five seconds, and sends `KILL` only if the process is still alive.
Attached MCP processes are ignored because their parent PID is not `1`.

Each candidate ends with one result in the alert table:

| Result | Meaning | Exit |
|---|---|---|
| `killed` | The process is gone. | 0 |
| `gone-before-signal` | It exited or changed identity before the first signal. Nothing was sent. | 0 |
| `would-kill` | Dry run. Nothing was sent. | 0 |
| `survived-term` | Still alive after `TERM` with `KILL_AFTER_TERM=0`. | 1 |
| `failed` | A signal failed, the process survived `KILL`, or `ps` could not confirm what now holds the PID. | 1 |

If `ps` returns no process table, the run exits 1 and leaves the previous alert
in place rather than reporting `clear`.

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
| `CEO/alerts/process-watchdog-<host>.md` | overwrite | Every run. Current state and the PIDs acted on. `since` holds the first run that saw the current status. |
| `CEO/log/process-watchdog/YYYY-MM.md` | append | Every run. One forensic summary line. |
| Discord alert webhook | post | Only when at least one process is actually killed. Clear/no-op checks are silent. |

The alert deliberately reports only the target label and thresholds, not the full
process command line. Some providers place credentials in process arguments.

Discord delivery uses the regular `discord_webhook` secret and honors
`notify_events: "off"`. It does not post on every ten-minute check, even when
`notify_events` is `"all"`. A failed post (a non-2xx response or a transport error)
is reported on stderr and in `/tmp/process-watchdog-notify.log`. The kill itself
is still recorded in the alert and the log.

## Install

Registered automatically by `ceo playbook scan`. On macOS, scan updates
`~/.ceo/registry.json`; the existing `ceo-schedulerd` daemon reads that registry.

This is `scope: each`, so nothing runs until you enable it on a host:
`ceo playbook enable process-watchdog`. Enable it only on hosts that run the
Homebrew `gitnexus mcp` (today: the MacBook). It signals processes, so it is a
deliberate exception to the rule that non-owner hosts enable only each-scope
telemetry.

On MBP-2026, retire the hand-rolled launchd agent that runs an older copy of
this script before you enable it (#509). Otherwise two schedulers run it.

## Disable

Set `status: disabled` in this file or a vault override at
`$CEO_VAULT/CEO/playbooks/process-watchdog.md`, then run `ceo playbook scan`.

## Origin

Written 2026-08-17 on the MacBook to clean up orphaned `gitnexus mcp` servers:
node processes whose parent session had exited, left behind under launchd
(PPID 1) and spinning at high CPU. It lived only in the vault and as untracked
files until #459 moved it into the repo.

## Documented gaps

- The default match is a macOS Homebrew path, so on Linux and WSL hosts it
  matches nothing unless `CEO_PROCESS_WATCHDOG_MATCH` is overridden.
- The match is a plain substring of the command line, and only one target can be
  configured per host.
- Thresholds come from `CEO_PROCESS_WATCHDOG_*` environment variables only. There
  is no vault or registry setting for them.
- Bash cannot re-check identity and send a signal atomically. The re-check
  narrows the PID-reuse window to the time between `ps` and `kill`; it does not
  close it.
