# Migrating an Existing Single-Host Install to the Swarm

This guide migrates a CEO install that has been running on **one** machine to
the multi-host swarm model. Setting up new machines from scratch instead? See
[`install.md`](install.md).

**Order is load-bearing.** Doing these steps out of order risks two failure
modes the swarm model exists to prevent: a token playbook running on every host
(double spend), or playbooks silently dropped (run nowhere). Do the steps in
order, on the host(s) named.

## 1. Upgrade `ceo` on all hosts first

Pull the new code on **every** machine before changing any state. A mixed fleet
(one host on the new binary, another on the old) will mis-handle the new
`scope` field and the host-local registry. Upgrade everywhere, then migrate.

## 2. Backfill `scope` on every playbook `.md`

Each playbook definition now carries a `scope` field that replaces the old
`hosts:` list. Convert every playbook:

- `hosts: ["*"]` (ran on all hosts) → `scope: each`
- `hosts: ["<one-host>"]` (ran on one host) → `scope: single`, and assign that
  host as the owner in step 4 (`ceo playbook assign <name> <host>`)

**An absent `scope` resolves to the SAFE default `single`** — the playbook runs
**nowhere** until an owner is assigned. This is deliberate: `scope` must **never**
default to `each`, because a token-spending playbook silently fanned out to
every host is exactly the double-spend this feature prevents. A missing scope
failing closed (runs nowhere, visible in `ceo playbook list`) is recoverable; a
missing scope failing open (runs everywhere) is not.

An **unknown** `scope` value (a typo like `evry`) is **rejected at scan time** —
`ceo playbook scan` skips the playbook with a `SKIP` diagnostic and exits
non-zero. Fix the typo; don't rely on a default swallowing it.

## 3. Move `registry.json` out of the synced vault

The generated registry is now **host-local** at `~/.ceo/registry.json`. Two
hosts scanning a shared copy would both rewrite it and produce Syncthing
`.sync-conflict` copies. The vault keeps only the playbook `.md` definitions
(which scan reads).

- Delete the synced copy: `rm "$CEO_VAULT/CEO/registry.json"`
- Each host regenerates its own host-local registry via `ceo playbook scan`
  (step 4 / 5).
- Update `syncthing/shared.stignore` so the vault `CEO/registry.json` is no
  longer synced (this repo already adds the ignore line — copy the updated
  `shared.stignore` to `~/Documents/Obsidian/.stignore` on every host). See
  [`syncthing/README.md`](../syncthing/README.md#swarm-state-what-syncs-and-what-doesnt)
  for what syncs (`swarm.json`, `heartbeats/`) and what doesn't (`registry.json`).

## 4. Create and populate `swarm.json`

Run `ceo setup` to bootstrap `CEO/swarm.json` and register each host into
`hosts[]`. Set an explicit **`CEO_HOSTNAME` on every machine** as the default —
not only when hostnames collide. An explicit id makes the bash (`hostname -s`)
and TS (`os.hostname().split('.')[0]`) host-id resolution byte-identical,
eliminating any rare OS divergence between the two. The registration collision
guard is the backstop: if you do let identity auto-resolve and two machines
share a short hostname, the guard refuses the ambiguous second registration
(two machines sharing one id leads to double ownership of a `single`-scope
playbook). See
[`install.md` §2–§5](install.md#2-set-a-unique-ceo_hostname-per-machine) for the
per-host setup, ordering (machine 1 creates `swarm.json`, others join after it
syncs), and the scan step.

Then assign an owner for every `single`-scope playbook (including the ones you
converted from `hosts: ["<one-host>"]` in step 2):

```bash
ceo playbook assign <single-playbook> <host>
```

A `single`-scope playbook with no owner runs nowhere — `ceo playbook list`
shows it as unowned, and `ceo swarm owners-health` will not flag it (there is no
owner to be offline). Assign every one you intend to keep running.

## 5. Retire the native crontab FIRST, then rely on the daemon

`ceo-schedulerd` is now the sole scheduler — it reads the host-local registry
and applies scope-aware per-host selection that the old `# CEO Agent` crontab
block could not. The native crontab install path is retired.

**Remove the old `# CEO Agent` crontab block BEFORE (or as) you bring up
`ceo-schedulerd` on each host.** If both the crontab block and the daemon are
live at once, they fire the same playbook twice — and the crontab block ignores
`scope`, so it runs *everything* on that host (double spend). There is no
`ceo` subcommand to remove the block; edit the crontab by hand:

```bash
crontab -l | sed '/# CEO Agent START/,/# CEO Agent END/d' | grep -v '^# CEO Agent$' | crontab -
```

(Or `crontab -e` and delete the `# CEO Agent START` … `# CEO Agent END` block.)
Then the daemon is the scheduler — see
[`install.md` §7](install.md#7-verify) for the `ceo-schedulerd` keep-alive
agent.

`ceo doctor` now flags a lingering `# CEO Agent` crontab block as a migration
leftover **regardless of whether the daemon is already running** (it is always a
leftover now that install is retired), so run `ceo doctor` on each host after
this step and clear anything it reports.

## 6. Retire the `ceo-scan-only-on-ml1` rule — POST-MIGRATION

> Do this only **after** every host is migrated and verified (step 7 passes on
> all of them).

The old operational rule "run `ceo playbook scan` only on ML-1" existed because
scan used to install host-local schedulers **and** rewrite the *synced*
`registry.json` — so scanning on a second host mutated shared state for the
whole fleet. That is no longer true: scan now writes only the **host-local**
`~/.ceo/registry.json` and installs nothing into the synced vault. Multi-host
scan is the **intended** model — every host scans its own registry.

Once migration is complete, the ML-1-only constraint is lifted: scan on every
host as a normal operation.

This rule lives **outside this repo** (in the user's global rules / `llm-tools`),
not in `claude-ceo`. Do **not** delete or edit any repo file for it — there is
nothing here to remove. This section documents only that the operational
constraint no longer applies post-migration; retiring the rule itself is a
separate change made wherever that rule is defined, after this ships.

## 7. Verify

On each host:

```bash
ceo doctor                # deps, vault, scheduler daemon, leftover crontab block
ceo swarm doctor          # detect swarm.json sync-conflict copies (--fix to heal)
ceo swarm owners-health   # flag single-scope owners whose heartbeat has gone stale
ceo playbook list         # confirm expected scope + state per playbook
```

Confirm on every host that `~/.ceo/registry.json` exists (the host-local
registry) and that `ceo playbook list` shows the scope and enablement/ownership
state you expect — no playbook unintentionally running on every host, none
silently unowned.
