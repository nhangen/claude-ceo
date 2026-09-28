---
name: local-ci-health
description: Checks ML1 Docker access, the local CI status service, and every configured runner
trigger: cron
schedule: "*/5 * * * *"
preflight: none
tier: low-stakes-write
status: active
scope: each
runner: script
script: ceo-local-ci-health.sh
artifact: CEO/alerts/local-ci-health-{HOST}.md
---

# Local CI Health

Read-only ML1 monitor for the local CI dependency chain. It checks Docker API
access, `local-ci-status.service`, the status API, and every repository returned
by that API. Runner discovery comes from the current local CI configuration
rather than a fixed repository list. A busy online runner is healthy.

The first failed check updates the alert. An inbox task appears only when the
failure is still present on the next five-minute check. Recovery closes the
active task. Failed or incomplete observations cannot clear an existing alert.
The playbook never restarts Docker, services, containers, or runners.

## Outputs

| File | Mode | When |
|---|---|---|
| `CEO/alerts/local-ci-health-<host>.md` | overwrite | Every run, with current probe and fleet state. |
| `CEO/log/local-ci-health/YYYY-MM.md` | append | Every run, one forensic summary line. |
| `CEO/inbox/<host>.md` | transition | One task after sustained failure; closed on recovery. |

## Install

Run `ceo playbook scan`, then enable the each-scope playbook on ML1 only:

```bash
ceo playbook enable local-ci-health
```

The ML1 service currently exposes its API at
`http://100.102.197.40:8876/api/status`. Override
`CEO_LOCAL_CI_STATUS_URL` if that address changes.

## Known gaps

- Provider and runner state comes from the status API, so an API outage hides
  the individual runner states while still firing the overall alert.
- The monitor records failures and recovery but does not remediate them.
- The default status URL is ML1-specific.

## Origin

Added after Docker Desktop's Ubuntu WSL integration lost
`/var/run/docker.sock` while the Windows engine and runner containers remained
healthy. The separate checks preserve that distinction.
