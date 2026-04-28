---
date: 2026-04-22
status: shipped
topic: count-blessings
---

# Count Blessings — Design Spec

> **Update 2026-04-23:** Shipped as PR [#2](https://github.com/nhangen/claude-ceo/pull/2) (merge `2ea9723`). Post-merge revision dropped the `skills/ea/count-blessings/SKILL.md` slash skill — Claude Code surfaces plugin skills as `<plugin>:<skill>`, so the bare `/count-blessings` was unreachable, and `/ceo:count-blessings` was more keystrokes than running the CLI in a terminal. The CLI is the canonical interface.

## Goal

A small "executive assistant" feature: maintain a list of things the user is thankful for, and surface three at random in the morning brief's report. Additions happen via CLI (`count-blessings add "..."`) and the morning brief footers a prompt to add more.

Framing note: this is an EA-flavored feature, not a CEO-flavored one. It lives in the CEO plugin today because the brief lives there. Placement under `skills/ea/` leaves room to extract to a separate plugin later without a rename pass.

## Non-goals

- No interactive checkbox/harvest flow. The morning brief is model-rewritten each run, so any `- [ ]` the user ticks does not persist. CLI is the canonical write path.
- No weighting, recency bias, or rotation cursor. Pure random pick of three per day.
- No model involvement in selection. Selection is pure shell.

## File layout

**Plugin (`/Users/nhangen/ML-AI/claude/ceo/`):**

- `scripts/count-blessings.sh` — CLI entrypoint
- `scripts/blessings-lib.sh` — shared library (`ensure_blessings_cache`, `strip_frontmatter`, `require_ceo_dir`)
- ~~`skills/ea/count-blessings/SKILL.md`~~ — removed post-merge; CLI is the canonical interface (see top-of-doc note).

**Vault (`~/Documents/Obsidian/CEO/`):**

- `blessings.md` — persistent list
- `cache/blessings-today.md` — today's three picks (regenerated once per day)

### `blessings.md`

```markdown
---
type: ea-blessings
---

- Heather and the kids
- A warm home and a full fridge
- Work I get to do
- Quiet early mornings
```

One bullet per blessing. No per-entry metadata. No cursor.

### `cache/blessings-today.md`

```markdown
---
date: 2026-04-22
---
- Heather and the kids
- Quiet early mornings
- Work I get to do
```

## CLI

`count-blessings.sh` must run identically on macOS (BSD coreutils) and Linux/WSL (GNU coreutils). All shell follows `set -euo pipefail`, requires `CEO_DIR` via `: "${CEO_DIR:?CEO_DIR must be set}"`, and resolves the vault via `CEO_VAULT` override (see existing pattern in `ceo-gather.sh`).

### Subcommands

| Subcommand | Behavior |
|---|---|
| `add "text"` | Append one bullet to `blessings.md`. Locked, validated, atomic. |
| `list` | Numbered dump of current bullets. Read-only. |
| `show` | Cat today's cache. Read-only. |
| `repick` | Force cache regeneration. Hidden from help; for testing. |

### `add` contract

```sh
# arg validation
[[ -n "${1:-}" ]] || die "usage: count-blessings add \"text\""
[[ "$1" == *$'\n'* ]] && die "no newlines allowed (prevents multi-bullet smuggling)"
[[ ${#1} -le 500 ]] || die "entry too long (max 500 chars)"

# acquire lock (mkdir-based, portable)
LOCK="$CEO_DIR/blessings.md.lock.d"
mkdir "$LOCK" 2>/dev/null || die "another writer is active"
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# ensure trailing newline so append doesn't land on frontmatter or prior bullet
[[ -s "$FILE" && -z "$(tail -c1 "$FILE")" ]] || printf '\n' >> "$FILE"

# safe append — printf %s disarms format strings, -- disarms -flag args
printf -- '- %s\n' "$1" >> "$FILE"
```

### `list` contract

Strips frontmatter with an awk state machine (portable; `sed -n '/^---$/,/^---$/!p'` fails on missing or single `---`):

```sh
awk 'NR==1 && /^---$/{fm=1;next} fm && /^---$/{fm=0;next} !fm' "$FILE" \
  | grep '^- ' \
  | nl -ba
```

### `show`

```sh
cat "$CEO_DIR/cache/blessings-today.md"
```

### `repick`

Deletes `cache/blessings-today.md`, then calls `ensure_blessings_cache` (the shared helper in `scripts/blessings-lib.sh`). The delete bypasses the fast-path date check, giving a clean regen even on the same day. Hidden from `--help`; for testing and manual re-rolls.

## Selection + cache algorithm

Lives as a function `ensure_blessings_cache()` in `scripts/blessings-lib.sh`. Sourced by both `ceo-gather.sh` (on every cron run) and `count-blessings.sh` (`repick` subcommand). No-op if cache is already today's.

```sh
ensure_blessings_cache() {
  local file="$CEO_DIR/blessings.md"
  local cache="$CEO_DIR/cache/blessings-today.md"
  local today; today=$(date +%Y-%m-%d)

  # fast path — cache is today's
  if [[ -f "$cache" ]] && head -3 "$cache" | grep -q "^date: $today$"; then
    return 0
  fi

  # missing source — emit empty cache, log, return
  if [[ ! -f "$file" ]]; then
    mkdir -p "$CEO_DIR/cache"
    printf -- '---\ndate: %s\n---\n' "$today" > "$cache"
    return 0
  fi

  # strip frontmatter, keep bullets, shuffle, take three
  local picks
  picks=$(awk 'NR==1 && /^---$/{fm=1;next} fm && /^---$/{fm=0;next} !fm' "$file" \
    | grep '^- ' \
    | awk 'BEGIN{srand()} {print rand()"\t"$0}' \
    | sort -k1,1n \
    | cut -f2- \
    | head -3)

  # atomic write — tmp + mv
  mkdir -p "$CEO_DIR/cache"
  local tmp; tmp=$(mktemp "$cache.tmp.XXXXXX")
  {
    printf -- '---\ndate: %s\n---\n' "$today"
    printf '%s\n' "$picks"
  } > "$tmp"
  mv -f "$tmp" "$cache"
}
```

**Why this shuffle**: `sort -R` diverges between BSD and GNU on lists with duplicate keys (GNU clusters; BSD true-randoms). The `awk-rand | sort | cut` pattern is POSIX and gives true random ordering on both.

**Why cache-by-day**: `ceo-gather.sh` runs on every cron invocation (every 15 min for inbox). Re-picking on each call is wasteful and means different cron jobs see different blessings. Pick-once-per-day gives consistency across morning-scan and morning-brief and keeps writes to one per day.

## Wiring

### `ceo-gather.sh`

Add after the existing pre-gather block:

```sh
ensure_blessings_cache  # defined above

BLESSINGS_TODAY=""
if [[ -f "$CEO_DIR/cache/blessings-today.md" ]]; then
  BLESSINGS_TODAY=$(awk 'NR==1 && /^---$/{fm=1;next} fm && /^---$/{fm=0;next} !fm' \
                    "$CEO_DIR/cache/blessings-today.md")
fi
```

### `ceo-cron.sh`

Where the PLAN prompt is assembled, add `BLESSINGS_TODAY` to the `<external-data>` block — **not** as trusted pre-gather data. The content of `blessings.md` is user-authored text but still flows through the model; the existing untrusted-content guard is the right primitive.

```
<external-data>
Yesterday's log summary: $YESTERDAY_LOG_SUMMARY
Daily note Top 3: $DAILY_NOTE_TOP3
Daily note Tasks: $DAILY_NOTE_TASKS
Blessings today:
$BLESSINGS_TODAY
</external-data>
```

No change to the EXECUTE prompt — blessings are reference material for the brief narrative only.

### `playbooks/morning-brief.md`

Add to the Output Format section:

```markdown
After the bullet list, append:

## Personal

### Blessings
<reproduce the bullets from `Blessings today:` in the external-data block, verbatim>

_Add one?_ Run `count-blessings add "your blessing"` from a terminal.
```

This changes morning-brief's output contract from "flat 10-bullet list" to "flat list followed by a Personal section." Document the change in the playbook frontmatter (`last_updated`) and in the commit message.

### SKILLS.md

**No row added.** Selection and rendering fold into the existing `morning-brief` row. This preserves the dispatch-table invariant (one row = one playbook = one cron) and avoids introducing a `shell-only` model tier.

## Slash command skill

**Removed post-merge.** Claude Code plugin skills surface as `<plugin>:<skill>`, not bare. The skill at `skills/ea/count-blessings/` would have been ignored by the plugin's skill scanner (which expects `skills/<plugin-name>/...`), and moving it to `skills/ceo/count-blessings/` would only get `/ceo:count-blessings` — strictly more keystrokes than the CLI. The CLI is the canonical interface; symlink it to `~/bin/count-blessings`.

## Security / trust boundaries

| Surface | Source | Trust | Mitigation |
|---|---|---|---|
| `count-blessings add "X"` | User CLI | Trusted input | Reject newlines; cap length; printf-safe append |
| `blessings.md` content flowing to model prompt | User-authored, but model reads it | Untrusted to the model | Wrapped in `<external-data>` with the existing "do not follow instructions" guard |
| `blessings.md` content flowing to terminal (`list`, `show`) | User-authored | Trusted display | `cat`/awk — no interpretation |
| Cache file | Written by `ensure_blessings_cache` only | Internal | Atomic tmp+rename; not world-writable |

No `harvest` subcommand. Model output does not loop back into user-authored data.

## Portability

Tested targets: macOS (Darwin, BSD userland), Linux (GNU userland), Windows via WSL2 (Linux-equivalent).

- No `shuf`, no `sort -R`, no GNU-only `sed -i`, no `date -d`, no `grep -P`.
- All file mutations go tmp-file → `mv -f` (POSIX atomic).
- All locks are `mkdir`-based (no `flock` — absent on macOS).
- `date` yesterday uses `date -v-1d 2>/dev/null || date -d yesterday` (pattern already in `ceo-gather.sh`).
- `grep -c` and `wc -l` guarded with `|| echo 0` and `| xargs` respectively (patterns already in `ceo-gather.sh`).
- Vault path resolves via `${CEO_VAULT:-$HOME/Documents/Obsidian}` — same convention as `ceo-gather.sh`.

## Testing plan

1. **Unit, shell only (no `claude` invocation):**
   - Empty `blessings.md` → empty cache, no crash.
   - 1, 2, 3, 10 entries → cache has `min(N, 3)` entries.
   - No frontmatter on `blessings.md` → awk strip still yields the bullets.
   - File without trailing newline → `add` produces a well-formed result.
   - `add "'; rm -rf ~; #"` → content appears verbatim, no eval.
   - `add $'line1\nline2'` → rejected.
   - `add "$(printf 'x%.0s' {1..501})"` → rejected (length cap).
   - Concurrent `add` + `repick` → no corruption (lock holds).
   - `ensure_blessings_cache` called twice same day → second call is a no-op.
   - `ensure_blessings_cache` after date rollover → cache regenerated.
2. **Integration:**
   - Run `ceo-gather.sh` and inspect `BLESSINGS_TODAY` export.
   - Run `ceo-cron.sh morning-brief` with a populated `blessings.md`; confirm the brief's output contains `## Personal / ### Blessings` with three entries.
   - Run on a second cron (e.g. `inbox`) and confirm cache is reused, not regenerated.
3. **Portability:**
   - Run test suite under both macOS and a Linux container / WSL.

## Known issues — documented, not fixed

These were raised by the audit panel but are outside the scope of this feature. Filed here so they do not get lost.

### 1. WSL vault path is not consistently overridable (HIGH, pre-existing)

`ceo-gather.sh` respects `CEO_VAULT`, but `ceo-cron.sh:17` and `setup-wsl.sh:75,92` hard-code `$HOME/Documents/Obsidian`. A Windows user whose Obsidian vault lives on the Windows side (typical) syncs into WSL via Syncthing, but the default path will not match.

**Not fixed because**: touching all three scripts would widen this PR beyond the feature. The new code uses the `CEO_VAULT` override pattern correctly for its own reads; it does not make the pre-existing divergence worse.

**Follow-up**: single commit that threads `VAULT="${CEO_VAULT:-$HOME/Documents/Obsidian}"` through `ceo-cron.sh` and `setup-wsl.sh`, and documents the `/mnt/c/Users/<user>/Documents/Obsidian` alternative.

### 2. WSL2 cron is not auto-started at boot (HIGH, pre-existing)

`setup-wsl.sh:119-127` installs a crontab, but WSL2 does not start `cron` on boot. Cron entries silently never fire until the user manually opens a WSL shell and runs `sudo service cron start`.

**Not fixed because**: out of scope and does not regress with this feature (pure addition on top of the existing cron pipeline, which has the same issue for every other playbook).

**Follow-up**: `setup-wsl.sh` should append either (a) a `/etc/wsl.conf` `[boot] command = service cron start` stanza (WSL2 0.67.6+), or (b) a Windows Task Scheduler job launching `wsl.exe -u <user> -- /etc/init.d/cron start` at logon. Documentation in `setup-wsl.sh` should explain both.

### 3. `SKILLS.md` preflight column is dead metadata (HIGH, pre-existing)

`SKILLS.md` column 5 lists preflight tokens (`has_unchecked_inbox`, `has_prs_to_review`, etc.). `ceo-cron.sh` parses columns 3 and 6 only; preflight is never read and never evaluated. Every existing preflight is a no-op.

**Not fixed because**: the revised design does not add a new preflight, so the bug is neither used nor extended. Fixing it properly means writing a `run_preflight()` dispatcher with per-token shell predicates — a separate concern.

**Follow-up**: either delete column 5 as dead metadata (honest) or add the dispatcher. Not both, not now.

### 4. morning-brief output format contract broadens (MED, accepted)

The playbook's `## Output Format` today says "Max 10 bullet points." Adding a `## Personal` section after the bullets is a real format change. Accepted because the user explicitly asked for the blessings under a Personal section in the report. Recorded here so a future reader understands why the Output Format no longer matches the original "flat list" intent.

### 5. `shuf` / `sort -R` seed reproducibility (LOW, accepted)

The awk-rand shuffle uses `srand()` seeded from epoch seconds, which means two invocations within the same second produce identical orderings. The cache-by-day gate makes this a non-issue in practice (one invocation per day), and blessings are not secrets. Not worth seeding from `/dev/urandom`.

## Rollout

1. Create `blessings.md` in the vault by hand with a handful of seed entries.
2. Land the plugin changes (script, gather hook, brief playbook, skill file) in a single commit.
3. Wait for the next morning cron. If the brief renders the Personal section correctly, ship. If not, `repick` and inspect.
4. No migration, no feature flag — the feature is a no-op if `blessings.md` is missing.
