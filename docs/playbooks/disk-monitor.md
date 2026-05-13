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
| `CEO/alerts/disk.md` | overwrite | Every run. One entry, current state. Frontmatter: `status: firing\|clear`, `since:`, `last_check:`, `dump_folder_gb:`, `c_free_gb:`. |
| `CEO/log/disk-monitor/YYYY-MM.md` | append | Every run. One line per check. Forensic history. |
| `CEO/inbox/ML-1.md` | append `- [ ]` line | Only on state transition clear→firing, OR sustained firing past 24 hours. Idempotent — does not re-append if the same task line already exists. |

When state transitions firing→clear, the playbook flips the matching `- [ ]` task in `CEO/inbox/ML-1.md` to `- [done]` and appends a one-line resolution note.

## Documented gaps

- `.wslconfig`'s `crashDumpFolder=` only suppresses WSL-guest-side dumps. Windows-native binaries running Linux builds *under* WSL (e.g. CARLA's Linux UE4 binary) still write to `wsl-crashes/` via Windows Error Reporting. The monitor can detect this but does not clean it up — cleanup is human work via the inbox task.
- Hourly cadence is intentional (early detection). Suppress duplicate inbox tasks via idempotency, not by lengthening the schedule.

## Install

Registered automatically by `ceo playbook scan`. Repo playbooks under `docs/playbooks/` are picked up alongside vault playbooks. Cron lines bake in `$INSTALL_DIR` at scan time; re-run `ceo playbook scan` if the repo moves.

## Disable

Set `status: inactive` in this file (or in a vault override at `$CEO_VAULT/CEO/playbooks/disk-monitor.md`) and re-scan.
