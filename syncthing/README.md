# Syncthing Configuration for CEO Agent

## Overview

Both machines need to **read** all vault files. The write-domain separation is enforced by convention (which machine writes to which files), not by Syncthing ignoring files.

Use a single `.stignore` on both machines to exclude non-vault noise. The CEO's scripts and playbooks enforce write discipline — Syncthing syncs everything bidirectionally.

## .stignore (same on both machines)

Copy `shared.stignore` to `~/Documents/Obsidian/.stignore` on both Mac and WSL.

## Folder Type

Set the Syncthing folder type to **Send & Receive** on both machines. Do NOT use Send Only or Receive Only — both sides need to push changes.

## Write Domain Enforcement

Write domains are enforced by the CEO's scripts and documented in VAULT.md, not by Syncthing config:

| Path | Mac writes | WSL writes |
|------|-----------|------------|
| CEO/AGENTS.md, IDENTITY.md, SKILLS.md, TRAINING.md | Yes | No |
| CEO/training/, playbooks/ | Yes | No |
| CEO/log/, repos.md | No | Yes |
| CEO/inbox.md | Yes (add tasks) | Yes (mark done/failed) |
| CEO/approvals/pending.md | Yes (mark [x]) | Yes (add proposals) |
| CEO/delegations/ | Yes (CEO Review) | Yes (create + results) |
| Profile.md, Pending.md, People/, etc. | Yes | No |

## Swarm State: What Syncs and What Doesn't

The swarm model (multiple hosts) splits CEO state into synced (shared topology)
and host-local (per-machine) files:

| Path | Synced? | Why |
|------|---------|-----|
| `CEO/registry.json` | **No — host-local** | Generated per host at `~/.ceo/registry.json` by `ceo playbook scan`. Syncing it would let two hosts rewrite the same file and produce `.sync-conflict` copies. Ignored in `shared.stignore`. |
| `CEO/swarm.json` | **Yes — shared topology** | Describes the swarm itself: which hosts participate (`hosts[]`) and which host owns each `single`-scope playbook (`owners{}`). Every host must read the same file. |
| `CEO/heartbeats/<host>.json` | **Yes — per-host liveness** | One file per host (host-namespaced), so two hosts never write the same path. The offline-owner alert reads these to detect a host whose heartbeat has gone stale. |

A stale `CEO/registry.json` may linger in the vault on first migration from a
single-host install; the `shared.stignore` entry stops it from syncing going
forward (delete the vault copy during migration — see `docs/migration.md`).

## Conflict Detection

If both machines write to the same file within a sync window, Syncthing creates `.sync-conflict-*` files. The CEO's cleanup playbook scans for these and logs them as errors.

## Troubleshooting

Check for conflict files:
```bash
find ~/Documents/Obsidian/CEO -name "*.sync-conflict-*"
```

If conflicts appear frequently, check which machine is violating write domains.
