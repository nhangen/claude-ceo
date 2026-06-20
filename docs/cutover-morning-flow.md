# Morning Flow Cutover (ML-1 only)

This runbook documents the runtime steps needed to activate the `morning` playbook
and retire the four legacy playbooks. All file/frontmatter changes are already
committed in `nh/feat/ceo-morning-flow`. The steps below are deferred runtime
actions that must run on ML-1.

## Prerequisites

- Branch `nh/feat/ceo-morning-flow` is merged to master.
- You are on ML-1 (check: `hostname` must be ML-1).
- Per `ceo-scan-only-on-ml1`: `ceo playbook scan` installs host-local launchd
  agents and rewrites the synced `CEO/registry.json`. Never run it on the
  MacBook or any other host.

## Step 1: Run `ceo playbook scan` on ML-1

```bash
ceo playbook scan
```

This regenerates `~/.ceo/registry.json` from frontmatter and registers the
`morning` schedule via ceo-schedulerd. The four legacy playbooks
(`morning-scan`, `morning-brief`, `pending-drip`, `pr-triage`) have
`status: disabled` in their frontmatter and will be de-scheduled automatically.

## Step 2: Add `morning` to `discord_report_triggers` (vault CEO/settings.json)

Edit the synced vault file `CEO/settings.json`. Add `"morning"` to the
`discord_report_triggers` array. **Keep `"morning-brief"` in the array for
ONE cycle** while you diff the outputs (see Step 3).

Example delta:
```json
"discord_report_triggers": ["morning-brief", "morning"]
```

This is a vault edit — do it directly in Obsidian or via a terminal on ML-1.
Do NOT commit `CEO/settings.json` to this repo; it lives in the synced vault.

## Step 3: One-cycle diff (1-2 days)

For the first 1-2 weekday mornings after cutover, compare:

- New `morning` briefing (written to `CEO/reports/YYYY-MM-DD.md`)
- Legacy `morning-brief` output (check Discord second message)

Confirm the new briefing has parity or improvement on:
- Priority ranking (sprint membership as primary key)
- Overnight digest coverage
- Predicted-priorities block presence

## Step 4: Remove `morning-brief` from `discord_report_triggers`

Once parity/superiority is confirmed, edit `CEO/settings.json` again:

```json
"discord_report_triggers": ["morning"]
```

Leave legacy playbooks in their `status: disabled` state — disabled, not deleted,
so they can be re-enabled for comparison if needed.

## Step 5: Register `morning` as an automated writer

Per `ceo-automated-writers-are-playbooks`: `morning` writes to `CEO/model/YYYY-MM.md`
(the learning ledger). Ensure the registry entry in `CEO/registry.json` declares
this output under `outputs`. If the scan did not auto-populate it, add manually:

```json
{
  "name": "morning",
  "outputs": ["CEO/reports/", "CEO/model/"]
}
```

The `CEO/model/` path is write-append (one dated entry per run); `CEO/reports/`
is the daily briefing. Both are sanctioned output locations per
`CEO/rules/output-locations.md`.

## Summary of status changes (committed)

| Playbook | Before | After |
|---|---|---|
| `morning` | draft | **active** |
| `morning-scan` | active | **disabled** |
| `morning-brief` | active | **disabled** |
| `pending-drip` | active | **disabled** |
| `pr-triage` | active | **disabled** |

## What was NOT done in this commit

- `ceo playbook scan` was NOT run (ML-1 runtime action).
- Vault `CEO/settings.json` was NOT edited (outside this repo; deferred runtime step).
- No launchd agents were installed.
- No crontab entries were modified.
