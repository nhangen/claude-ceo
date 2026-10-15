---
name: fleet-readiness
description: Read-only role-aware fleet audit using the llm-tools machine registry
trigger: cron
schedule: "20 */4 * * *"
preflight: none
tier: low-stakes-write
status: draft
scope: single
runner: script
script: ceo-fleet-readiness.sh
artifact: CEO/alerts/fleet-readiness-{HOST}.md
---

# Fleet Readiness

Calls the deterministic llm-tools checker. Primary assignments and probe requirements remain in `home/.claude/olla-fleet.json`; this playbook has no independent machine roster. No LLM, installs, upgrades, credential copying, host-key acceptance, service restarts or model loads.

## Outputs

- `CEO/reports/fleet-readiness-<host>.json`: non-authoritative latest raw observation, marked `authoritative: false`; may record an observation whose later publication failed.
- `CEO/alerts/fleet-readiness-<host>.md`: the single authoritative decision record, with current verified failures, explicit unknown checks and embedded sanitized JSON state. Published atomically last, after history, observation and notification-outcome writes succeed.
- `CEO/log/fleet-readiness/YYYY-MM.md`: append-only sanitized run summaries.
- `CEO/reports/fleet-readiness-<host>-discord.json`: last acknowledged finding fingerprint, Discord message/channel IDs and timestamp; never a webhook URL.
- `CEO/reports/fleet-readiness-<host>-discord-attempt.json`: last bounded delivery attempt. A matching acknowledgment is authoritative for delivery; an attempt alone proves nothing.

The reporter publishes its observation independently of Discord delivery. The dedicated sender posts initial nonhealthy findings, changed verified failures or unknown warnings, and positively verified recoveries. It compares with the last Discord-acknowledged fingerprint, not the last observation: unsuccessful delivery remains retryable even when findings are unchanged. Three HTTP attempts are bounded to ten seconds each, with bounded backoff. Only HTTP 2xx plus a valid message receipt commits an acknowledgment. A crash after POST but before acknowledgment may duplicate a message; delivery is at least once, not exactly once or proof a person read it. Webhook values and response/error bodies are never logged.

The wrapper emits `noop` after dedicated delivery to avoid a duplicate generic success notification; global `notify_events=failures` does not suppress fleet warnings. Incomplete evidence never clears existing failures. This playbook does not create inbox tasks or perform remediation. Missing checkers and collector/report failures attempt a sanitized monitor-failure notice and exit nonzero through the existing scheduled-failure path. Only acknowledged dedicated failure delivery emits `failure-notified`, suppressing a duplicate generic message without suppressing failure accounting. Unacknowledged notification delivery itself exits nonzero.

## Installation gate

Set `LLM_TOOLS_REPO` to a persistent reviewed checkout, and `CEO_FLEET_LOCAL_CONTEXT=ml1-wsl` when running on ML1 WSL. Verify existing SSH keys/known-host trust and private reads in assigned contexts. Run manually first. Only then activate, scan and assign through `ceo playbook` on the verified owner. The desktop observer remains an independent report-freshness watchdog.

## Known gaps

Darkbloom serving/trust evidence and actual reboot survival are not yet supported by the collector and remain unknown, not healthy. This is a draft until collector and reporting tests plus the live owner-host gate pass. Existing `local-ci-health`, `disk-monitor`, `owners-health` and weekly `ollama-smoke` retain their separate responsibilities.
