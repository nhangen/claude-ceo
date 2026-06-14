# Multi-Machine Install Guide

Set up CEO across two or more machines from scratch, sharing one Obsidian vault with no write-conflicts and no double token spend.

The swarm model in one paragraph: playbook `.md` *definitions* are synced (a shared catalog), but the generated registry is host-local (`~/.ceo/registry.json`) — each host scans its own. A synced `CEO/swarm.json` holds the topology (`hosts`) and the owners of `single`-scope playbooks. Each host runs the intersection of the shared catalog, its host-local enablement (`each` scope), and the swarm owners (`single` scope). See [`playbooks/SCHEMA.md`](playbooks/SCHEMA.md#swarm-selection-model) for the full selection predicate.

Migrating an existing single-host install rather than starting fresh? See [`migration.md`](migration.md).

## 1. Prerequisites

`ceo setup` checks for these on each machine:

- **git** and **gh** (GitHub CLI), authenticated — `gh auth login`.
- **jq** — required for swarm bootstrapping and registration.
- **yq** — required by `ceo playbook scan`. ([install](https://github.com/mikefarah/yq#install))
- **Syncthing** — running on every machine to sync the Obsidian vault. ([install](https://syncthing.net/))
- **Claude Code** with an authenticated subscription (`claude --print`).
- **bun** (≥ 1.3.5) — runtime for the `ceo-schedulerd` scheduler daemon.
- An **Obsidian vault** with `CEO/`, `VAULT.md`, and `Profile.md`, shared by Syncthing across all machines.

`ceo setup` installs what it can on macOS/Linux and warns (without failing) on Syncthing / yq / Claude Code so you can install them yourself; missing git/gh/jq fail the run.

## 2. Set a UNIQUE `CEO_HOSTNAME` per machine

Host identity defaults to `hostname -s`. If two machines resolve to the same short hostname and you let it auto-resolve, the swarm-registration **collision guard refuses** the second registration — it cannot tell whether the existing `hosts[]` entry is this machine or a clone, and a silently shared id leads to double-ownership (and double token spend) of a `single`-scope playbook.

An explicit `CEO_HOSTNAME` is trusted: you have asserted the id is unique, so re-registration becomes a safe no-op. Set a distinct value on **every** machine, even when `hostname -s` already differs — it makes identity explicit and stable.

`~/.ceo/config` is sourced as a shell file, so add a line there:

```bash
mkdir -p ~/.ceo
echo 'CEO_HOSTNAME=ml-1' >> ~/.ceo/config   # ml-2, mac-mini, … on the others
```

(Or export `CEO_HOSTNAME` in your shell before running `ceo`.) Do this **before** `ceo setup` so the host registers under the right id.

## 3. Machine 1 — create the swarm

```bash
ceo setup
```

Setup detects/writes the vault path into `~/.ceo/config`, then bootstraps `CEO/swarm.json` and registers this host into `hosts[]`. Machine 1 is the one that *creates* `swarm.json`.

Then bring up Syncthing and share the Obsidian vault to the other machines (Send & Receive everywhere) — see the [README](../README.md#syncthing). Wait for the vault (including the newly created `CEO/swarm.json`) to fully sync before touching machine 2.

## 4. Machine 2 — join after the vault has synced

**Order matters.** Machine 1 creates `swarm.json`; machine 2 joins it. Run `ceo setup` on machine 2 only **after** the vault has synced, so setup finds the existing `swarm.json` and registers this host into it (rather than two machines creating it concurrently and producing Syncthing conflict copies):

```bash
ceo setup                       # with CEO_HOSTNAME=ml-2 already in ~/.ceo/config
```

If the host id is ambiguous, setup prints the collision-guard message and does **not** register — set a unique `CEO_HOSTNAME` and re-run. Repeat for each additional machine.

## 5. Scan playbooks on each host

The generated registry is host-local, so scan on **every** machine:

```bash
ceo playbook scan
```

This reads the synced playbook definitions and writes `~/.ceo/registry.json` for that host. (`ceo setup`'s final step offers to run this for you.) Preview without writing via `ceo playbook scan --dry-run`.

## 6. Select what runs where

```bash
ceo playbook list                 # per-host view: scope, status, current state
```

- **`each`-scope** playbooks (run on every host where enabled):

  ```bash
  ceo playbook enable <name>      # run on THIS host
  ceo playbook disable <name>     # stop on THIS host
  ```

- **`single`-scope** playbooks (run on exactly one owner — guarantees no double token spend; an unowned single-scope playbook runs nowhere):

  ```bash
  ceo playbook assign <name> <host>
  ```

`enable`/`disable` are rejected for `single`-scope playbooks, and `assign` is rejected for `each`-scope — `ceo playbook list` tells you which is which.

## 7. Verify

On each host:

```bash
ceo doctor                # deps, vault, scheduler daemon, auth
ceo swarm doctor          # detect swarm.json sync-conflict copies (--fix to heal)
ceo swarm owners-health   # flag single-scope owners whose heartbeat has gone stale
```

`ceo swarm doctor` exits non-zero if any `swarm.sync-conflict-*.json` copy exists; `--fix` merges them back (`hosts` union, owners live-wins-per-key, max `schema_version`) and removes the copies. `ceo swarm owners-health` flags single-scope playbooks whose owner host's synced heartbeat is stale (host presumed offline → those playbooks run nowhere) and exits non-zero when any owner is stale.
