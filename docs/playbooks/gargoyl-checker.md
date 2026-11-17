---
name: gargoyl-checker
description: Five-minute deterministic watchdog for the dev.gargoyl.monitor LaunchAgent; Discord and an alerts note on healthy->failed / failed->recovered transitions only
trigger: cron
schedule: "*/5 * * * *"
preflight: none
tier: low-stakes-write
status: active
scope: each
runner: script
script: ceo-gargoyl-checker.sh
---

# Gargoyl Checker

Deterministic, model-free watchdog for the `dev.gargoyl.monitor` LaunchAgent.
It reads status only and never drives Darkbloom (parse-don't-execute). Hosted
here since nhangen/claude-ceo#653; superseded the untracked
`nhangen/llm-tools/scripts/gargoyl-checker.sh` copy (spec:
`~/.claude/specs/2026-11-05-gargoyl-monitor-checker.md`, ticket
nhangen/llm-tools#1144).

Checks, in order — any failure exits 1 (the dispatcher records the failure):

1. Monitor logs exist (`~/Library/Logs/Gargoyl/monitor.{stderr,stdout}.log`).
2. `launchctl list` has a `dev.gargoyl.monitor` job reporting `-` or `0`.
3. Fresh `Traceback`/`FATAL`/`Uncaught` shapes in the last 20 KB of
   `monitor.stderr.log`. stderr *freshness* alone is a logged note, not a
   failure — the monitor is event-driven and legitimately silent for days
   (calibrated 2026-11-05).
4. A running `gargoyl monitor` process exists.
5. The dashboard on `127.0.0.1:8766` answers a loopback GET within 5 s
   (process present but wedged).
6. `fleet.json` parses as JSON. Its `connection` value is informational only —
   it is a fetch-time snapshot, not live health (calibrated 2026-11-05).
7. `/report.json`'s newest snapshot is <= 120 s old. Collection cadence is the
   wedge signal; equal traffic counters across reads are not (dashboard's own
   semantics).

The loopback probes, launchd-monitor checks, and the collector-cadence wedge
probe are intentional and must not be removed.

## Outputs

| Channel | When |
|---|---|
| `CEO/alerts/gargoyl-checker-<host>.md` | On transitions only: overwritten with current state (`status: firing\|clear`, `since:`, `last_check:` frontmatter) plus the transition report. No per-run write — `last_check` records the last transition, not the last probe. |
| Discord (`discord_webhook` secret) | Transitions only: one message on healthy->failed, one on failed->recovered. Repeat failures stay silent. Delivery failures are logged with the HTTP code, never the URL (no-secrets-in-logs). |
| `~/Library/Logs/Gargoyl/checker/checker.log` | Every run. Host-local forensic line per check plus the informational notes. |

`notify_events: "off"` in `CEO/settings.json` silences the Discord voice (the
alerts note still writes). Under `ceo-cron.sh` the script reports
`failure-notified` on failing runs — it owns failure notification, so the
dispatcher does not re-post the same failure every five minutes — and `noop`
on green runs.

## Overrides

| Variable | Default |
|---|---|
| `GARGOYL_MONITOR_LOG_DIR` | `~/Library/Logs/Gargoyl` |
| `GARGOYL_FLEET_JSON` | `~/Library/Application Support/Gargoyl/fleet.json` |
| `GARGOYL_DASHBOARD_URL` | `http://127.0.0.1:8766` |
| `GARGOYL_MONITOR_PGREP_PATTERN` | `ML-AI/gargoyl/.venv/bin/gargoyl monitor` |
| `GARGOYL_CHECKER_LOG_DIR` | `~/Library/Logs/Gargoyl/checker` |
| `GARGOYL_LAUNCHCTL_BIN` / `GARGOYL_PGREP_BIN` / `GARGOYL_CURL_BIN` | PATH binaries (test seams) |
| `GARGOYL_DISCORD_WEBHOOK_URL` | unset — webhook comes from the `discord_webhook` secret in `~/.config/claude-ceo/secrets.json` |

## Install (cutover from the launchd timer)

The 5-minute cadence moved from the standalone `dev.nhangen.gargoyl.checker`
LaunchAgent to the `ceo-schedulerd`/cronbird registry. `scripts/gargoyl-checker-cutover.sh`
(a human runs it) registers the playbook on this host — `ceo playbook enable gargoyl-checker`
then `ceo playbook scan` — and boots out the legacy plist. `--retire-only` does
just the launchd retirement; `--dry-run` prints without acting.

This is `scope: each`, macOS-only (launchctl, `~/Library/Logs`): enable it only
on the host that runs the monitor (`ceo playbook enable gargoyl-checker`).

## Origin

Written 2026-11-05 in llm-tools as an untracked calibrated script, per the
option-1 local-watchdog decision (no model, no AI analyst). Moved into this
repo as a registered playbook by #653; the llm-tools copy is retired and
nhangen/llm-tools#1144 cross-links here.

## Documented gaps

- The alerts note is written on transitions only, so a steady-firing or
  steady-green monitor leaves `last_check` stale by design; per-run evidence
  is in the host-local checker log.
- The checker reports only the first failing probe per run (fail-fast, matching
  the calibrated original); a later probe failure surfaces on the next run.
- An unreadable prior note (`status:` missing) suppresses the transition
  notice for that run — the checker cannot tell fresh failure from repeat, and
  would rather stay silent than double-post. The note is repaired and the next
  run classifies normally.
- If a transition's alerts-note write or Discord post fails, the state repair
  happens on the next run (transition re-detected); the failed delivery is
  logged with its HTTP code.
