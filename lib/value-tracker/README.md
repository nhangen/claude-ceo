# value-tracker

Internal CEO library — post-hoc analyser of MCP tool-call value from Claude Code and Cursor sessions.

Reads:

- Claude Code session JSONLs (`~/.claude/projects/*/...jsonl`)
- Cursor SQLite tool bubbles (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`)

Classifies each MCP tool call as plausibly-used, trivially-wasted, or unclear by checking whether downstream turns echo symbols from the result. Writes a terminal report, a JSON snapshot, and an Obsidian note.

## Not a public CLI

This started as `nhangen/mcp-value-tracker` (standalone Bun CLI). It was folded into claude-ceo to ship as a cron-fired playbook instead of an npm package — the personal "did Claude use the tools it called?" question is better served by an unattended daily report than a CLI you'd forget to run.

The directory keeps a clean boundary (no imports from ceo internals) so it can be extracted back into a standalone CLI later if the use case grows beyond personal analytics.

## Invocation

Not invoked directly. Wrapped by `scripts/ceo-value-tracker.sh`, which is dispatched by the `value-tracker` playbook on the ceo cron schedule.

For ad-hoc runs:

```bash
bun ~/code/claude-ceo/lib/value-tracker/src/cli.ts --since "$(date -v-1d +%Y-%m-%d)" --dry-run
```

## Layout

```
src/
├── cli.ts            entry point (#!/usr/bin/env bun)
├── ingest/           per-source ingestors (claude-jsonl, cursor-sqlite)
├── servers/          per-server tool registries (gitnexus, etc.)
├── classify.ts       used / wasted / unclear bucketing
├── rollup.ts         per-tool aggregation
├── format.ts         terminal + Obsidian renderers
├── snapshot.ts       JSON snapshot writer
├── extract.ts        symbol extraction from tool results
├── signals.ts        downstream-echo detection
├── cli-detect.ts     classify Bash-routed CLI calls (gitnexus analyze, etc.)
├── jsonl.ts          line-by-line JSONL reader
└── types.ts

tests/                bun test
```

## Tests

```bash
cd ~/code/claude-ceo/lib/value-tracker && bun install && bun test
```

50 tests covering ingest, classify, rollup, format, snapshot, CLI detection, Cursor SQLite extraction.

## Fresh-clone install

Cron invocation works without `bun install` — the engine has zero runtime deps, and `bun src/cli.ts` resolves the TS imports directly. `bun install` is only needed for `bun test` / `bun tsc --noEmit`, both of which require the dev-deps (`typescript`, `@types/bun`).

After `git clone` or worktree creation, run once:

```bash
cd lib/value-tracker && bun install
```
