---
name: count-blessings
description: EA skill — maintain a gratitude list surfaced in the morning brief. Use when the user wants to add, list, or view today's blessings. Subcommands: add, list, show.
version: 0.1.0
---

# Count Blessings

Thin wrapper over `scripts/count-blessings.sh`. Dispatch on the user's first argument.

## Invocation

Resolve the script path relative to this plugin root, then pass the user's arguments through:

```bash
PLUGIN_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
bash "$PLUGIN_ROOT/scripts/count-blessings.sh" "$@"
```

## Commands

- `/count-blessings add "text"` — append a blessing
- `/count-blessings list` — show all blessings numbered
- `/count-blessings show` — show today's three picks

## Notes

- Adds are persisted to `CEO/blessings.md` in the Obsidian vault (resolved via `$CEO_VAULT` or `$HOME/Documents/Obsidian`).
- Today's picks live in `CEO/cache/blessings-today.md` and are regenerated once per day by `ceo-gather.sh`.
- Morning brief surfaces the three picks under `## Personal / ### Blessings`.
