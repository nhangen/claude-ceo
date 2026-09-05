---
name: norx-bookkeeping
description: Hourly due-check for the once-daily NoRx Mercury import and four-tab Google Sheets refresh
trigger: cron
schedule: "15 * * * *"
preflight: none
tier: high-stakes
status: active
scope: single
runner: script
script: ceo-norx-bookkeeping.sh
---

# NoRx Bookkeeping

Shell-only playbook. CEO and Cronbird own scheduling, missed-slot catch-up, at-most-once dispatch, and host ownership. The existing NoRx Operations runner remains the sole implementation of financial imports and Google Sheets synchronization.

The playbook checks hourly at minute 15. Before 06:15 local time it exits without work. After 06:15 it invokes the NoRx runner only when the local success marker does not contain today's date. The marker advances only after the runner exits successfully.

## Origin

Registered after the standalone Mac LaunchAgent exposed a shutdown gap. A once-daily Cronbird schedule has a maximum six-hour catch-up window, so an hourly due-check provides same-day catch-up after a later wake without replaying successful bookkeeping.

## Safety boundary

- `scope: single` prevents multiple hosts from owning financial writes.
- `runner: script` makes no LLM call.
- The NoRx runner retains its own lock, immutable import rules, preview/apply comparison, process-only production gate, exact four-tab readback, and internal failure alerts.
- The wrapper records success only after the complete NoRx runner succeeds. A failed run remains due and is retried by a later hourly check.
- A wrapper lock spans the success-marker check through the atomic marker replacement. A concurrent manual or scheduled check exits successfully without invoking the runner.
- Credentials remain in host-local secret stores. They must not be placed in this playbook, the repository, or the synced CEO vault.

## Host requirements

The default runner is `$HOME/Library/Application Support/NoRxPeptides/runtime/norx-operations/bin/daily-bookkeeping.sh`. Another owner host may set `NORX_BOOKKEEPING_RUNNER` to its permanent runtime command. That runner must already have working Mercury, SendGrid, Google, PHP, production SSH, and WordPress access from the scheduler context.

Do not assign ownership to another host until those requirements have passed a controlled run there. `scope: single` does not fail over automatically when its owner is offline.

## Declared outputs

- `$HOME/.local/state/norx-bookkeeping/ceo-last-success-date`, mode 0600, overwritten only after a complete successful run.
- The existing NoRx bookkeeping log and internal SendGrid alert paths owned by the NoRx runner.
- Standard CEO scheduler run history. This playbook does not write a separate report or inbox item.

## Cutover

Verify the credential-bearing host appears in `CEO/swarm.json` before assignment; register it through the normal `ceo setup` and swarm-doctor flow if absent. Assign exactly one owner with `ceo playbook assign norx-bookkeeping <host>`.

For the first handoff, re-read the existing NoRx log and require a complete successful run for the current local day. Atomically seed `ceo-last-success-date` with that date, scan and assign the CEO playbook, then observe one scheduled CEO no-op. Only after that no-op is recorded should the standalone `com.norx.daily-bookkeeping` LaunchAgent be unloaded and removed. This avoids arming two independent 06:15 writers.

The MBP is a temporary exception to the normal ML-1 ownership convention because the required credentials are currently bound to its Keychain. Move ownership back to ML-1 only after its complete runtime and secret boundary pass a controlled run. Verify final state with `ceo playbook info norx-bookkeeping`, `ceo doctor`, and `ceo swarm owners-health`.
