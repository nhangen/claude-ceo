# Archived playbooks

Retired playbooks, kept for reference. Nothing here dispatches.

`ceo playbook scan` enumerates `<dir>/*.md` non-recursively (`scripts/ceo:1400`), so
files in this subdirectory are never registered and never scheduled. That is the only
thing keeping them inert — do not move one back up a level to "look at it."

To revive one: move it to `docs/playbooks/`, re-check its frontmatter against
`docs/playbooks/SCHEMA.md` (the schema has moved on), restore any owner entry in
`CEO/swarm.json`, then `ceo playbook scan` on the owner host.

## Contents

Retired 2026-08-12 when Nathan's AwesomeMotive employment ended. All three read
AM-only data sources that are no longer reachable.

| Playbook | Was | Depended on |
|----------|-----|-------------|
| `workload-report` | active, `0 7 * * 1,3` | GitHub org project 80 (AM board) — assignees, sprints, Estimate field |
| `story-points` | disabled | Same board's Estimate field, via the `story-points` skill |
| `auto-review` | draft, never enabled | A scan across ~27 `awesomemotive/*` repos |

Removed alongside them, and *not* archived because they were dead code rather than
configuration (recoverable from git history at `cbd060d~1`):

- `scripts/ceo-zenhub-sprint.sh` + its test — queried the ZenHub GraphQL API, dead
  since ZenHub access ended 2026-06-29.
- `scripts/ceo-gather-sprint.test.sh`.
- The `CURRENT_SPRINT_ITEMS` / `CURRENT_SPRINT_COUNT` block in `scripts/ceo-gather.sh`.
  Worth knowing: `ceo-cron.sh` has no `current_sprint` branch in its injection
  vocabulary, so these were computed on every gather and injected into no prompt.
  The `morning` playbook's instruction to rank by sprint membership had therefore
  never taken effect; its ranking rule was rewritten rather than repaired.
- `preflight_has_auto_review_prs()` in `scripts/ceo-cron.sh`, which shelled out to the
  `auto-review` skill's AM repo scanner.
