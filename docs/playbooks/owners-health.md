---
name: owners-health
description: Every 15 minutes on each host, read peers' synced heartbeats; escalate a peer whose ceo-schedulerd stopped on a permanent local-write fault, and record stale owners in alerts/owners-health-<host>.md
trigger: cron
schedule: "*/15 * * * *"
preflight: none
tier: low-stakes write
status: active
scope: each
runner: script
script: ceo-owners-health.sh
artifact: CEO/alerts/owners-health-{HOST}.md
---

# Owners Health

Shell-only playbook. Runs `ceo swarm owners-health --scheduled` every 15 minutes on each host where it is enabled, so every host watches its peers. A host never checks itself: a dead scheduler can't dispatch the check that would report it.

## What it reads

`CEO/heartbeats/<host>.json` for every peer, written by each host's `ceo-schedulerd`. When a daemon exits 78 on a permanent local-write fault, it marks its synced heartbeat with `fatal: {code, since}` and keeps the last good `ts` (#562). launchd has no per-exit-code `KeepAlive`, so on macOS that daemon respawns every 10 seconds forever. This check is how the operator hears about it.

## Outputs

| File | Mode | When |
|---|---|---|
| `CEO/alerts/owners-health-{HOST}.md` | overwrite | Every run. Frontmatter `status` (`firing` or `clear`), `since` (the last status change), and `last_check`. The body lists fatal peers and each single-scope owner's freshness. |
| `CEO/alerts/schedulerd-{HOST}.md` | overwrite (written by the daemon, not this playbook) | Written by `ceo-schedulerd` on fatal exit (`status: firing`); reset to `status: clear` on the next healthy start (#589). Provides single-host fallback visibility so the morning scan surfaces the failure even if no peer is watching. |
| `CEO/inbox/{HOST}.md` | append one `- [ ]` line | Only when a peer's heartbeat first reports `fatal`. Deduped by the `<!-- schedulerd-fatal:<peer> -->` marker, so it doesn't repeat while the line is unchecked. |

A stale owner, which is usually a laptop asleep overnight, goes to the alert file only, never the inbox. The manual `ceo swarm owners-health` still escalates a stale owner after 3 hours. The two modes keep separate state files, so a scheduled run never uses up the transition a manual run would alert on.

The script exits 0 whenever the check ran, and a firing state lives in the alert file. It exits non-zero only when the check itself failed, such as a malformed `swarm.json`. It writes `fired` to the runner outcome file when it appended an inbox line, and `noop` otherwise, so a quiet tick doesn't post a success notice under `notify_events: all`. Under the default `notify_events: failures`, the inbox and the alert file are the only channels, and the `morning` scan surfaces a firing alert.

Fatal peers are checked from every heartbeat except this host's own and Syncthing `*.sync-conflict-*` copies, whether or not `swarm.json` exists. A missing `swarm.json` skips only the owner check.

## Install / Disable

`scope: each`, so it runs only where it is enabled, and merging it enables nothing. On each host, after pulling (on ML-1, over `ssh ml1-wsl`, and pull ML-1's deploy checkout and restart `ceo-schedulerd` so the daemon writes the `fatal` mark):

```bash
ceo playbook scan
ceo playbook enable owners-health
```

Disable on one host with `ceo playbook disable owners-health`. Disable everywhere with `status: disabled` and a re-scan.

## Known gaps

- A single-host install has no peer to dispatch the owners-health check. The fallback alert at `CEO/alerts/schedulerd-<host>.md` (#589) lets the morning scan surface an exit-78 permanent fault. A daemon crash-looping on any other exit (a transient I/O error, a registry parse error) still writes no alert there.
- If every host is down, nobody is watching.
- If the disk holding the vault is also full, the daemon can't write `fatal`, and the failure is logged only to the daemon's stderr (`/tmp/ceo-schedulerd.err.log` under launchd). A peer then sees a stale heartbeat only if the failed host owns a single-scope playbook, and that goes to the alert file, not the inbox. A host that owns nothing produces no signal at all.
- A stale owner never reaches the inbox from this playbook. Run `ceo swarm owners-health` by hand, or read the alert file.

## Origin

#562, found while reviewing #526 (closes #496). #526 made a permanent local-write fault exit 78 and stopped systemd from restarting on it. launchd can't do the same.
