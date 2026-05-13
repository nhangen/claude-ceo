---
name: disk-monitor
description: Hourly disk/wsl-crashes check on ML-1; writes state to alerts/disk.md, escalates to inbox on sustained firing
trigger: cron
schedule: "0 * * * *"
preflight: none
tier: low-stakes write
status: active
runner: script
script: ceo-disk-monitor.sh
---

# Disk Monitor (ML-1)

Shell-only playbook. Runs hourly on ML-1 (WSL2). Checks:

- C: drive free space — alert if < 50 GB
- `C:\Users\nhang\AppData\Local\Temp\wsl-crashes\` folder size — alert if > 5 GB

## Origin

Written May 11 2026 by a Claude Code session on ML-1 as a follow-up to a 1.126 TB WSL node crash-dump cleanup (see `Projects/Development/nhangen/claude-ceo/2026-05-11-c-drive-exhaustion-wsl-crash-dump.md`). The first version was an append-on-every-fire signal generator, which spammed `CEO/inbox/disk-alert.md` after a May 11 CARLA crash dropped a 14 GB dump into `wsl-crashes/`. This version is a state machine.

## Outputs

| File | Mode | When |
|---|---|---|
| `CEO/alerts/disk-<host>.md` | overwrite | Every run. One entry per host, current state. Frontmatter: `status: firing\|clear\|unknown`, `since:`, `last_check:`, `host:`, `dump_folder_gb:`, `c_free_gb:`, `measurement_failed:`. Per-host so a synced vault with multiple monitors does not race. |
| `CEO/log/disk-monitor/YYYY-MM.md` | append | Every run. One line per check. Forensic history. |
| `CEO/inbox/<host>.md` | append `- [ ]` line | On `clear → firing` transition. Idempotent — does not re-append the same task line. Per-host file (`<host>` = `hostname -s`, lowercase). |

Dedupe is gated by an HTML-comment marker (`<!-- disk-monitor:<host> -->`) embedded in every task line. The marker survives user reformats (translating the message, editing wording) so the same alert never produces two active task lines. The sustained-firing re-poke appends a fresh `- [ ]` only when no unchecked line carries the marker — i.e., the prior task has been checked off — and the alert continues to fire past 24 hours.

When state transitions `firing → clear`, the playbook flips the matching `- [ ]` task in `CEO/inbox/<host>.md` to `- [done]` and appends a one-line resolution note. The rewrite is exact-string match (no regex), so hosts with regex metacharacters in their names rewrite correctly.

## Measurement-failure invariant

If `du`, `df`, or either measured path is unavailable, the run is treated as measurement-failed: `status:` is preserved from the prior run (`firing` stays firing; `clear` stays clear), inbox is never mutated, and `measurement_failed: 1` is recorded in the alert frontmatter. A transient read error cannot silently clear an active alert.

## Documented gaps

- `.wslconfig`'s `crashDumpFolder=` only suppresses WSL-guest-side dumps. Windows-native binaries running Linux builds *under* WSL (e.g. CARLA's Linux UE4 binary) still write to `wsl-crashes/` via Windows Error Reporting. The monitor can detect this but does not clean it up — cleanup is human work via the inbox task.
- Hourly cadence is intentional (early detection). Suppress duplicate inbox tasks via idempotency, not by lengthening the schedule.

## Install

Registered automatically by `ceo playbook scan`. Repo playbooks under `docs/playbooks/` are picked up alongside vault playbooks. Cron lines bake in `$INSTALL_DIR` at scan time; re-run `ceo playbook scan` if the repo moves.

## Disable

Set `status: inactive` in this file (or in a vault override at `$CEO_VAULT/CEO/playbooks/disk-monitor.md`) and re-scan.
