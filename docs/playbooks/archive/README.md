# Archived playbooks

Retired playbooks, kept for reference. Nothing here dispatches.

`ceo playbook scan` enumerates `<dir>/*.md` non-recursively (`scripts/ceo:1400`), so
files in this subdirectory are never registered and never scheduled. All three also
carry `status: disabled`. That is a separate gate, one level down: `disabled` is a valid
status, so scan does write a registry entry for such a file — but the scheduler dispatches
only `status: active` (`lib/scheduler/src/registry.ts:97`) and `ceo playbook preview` skips
it (`scripts/ceo:672`). So a file moved back up a level to "look at it" lands inert rather
than scheduled.

## Retiring a playbook

Archiving the repo copy is the last step, not the only one. `ceo playbook sync` copies
repo→vault and deliberately never deletes vault-only files (`scripts/ceo:1229-1236`), and
scan reads the vault dir *first* and lets it shadow the repo (`scripts/ceo:1396-1426`).
So a playbook archived here keeps dispatching until the vault side is dealt with:

1. Delete `$CEO_VAULT/CEO/playbooks/<name>.md` (or set `status: disabled` in it).
2. Drop the playbook's `owners{}` entry from `CEO/swarm.json`.
3. `ceo playbook disable <name>` on any host that enabled it (`~/.ceo/enabled.json`).
4. `ceo playbook scan` on the owner host so `~/.ceo/registry.json` drops the entry.
5. Move the repo copy here and set `status: disabled`.

Steps 1–2 were done for all three on 2026-08-12. Step 4 is still outstanding — it can
only run on ML-1, and until it does, that host's registry still lists them (#308).

To revive one: reverse the list. Move the file to `docs/playbooks/`, re-check its
frontmatter against `docs/playbooks/SCHEMA.md` (the schema has moved on), restore the
`CEO/swarm.json` owner entry, set a real `status:`, then `ceo playbook scan` on the owner
host. Check `preflight:` before flipping status — `auto-review`'s was deleted with it and
now reads `none`; an unknown preflight name does not block, it logs and runs anyway
(`scripts/ceo-cron.sh:1342`).

## Contents

Retired 2026-08-12 when Nathan's AwesomeMotive employment ended. All three read
AM-only data sources that are no longer reachable.

| Playbook | Was | Depended on |
|----------|-----|-------------|
| `workload-report` | active, `0 7 * * 1,3` | GitHub org project 80 (AM board) — assignees, sprints, Estimate field |
| `story-points` | disabled | Same board's Estimate field, via the `story-points` skill |
| `auto-review` | draft, never enabled | A scan across ~27 `awesomemotive/*` repos |

Removed alongside them, and *not* archived because they were dead code rather than
configuration (recoverable from git history at `cbd060d`):

- `scripts/ceo-zenhub-sprint.sh` + its test — queried the ZenHub GraphQL API, dead
  since ZenHub access ended 2026-06-29.
- `scripts/ceo-gather-sprint.test.sh`.
- The `CURRENT_SPRINT_ITEMS` / `CURRENT_SPRINT_COUNT` block in `scripts/ceo-gather.sh`,
  and with it the whole `current_sprint` input: the injection branch in
  `ceo_build_pregathered_extras`, the sprint block in `ceo_morning_raw_digest`, and the
  key's entry in `scripts/ceo`'s valid-inputs list. The signal was wired end-to-end —
  `ceo-cron-lib.sh` held the injector, which is why the string never appeared in
  `ceo-cron.sh` itself — but the ZenHub source has been unreachable since 2026-06-29, so
  the injected line read `(0 items): []` for the last six weeks. The `morning` playbook's
  ranking rule was rewritten because its input is gone, not because it never ran.
- `preflight_has_auto_review_prs()` in `scripts/ceo-cron.sh`, which shelled out to the
  `auto-review` skill's AM repo scanner.
