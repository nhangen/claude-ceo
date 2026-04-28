# Count Blessings Implementation Plan

> **Update 2026-04-23:** Plan executed and shipped (PR [#2](https://github.com/nhangen/claude-ceo/pull/2), merge `2ea9723`). Task 9 (slash skill at `skills/ea/count-blessings/SKILL.md`) was reverted post-merge — the plugin skill scanner expects `skills/<plugin-name>/...` and bare slash commands are reserved for built-ins. The CLI is the canonical interface.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a gratitude-list feature to the CEO plugin that picks 3 random blessings per day and renders them in the morning brief's new `## Personal / ### Blessings` section. Adds are via CLI only.

**Architecture:** A small portable-shell CLI (`count-blessings.sh`) manages the list. A shared library function (`blessings-lib.sh::ensure_blessings_cache`) does once-per-day random selection into a cache file. `ceo-gather.sh` sources the library, calls the helper, and exports `$BLESSINGS_TODAY`. `ceo-cron.sh` injects it into the PLAN prompt inside the existing `<external-data>` block. The `morning-brief` playbook renders it verbatim in a new Personal section.

**Tech Stack:** Bash (portable across BSD/GNU coreutils — no `shuf`, no `sort -R`, no `sed -i` for rewrites, no `date -d` without the `-v-1d` fallback). Self-contained bash assertion harness for tests.

**Spec:** `docs/superpowers/specs/2026-04-22-count-blessings-design.md`

---

## File Structure

### Created

| Path | Responsibility |
|---|---|
| `scripts/count-blessings.sh` | CLI entrypoint; dispatches `add`/`list`/`show`/`repick` |
| `scripts/blessings-lib.sh` | Pure helpers: `ensure_blessings_cache`, `strip_frontmatter`, `require_ceo_dir` |
| `scripts/count-blessings.test.sh` | Self-contained test suite (temp-dir, no network) |
| ~~`skills/ea/count-blessings/SKILL.md`~~ | ~~Slash-command wrapper~~ — reverted post-merge (see top-of-doc note) |

### Modified

| Path | Change |
|---|---|
| `scripts/ceo-gather.sh` | Source `blessings-lib.sh`, call `ensure_blessings_cache`, export `BLESSINGS_TODAY` |
| `scripts/ceo-cron.sh` | Add `BLESSINGS_TODAY` to the `<external-data>` block in the PLAN prompt (around line 178-182) |
| `~/Documents/Obsidian/CEO/playbooks/morning-brief.md` | Output Format gains `## Personal / ### Blessings` section |

---

## Testing Strategy

All tests live in `scripts/count-blessings.test.sh`. The harness:

- Runs on macOS (Darwin) and Linux/WSL identically.
- Uses `mktemp -d` to create an isolated `$CEO_DIR` per test — no real vault touched.
- Asserts via three small functions (`assert_eq`, `assert_contains`, `assert_fails`).
- Iterates every function named `test_*` found in the file.
- Exits non-zero on any failure.

Run the suite before each commit: `bash scripts/count-blessings.test.sh`.

---

## Task 1: Test harness + empty library and CLI skeleton

**Files:**
- Create: `scripts/blessings-lib.sh`
- Create: `scripts/count-blessings.sh`
- Create: `scripts/count-blessings.test.sh`

- [ ] **Step 1.1: Create `scripts/blessings-lib.sh` with only the skeleton**

```bash
#!/bin/bash
# blessings-lib.sh — shared helpers for count-blessings.sh and ceo-gather.sh.
# Source this file; do not execute directly.

require_ceo_dir() {
  : "${CEO_DIR:?CEO_DIR must be set}"
  [[ -d "$CEO_DIR" ]] || { printf 'CEO_DIR does not exist: %s\n' "$CEO_DIR" >&2; return 1; }
}

strip_frontmatter() {
  # Strip YAML frontmatter if it opens on line 1. Portable across BSD and GNU awk.
  awk 'NR==1 && /^---$/{fm=1;next} fm && /^---$/{fm=0;next} !fm' "$1"
}

ensure_blessings_cache() {
  : # filled in Task 4
}
```

- [ ] **Step 1.2: Create `scripts/count-blessings.sh` with dispatch-only body**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=blessings-lib.sh
source "$SCRIPT_DIR/blessings-lib.sh"

: "${CEO_VAULT:=$HOME/Documents/Obsidian}"
: "${CEO_DIR:=$CEO_VAULT/CEO}"
export CEO_VAULT CEO_DIR

BLESSINGS_FILE="$CEO_DIR/blessings.md"
CACHE_FILE="$CEO_DIR/cache/blessings-today.md"

usage() {
  cat <<EOF
usage: count-blessings <subcommand> [args]

subcommands:
  add "text"   append a blessing to the list
  list         show all blessings, numbered
  show         show today's three picks
EOF
}

die() { printf '%s\n' "$*" >&2; exit 1; }

cmd="${1:-}"
shift || true

case "$cmd" in
  add)    die "not implemented" ;;
  list)   die "not implemented" ;;
  show)   die "not implemented" ;;
  repick) die "not implemented" ;;
  ""|-h|--help) usage; exit 0 ;;
  *)      usage >&2; exit 2 ;;
esac
```

- [ ] **Step 1.3: Create `scripts/count-blessings.test.sh` with the harness**

```bash
#!/bin/bash
# Self-contained test harness. Runs every function named test_*.

set -uo pipefail  # note: no -e — tests handle their own failures

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="$SCRIPT_DIR/count-blessings.sh"
LIB="$SCRIPT_DIR/blessings-lib.sh"

FAILS=0
CURRENT_TEST=""

assert_eq() {
  local got="$1" want="$2" msg="${3:-}"
  if [[ "$got" != "$want" ]]; then
    printf '  FAIL [%s] %s\n    got:  %q\n    want: %q\n' "$CURRENT_TEST" "$msg" "$got" "$want"
    FAILS=$((FAILS + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  FAIL [%s] %s\n    haystack: %q\n    needle:   %q\n' "$CURRENT_TEST" "$msg" "$haystack" "$needle"
    FAILS=$((FAILS + 1))
  fi
}

assert_fails() {
  local msg="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  FAIL [%s] %s (expected non-zero exit)\n' "$CURRENT_TEST" "$msg"
    FAILS=$((FAILS + 1))
  fi
}

setup() {
  TEST_HOME=$(mktemp -d)
  export CEO_VAULT="$TEST_HOME/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  mkdir -p "$CEO_DIR/cache"
}

teardown() {
  rm -rf "$TEST_HOME"
  unset CEO_VAULT CEO_DIR TEST_HOME
}

test_harness_works() {
  assert_eq "1" "1" "arithmetic still works"
}

# --- runner ---
tests=$(declare -F | awk '{print $3}' | grep '^test_' || true)
for t in $tests; do
  CURRENT_TEST="$t"
  printf 'RUN %s\n' "$t"
  setup
  "$t"
  teardown
done

if [[ "$FAILS" -gt 0 ]]; then
  printf '\n%d FAILURE(S)\n' "$FAILS"
  exit 1
fi
printf '\nALL PASS\n'
```

- [ ] **Step 1.4: Make the scripts executable**

```bash
chmod +x /Users/nhangen/ML-AI/claude/ceo/scripts/count-blessings.sh \
         /Users/nhangen/ML-AI/claude/ceo/scripts/count-blessings.test.sh
```

- [ ] **Step 1.5: Run the suite — confirm the harness works**

```bash
bash /Users/nhangen/ML-AI/claude/ceo/scripts/count-blessings.test.sh
```

Expected output ends with `ALL PASS`.

- [ ] **Step 1.6: Commit**

```bash
cd /Users/nhangen/ML-AI/claude/ceo
git add scripts/blessings-lib.sh scripts/count-blessings.sh scripts/count-blessings.test.sh
git commit -m "feat(blessings): scaffold CLI, lib, and test harness"
```

---

## Task 2: Implement `add` subcommand

**Files:**
- Modify: `scripts/count-blessings.sh`
- Modify: `scripts/count-blessings.test.sh`

- [ ] **Step 2.1: Write failing tests for `add` in `count-blessings.test.sh`**

Append before the runner section (just above the `# --- runner ---` line):

```bash
test_add_writes_bullet_to_blessings_file() {
  bash "$CLI" add "family" >/dev/null
  local content
  content=$(cat "$CEO_DIR/blessings.md")
  assert_contains "$content" "- family" "bullet written"
  assert_contains "$content" "type: ea-blessings" "frontmatter created"
}

test_add_appends_without_overwriting() {
  bash "$CLI" add "first" >/dev/null
  bash "$CLI" add "second" >/dev/null
  local content
  content=$(cat "$CEO_DIR/blessings.md")
  assert_contains "$content" "- first" "first preserved"
  assert_contains "$content" "- second" "second appended"
}

test_add_rejects_empty_argument() {
  assert_fails "empty add should fail" bash "$CLI" add ""
}

test_add_rejects_newline_in_argument() {
  assert_fails "newline smuggling rejected" bash "$CLI" add $'line1\nline2'
}

test_add_rejects_overlong_argument() {
  local long
  long=$(printf 'x%.0s' {1..501})
  assert_fails "501-char entry rejected" bash "$CLI" add "$long"
}

test_add_handles_shell_metacharacters_literally() {
  bash "$CLI" add "\$(rm -rf /tmp/should-not-happen); echo pwned" >/dev/null
  local content
  content=$(cat "$CEO_DIR/blessings.md")
  assert_contains "$content" '$(rm -rf /tmp/should-not-happen); echo pwned' "metachars stored verbatim"
  [[ ! -f "/tmp/should-not-happen" || $(ls /tmp/should-not-happen 2>/dev/null) ]] && true  # harmless
}

test_add_ensures_trailing_newline_before_append() {
  # pre-seed a file without trailing newline
  printf -- '---\ntype: ea-blessings\n---\n\n- existing' > "$CEO_DIR/blessings.md"
  bash "$CLI" add "new" >/dev/null
  local lines
  lines=$(grep -c '^- ' "$CEO_DIR/blessings.md")
  assert_eq "$lines" "2" "both bullets present on their own lines"
}
```

- [ ] **Step 2.2: Run tests — confirm they fail**

```bash
bash /Users/nhangen/ML-AI/claude/ceo/scripts/count-blessings.test.sh
```

Expected: failures on the new `test_add_*` tests (the dispatch currently dies with "not implemented").

- [ ] **Step 2.3: Implement `add` in `count-blessings.sh`**

Replace the `add)    die "not implemented" ;;` line with a call to a function, and add the function above the `case` statement:

```bash
ensure_blessings_file_exists() {
  if [[ ! -f "$BLESSINGS_FILE" ]]; then
    mkdir -p "$(dirname "$BLESSINGS_FILE")"
    printf -- '---\ntype: ea-blessings\n---\n\n' > "$BLESSINGS_FILE"
  fi
}

ensure_trailing_newline() {
  local f="$1"
  # If file is non-empty and last byte is not a newline, append one.
  if [[ -s "$f" ]]; then
    local last
    last=$(tail -c1 "$f" | od -An -c | tr -d ' ')
    if [[ "$last" != "\\n" ]]; then
      printf '\n' >> "$f"
    fi
  fi
}

with_blessings_lock() {
  # mkdir-based lock, portable to macOS (no flock by default).
  local lock="$BLESSINGS_FILE.lock.d"
  local tries=0
  until mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1))
    if (( tries > 50 )); then
      die "could not acquire lock on $BLESSINGS_FILE"
    fi
    sleep 0.1
  done
  trap 'rmdir "'"$lock"'" 2>/dev/null' EXIT
  "$@"
  rmdir "$lock" 2>/dev/null
  trap - EXIT
}

cmd_add() {
  local text="${1:-}"
  [[ -n "$text" ]]              || die "usage: count-blessings add \"text\""
  [[ "$text" != *$'\n'* ]]      || die "no newlines allowed in blessing text"
  [[ ${#text} -le 500 ]]        || die "entry too long (max 500 chars)"
  require_ceo_dir

  ensure_blessings_file_exists

  _do_add() {
    ensure_trailing_newline "$BLESSINGS_FILE"
    printf -- '- %s\n' "$text" >> "$BLESSINGS_FILE"
  }
  with_blessings_lock _do_add
}
```

Replace `add)    die "not implemented" ;;` with:

```bash
  add)    cmd_add "${1:-}" ;;
```

- [ ] **Step 2.4: Run tests — confirm they pass**

```bash
bash /Users/nhangen/ML-AI/claude/ceo/scripts/count-blessings.test.sh
```

Expected: `ALL PASS`.

- [ ] **Step 2.5: Commit**

```bash
cd /Users/nhangen/ML-AI/claude/ceo
git add scripts/count-blessings.sh scripts/count-blessings.test.sh
git commit -m "feat(blessings): implement add subcommand"
```

---

## Task 3: Implement `list` subcommand

**Files:**
- Modify: `scripts/count-blessings.sh`
- Modify: `scripts/count-blessings.test.sh`

- [ ] **Step 3.1: Write failing tests**

Append to `count-blessings.test.sh` before the runner:

```bash
test_list_shows_numbered_bullets() {
  bash "$CLI" add "first" >/dev/null
  bash "$CLI" add "second" >/dev/null
  bash "$CLI" add "third" >/dev/null
  local out
  out=$(bash "$CLI" list)
  assert_contains "$out" "- first" "first present"
  assert_contains "$out" "- second" "second present"
  assert_contains "$out" "- third" "third present"
  # nl -ba adds line numbers; we accept any numeric prefix style
  assert_contains "$out" "1" "numbered"
}

test_list_strips_frontmatter() {
  bash "$CLI" add "only-one" >/dev/null
  local out
  out=$(bash "$CLI" list)
  [[ "$out" != *"type: ea-blessings"* ]] || {
    printf '  FAIL [%s] frontmatter leaked into list output\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  }
}

test_list_on_missing_file_is_empty() {
  local out
  out=$(bash "$CLI" list 2>&1 || true)
  # Missing file is not an error — just empty output.
  assert_eq "$out" "" "empty output on missing file"
}
```

- [ ] **Step 3.2: Run tests — confirm new ones fail**

```bash
bash /Users/nhangen/ML-AI/claude/ceo/scripts/count-blessings.test.sh
```

- [ ] **Step 3.3: Implement `list`**

Add this function to `count-blessings.sh` above the `case` block:

```bash
cmd_list() {
  require_ceo_dir
  [[ -f "$BLESSINGS_FILE" ]] || return 0
  strip_frontmatter "$BLESSINGS_FILE" | grep '^- ' | nl -ba
}
```

Replace `list)   die "not implemented" ;;` with:

```bash
  list)   cmd_list ;;
```

- [ ] **Step 3.4: Run tests — confirm all pass**

```bash
bash /Users/nhangen/ML-AI/claude/ceo/scripts/count-blessings.test.sh
```

Expected: `ALL PASS`.

- [ ] **Step 3.5: Commit**

```bash
cd /Users/nhangen/ML-AI/claude/ceo
git add scripts/count-blessings.sh scripts/count-blessings.test.sh
git commit -m "feat(blessings): implement list subcommand"
```

---

## Task 4: Implement `ensure_blessings_cache` in the library

**Files:**
- Modify: `scripts/blessings-lib.sh`
- Modify: `scripts/count-blessings.test.sh`

- [ ] **Step 4.1: Write failing tests**

Append to `count-blessings.test.sh` before the runner:

```bash
test_cache_picks_three_when_many_available() {
  # shellcheck source=../blessings-lib.sh
  source "$LIB"
  mkdir -p "$CEO_DIR"
  {
    printf -- '---\ntype: ea-blessings\n---\n\n'
    for i in 1 2 3 4 5 6 7 8 9 10; do printf -- '- entry %d\n' "$i"; done
  } > "$CEO_DIR/blessings.md"

  ensure_blessings_cache

  local cache="$CEO_DIR/cache/blessings-today.md"
  [[ -f "$cache" ]] || { printf '  FAIL [%s] cache not created\n' "$CURRENT_TEST"; FAILS=$((FAILS+1)); return; }

  local today; today=$(date +%Y-%m-%d)
  assert_contains "$(cat "$cache")" "date: $today" "today stamped"

  local bullet_count
  bullet_count=$(grep -c '^- ' "$cache")
  assert_eq "$bullet_count" "3" "exactly three picks"
}

test_cache_picks_all_when_fewer_than_three() {
  source "$LIB"
  mkdir -p "$CEO_DIR"
  printf -- '---\ntype: ea-blessings\n---\n\n- only-one\n' > "$CEO_DIR/blessings.md"
  ensure_blessings_cache
  local count
  count=$(grep -c '^- ' "$CEO_DIR/cache/blessings-today.md")
  assert_eq "$count" "1" "one-entry file yields one pick"
}

test_cache_no_op_when_already_today() {
  source "$LIB"
  mkdir -p "$CEO_DIR/cache"
  printf -- '- first\n- second\n- third\n' > "$CEO_DIR/blessings.md"
  local today; today=$(date +%Y-%m-%d)
  printf -- '---\ndate: %s\n---\n- cached-sentinel\n' "$today" > "$CEO_DIR/cache/blessings-today.md"
  ensure_blessings_cache
  # sentinel must still be present — helper skipped regen
  assert_contains "$(cat "$CEO_DIR/cache/blessings-today.md")" "cached-sentinel" "cache preserved"
}

test_cache_regenerates_when_stale() {
  source "$LIB"
  mkdir -p "$CEO_DIR/cache"
  printf -- '- a\n- b\n- c\n' > "$CEO_DIR/blessings.md"
  printf -- '---\ndate: 1999-01-01\n---\n- stale-sentinel\n' > "$CEO_DIR/cache/blessings-today.md"
  ensure_blessings_cache
  local content
  content=$(cat "$CEO_DIR/cache/blessings-today.md")
  [[ "$content" != *"stale-sentinel"* ]] || {
    printf '  FAIL [%s] stale cache was not replaced\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  }
}

test_cache_handles_missing_source_file() {
  source "$LIB"
  ensure_blessings_cache  # no blessings.md exists
  local cache="$CEO_DIR/cache/blessings-today.md"
  [[ -f "$cache" ]] || { printf '  FAIL [%s] expected empty cache file\n' "$CURRENT_TEST"; FAILS=$((FAILS+1)); return; }
  local bullet_count
  bullet_count=$(grep -c '^- ' "$cache" || echo 0)
  assert_eq "$bullet_count" "0" "no bullets when source missing"
}

test_cache_strips_frontmatter_before_picking() {
  source "$LIB"
  mkdir -p "$CEO_DIR"
  {
    printf -- '---\ntype: ea-blessings\n---\n\n'
    printf -- '- real-entry\n'
  } > "$CEO_DIR/blessings.md"
  ensure_blessings_cache
  local content
  content=$(cat "$CEO_DIR/cache/blessings-today.md")
  [[ "$content" != *"type: ea-blessings"* ]] || {
    printf '  FAIL [%s] frontmatter bled into cache\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  }
  assert_contains "$content" "- real-entry" "real entry picked"
}
```

- [ ] **Step 4.2: Run — confirm failures**

```bash
bash /Users/nhangen/ML-AI/claude/ceo/scripts/count-blessings.test.sh
```

- [ ] **Step 4.3: Implement `ensure_blessings_cache` in `blessings-lib.sh`**

Replace the placeholder `ensure_blessings_cache() { : ; }` with:

```bash
ensure_blessings_cache() {
  require_ceo_dir || return 1
  local src="$CEO_DIR/blessings.md"
  local cache="$CEO_DIR/cache/blessings-today.md"
  local today; today=$(date +%Y-%m-%d)

  mkdir -p "$CEO_DIR/cache"

  # Fast path: cache is today's, do nothing.
  if [[ -f "$cache" ]] && head -3 "$cache" | grep -q "^date: $today\$"; then
    return 0
  fi

  # Missing source — write an empty-but-stamped cache so downstream readers
  # always get a valid file, and return.
  if [[ ! -f "$src" ]]; then
    local tmp="$cache.tmp.$$"
    printf -- '---\ndate: %s\n---\n' "$today" > "$tmp"
    mv -f "$tmp" "$cache"
    return 0
  fi

  # Pick three at random — portable across BSD/GNU (no sort -R).
  local picks
  picks=$(strip_frontmatter "$src" \
    | grep '^- ' \
    | awk 'BEGIN{srand()} {print rand()"\t"$0}' \
    | sort -k1,1n \
    | cut -f2- \
    | head -3)

  local tmp="$cache.tmp.$$"
  {
    printf -- '---\ndate: %s\n---\n' "$today"
    if [[ -n "$picks" ]]; then
      printf '%s\n' "$picks"
    fi
  } > "$tmp"
  mv -f "$tmp" "$cache"
}
```

- [ ] **Step 4.4: Run — confirm all pass**

```bash
bash /Users/nhangen/ML-AI/claude/ceo/scripts/count-blessings.test.sh
```

Expected: `ALL PASS`.

- [ ] **Step 4.5: Commit**

```bash
cd /Users/nhangen/ML-AI/claude/ceo
git add scripts/blessings-lib.sh scripts/count-blessings.test.sh
git commit -m "feat(blessings): daily cache picker in blessings-lib"
```

---

## Task 5: Implement `show` and `repick` subcommands

**Files:**
- Modify: `scripts/count-blessings.sh`
- Modify: `scripts/count-blessings.test.sh`

- [ ] **Step 5.1: Write failing tests**

Append to the test file before the runner:

```bash
test_show_outputs_cache_file() {
  bash "$CLI" add "a" >/dev/null
  bash "$CLI" add "b" >/dev/null
  bash "$CLI" add "c" >/dev/null
  bash "$CLI" repick >/dev/null
  local out
  out=$(bash "$CLI" show)
  local today; today=$(date +%Y-%m-%d)
  assert_contains "$out" "date: $today" "cache date visible"
}

test_show_on_missing_cache_is_empty() {
  local out
  out=$(bash "$CLI" show 2>&1 || true)
  assert_eq "$out" "" "empty on no cache"
}

test_repick_forces_regeneration() {
  bash "$CLI" add "a" >/dev/null
  bash "$CLI" add "b" >/dev/null
  bash "$CLI" add "c" >/dev/null
  bash "$CLI" repick >/dev/null
  # overwrite cache with sentinel so we can detect a re-pick
  local today; today=$(date +%Y-%m-%d)
  printf -- '---\ndate: %s\n---\n- sentinel\n' "$today" > "$CEO_DIR/cache/blessings-today.md"
  bash "$CLI" repick >/dev/null
  local content
  content=$(cat "$CEO_DIR/cache/blessings-today.md")
  [[ "$content" != *"sentinel"* ]] || {
    printf '  FAIL [%s] repick did not regenerate\n' "$CURRENT_TEST"
    FAILS=$((FAILS + 1))
  }
}
```

- [ ] **Step 5.2: Run — confirm failures**

```bash
bash /Users/nhangen/ML-AI/claude/ceo/scripts/count-blessings.test.sh
```

- [ ] **Step 5.3: Implement `show` and `repick`**

Add to `count-blessings.sh` above the `case` block:

```bash
cmd_show() {
  require_ceo_dir
  [[ -f "$CACHE_FILE" ]] || return 0
  cat "$CACHE_FILE"
}

cmd_repick() {
  require_ceo_dir
  rm -f "$CACHE_FILE"
  ensure_blessings_cache
}
```

Replace the two placeholder dispatch arms:

```bash
  show)   cmd_show ;;
  repick) cmd_repick ;;
```

- [ ] **Step 5.4: Run — confirm pass**

```bash
bash /Users/nhangen/ML-AI/claude/ceo/scripts/count-blessings.test.sh
```

- [ ] **Step 5.5: Commit**

```bash
cd /Users/nhangen/ML-AI/claude/ceo
git add scripts/count-blessings.sh scripts/count-blessings.test.sh
git commit -m "feat(blessings): implement show and repick subcommands"
```

---

## Task 6: Integrate into `ceo-gather.sh`

**Files:**
- Modify: `scripts/ceo-gather.sh`

- [ ] **Step 6.1: Add sourcing and export block**

Append to `scripts/ceo-gather.sh` after the "Daily note sections" block (currently ends at line 119):

```bash

# --- Blessings (EA) ---
GATHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=blessings-lib.sh
source "$GATHER_DIR/blessings-lib.sh"
ensure_blessings_cache || true

if [ -f "$CEO_DIR/cache/blessings-today.md" ]; then
  export BLESSINGS_TODAY=$(strip_frontmatter "$CEO_DIR/cache/blessings-today.md")
else
  export BLESSINGS_TODAY=""
fi
```

Also extend the `Exports:` header comment (lines 7-16) to add `BLESSINGS_TODAY`:

```bash
#   SYNC_CONFLICT_COUNT
#   DAILY_NOTE_TOP3, DAILY_NOTE_TASKS
#   BLESSINGS_TODAY
```

- [ ] **Step 6.2: Verify by sourcing in a shell and echoing the variable**

```bash
cd /Users/nhangen/ML-AI/claude/ceo
export CEO_VAULT="$(mktemp -d)/vault"
mkdir -p "$CEO_VAULT/CEO/cache"
printf -- '---\ntype: ea-blessings\n---\n\n- smoke-test-entry\n' > "$CEO_VAULT/CEO/blessings.md"
( source scripts/ceo-gather.sh && printf 'BLESSINGS_TODAY=[%s]\n' "$BLESSINGS_TODAY" ) 2>/dev/null
```

Expected: output includes `- smoke-test-entry` in the variable.

- [ ] **Step 6.3: Commit**

```bash
cd /Users/nhangen/ML-AI/claude/ceo
git add scripts/ceo-gather.sh
git commit -m "feat(blessings): export BLESSINGS_TODAY from ceo-gather"
```

---

## Task 7: Inject `BLESSINGS_TODAY` into the PLAN prompt

**Files:**
- Modify: `scripts/ceo-cron.sh`

- [ ] **Step 7.1: Locate the `<external-data>` block**

Currently at lines 178-182 of `scripts/ceo-cron.sh`:

```
<external-data>
Yesterday's log summary: $YESTERDAY_LOG_SUMMARY
Daily note Top 3: $DAILY_NOTE_TOP3
Daily note Tasks: $DAILY_NOTE_TASKS
</external-data>
```

- [ ] **Step 7.2: Edit the block to include blessings**

Use the Edit tool to replace the four-line block above with:

```
<external-data>
Yesterday's log summary: $YESTERDAY_LOG_SUMMARY
Daily note Top 3: $DAILY_NOTE_TOP3
Daily note Tasks: $DAILY_NOTE_TASKS
Blessings today:
$BLESSINGS_TODAY
</external-data>
```

Do not edit the EXECUTE prompt — blessings are context for brief narration only, not for tool calls.

- [ ] **Step 7.3: Sanity check — syntax still parses**

```bash
bash -n /Users/nhangen/ML-AI/claude/ceo/scripts/ceo-cron.sh
```

Expected: exits 0, no output.

- [ ] **Step 7.4: Commit**

```bash
cd /Users/nhangen/ML-AI/claude/ceo
git add scripts/ceo-cron.sh
git commit -m "feat(blessings): inject BLESSINGS_TODAY into PLAN prompt"
```

---

## Task 8: Update the `morning-brief` playbook

**Files:**
- Modify: `~/Documents/Obsidian/CEO/playbooks/morning-brief.md`

- [ ] **Step 8.1: Edit the Output Format section**

Replace the current Output Format section with:

```markdown
## Output Format

Max 10 bullet points:
- Open PR count and oldest PR age
- PRs needing your review (count + list top 3)
- Pending approvals count
- Top 3 priorities (from daily note or inferred from PR urgency + domain priority)
- 1-2 questions from Pending.md if relevant to today's focus
- Carryover items from yesterday

Then append a Personal section sourced from the `<external-data>` `Blessings today:` field:

## Personal

### Blessings
<reproduce each bullet from `Blessings today:` verbatim; if empty, omit this whole section>

_Add one?_ Run `count-blessings add "your blessing"` from a terminal.
```

Also bump `last_updated` in the frontmatter to today's date (2026-04-22) if such a field exists; add it if it doesn't.

- [ ] **Step 8.2: Commit in the vault (separate repo)**

The vault is Syncthing-synced; no git commit is required in this plugin repo for the playbook change. If the vault is under git locally, note the change in its log; otherwise Syncthing propagates.

No commit in the plugin repo for this step — the playbook lives in the vault, not the plugin.

---

## Task 9: ~~Add the `/count-blessings` slash command skill~~ (REVERTED)

**Status:** Reverted in the post-merge cleanup PR. Claude Code plugin skills surface as `<plugin>:<skill>`, not bare. The CLI (`count-blessings add|list|show|repick`) is the canonical interface.

The original task body is preserved below for historical reference, but do **not** re-implement.

**Files:**
- ~~Create: `skills/ea/count-blessings/SKILL.md`~~

- [ ] **Step 9.1: Create the skill file**

```markdown
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
```

- [ ] **Step 9.2: Commit**

```bash
cd /Users/nhangen/ML-AI/claude/ceo
git add skills/ea/count-blessings/SKILL.md
git commit -m "feat(blessings): add /count-blessings slash skill"
```

---

## Task 10: End-to-end smoke test

**Files:**
- No changes — just verification.

- [ ] **Step 10.1: Seed a test vault and run the full pipeline**

```bash
cd /Users/nhangen/ML-AI/claude/ceo
export CEO_VAULT="$(mktemp -d)/vault"
mkdir -p "$CEO_VAULT/CEO/cache"

# Seed via the CLI itself — exercises add path
bash scripts/count-blessings.sh add "family"
bash scripts/count-blessings.sh add "a warm home"
bash scripts/count-blessings.sh add "work I love"
bash scripts/count-blessings.sh add "quiet mornings"

# List
bash scripts/count-blessings.sh list

# Pick for today
bash scripts/count-blessings.sh repick
bash scripts/count-blessings.sh show
```

Expected: `list` shows four numbered bullets. `repick` followed by `show` prints a file with a `date:` frontmatter line matching today and exactly three bullets.

- [ ] **Step 10.2: Confirm `ceo-gather.sh` exports the variable**

```bash
( source scripts/ceo-gather.sh && printf 'EXPORTED=[%s]\n' "$BLESSINGS_TODAY" )
```

Expected: output includes three bullets drawn from the seed set.

- [ ] **Step 10.3: Clean up**

```bash
rm -rf "$CEO_VAULT"
unset CEO_VAULT
```

- [ ] **Step 10.4: Final test run on clean tree**

```bash
bash /Users/nhangen/ML-AI/claude/ceo/scripts/count-blessings.test.sh
```

Expected: `ALL PASS`.

No commit — this task is verification only.

---

## Self-review checklist (already run while drafting)

1. **Spec coverage:**
   - CLI (`add`, `list`, `show`, `repick`) — Tasks 2, 3, 5. ✓
   - Selection + cache — Task 4. ✓
   - `ceo-gather.sh` wiring — Task 6. ✓
   - `ceo-cron.sh` `<external-data>` injection — Task 7. ✓
   - Morning-brief Output Format change — Task 8. ✓
   - ~~`skills/ea/count-blessings/SKILL.md` — Task 9~~. Reverted post-merge.
   - Portability (no `sort -R`, awk state machine, mkdir lock, printf append, trailing-newline) — Tasks 2, 4. ✓
   - Security (`<external-data>` wrap, newline/length reject, printf-safe append, `set -euo pipefail`, `CEO_DIR` guard) — Tasks 1, 2, 7. ✓
   - Known issues (WSL path, WSL cron, dead preflight, output-format contract, srand granularity) — documented in spec; not fixed in this plan by design. ✓

2. **Placeholders:** none — every step has concrete code, concrete commands, and concrete expected output.

3. **Type consistency:** function names used across tasks:
   - `ensure_blessings_cache` — defined Task 4, called Tasks 5, 6. ✓
   - `strip_frontmatter` — defined Task 1, called Tasks 3, 4, 6. ✓
   - `require_ceo_dir` — defined Task 1, called Tasks 2, 3, 4, 5. ✓
   - `$BLESSINGS_FILE`, `$CACHE_FILE` — set in Task 1, used in Tasks 2, 3, 5. ✓
   - `BLESSINGS_TODAY` export — set Task 6, consumed Task 7. ✓
