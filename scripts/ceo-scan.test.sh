#!/bin/bash
# Tests for `ceo playbook scan` (cmd_playbook_scan):
#   - the generated registry.json is written HOST-LOCAL ($HOME/.ceo/registry.json),
#     NOT into the synced vault ($CEO_VAULT/CEO/registry.json)
#   - per-playbook `scope` frontmatter: passthrough, safe default (single),
#     and rejection of an unknown value through the existing skip/fail path
#
# Drives cmd_playbook_scan end-to-end against a temp vault + temp HOME, with a
# stub crontab so no real crontab is touched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CEO_CLI="$SCRIPT_DIR/ceo"

source "$SCRIPT_DIR/test-harness.sh"

_load_ceo_helpers() {
  export CEO_LIB_ONLY=1
  set +u
  # shellcheck disable=SC1090,SC1091
  source "$CEO_CLI"
  set +e +u
  unset CEO_LIB_ONLY
}

# A crontab stub: `-l` prints nothing (empty existing crontab), a write
# invocation (file arg or stdin) succeeds. Any other argv shape fails non-zero
# per stub-cli-argv-validation. Every invocation is recorded (argv + stdin) to
# $CRONTAB_LOG so a test can assert whether scan ever tried to install a block.
_write_crontab_stub() {
  export CEO_CRONTAB_BIN="$TMP/stub-crontab"
  export CRONTAB_LOG="$TMP/crontab-invocations.log"
  : > "$CRONTAB_LOG"
  cat > "$CEO_CRONTAB_BIN" <<'STUB'
#!/bin/bash
{
  printf 'argv:%s\n' "$*"
  case "$1" in
    -|"") sed 's/^/stdin:/' ;;
    *) [ -f "$1" ] && sed 's/^/file:/' < "$1" ;;
  esac
} >> "$CRONTAB_LOG"
case "$1" in
  -l) exit 0 ;;
  -r) exit 0 ;;
  -|"") exit 0 ;;
  *)
    if [ -f "$1" ]; then exit 0; fi
    echo "stub-crontab: unexpected argv: $*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$CEO_CRONTAB_BIN"
}

# A cron-triggered playbook with a concrete schedule. Under the retired Phase-1
# behavior, scan would emit a `# CEO Agent` block containing this line and write
# it to the crontab. The daemon now owns scheduling, so scan must NOT install.
_write_cron_playbook() {
  local file="$1" name="$2" schedule="$3"
  {
    echo "---"
    echo "name: $name"
    echo "description: $name desc"
    echo "trigger: cron"
    echo "schedule: \"$schedule\""
    echo "status: active"
    echo "runner: claude"
    echo "---"
    echo ""
    echo "# $name"
  } > "$file"
}

# Minimal valid frontmatter the scanner accepts. chat trigger + empty schedule
# keeps the crontab path a no-op (no collision detection on these entries).
_write_playbook() {
  local file="$1" name="$2" scope_line="$3"
  {
    echo "---"
    echo "name: $name"
    echo "description: $name desc"
    echo "trigger: chat"
    echo "schedule: \"\""
    echo "status: active"
    echo "runner: claude"
    [ -n "$scope_line" ] && echo "$scope_line"
    echo "---"
    echo ""
    echo "# $name"
  } > "$file"
}

setup() {
  TMP=$(mktemp -d)
  export HOME="$TMP/home"
  mkdir -p "$HOME"

  export CEO_VAULT="$TMP/vault"
  export CEO_DIR="$CEO_VAULT/CEO"
  mkdir -p "$CEO_DIR/playbooks"
  # ceo_validate_vault requires CEO/inbox.md to exist.
  : > "$CEO_DIR/inbox.md"

  # No repo playbooks should leak in.
  export CEO_REPO_PLAYBOOK_DIR="$TMP/no-such-repo-playbooks"

  # Resolve hostname deterministically so the primary-host gate (absent
  # settings.json → pass) and any host lookups don't depend on the runner.
  export CEO_HOSTNAME="testhost"

  _write_crontab_stub
  _write_playbook "$CEO_DIR/playbooks/scope-each.md"   "scope-each"   "scope: each"
  _write_playbook "$CEO_DIR/playbooks/scope-absent.md" "scope-absent" ""
  _write_playbook "$CEO_DIR/playbooks/scope-bogus.md"  "scope-bogus"  "scope: bogus"
  _write_cron_playbook "$CEO_DIR/playbooks/cron-job.md" "cron-job" "0 9 * * *"
}

teardown() {
  rm -rf "$TMP"
  unset HOME CEO_VAULT CEO_DIR CEO_REPO_PLAYBOOK_DIR CEO_HOSTNAME CEO_CRONTAB_BIN
}

_run_scan() {
  # Capture combined output; cmd_playbook_scan returns non-zero when an entry
  # is skipped for an invalid enum (same path as unknown status).
  SCAN_OUT=$(cmd_playbook_scan 2>&1)
  SCAN_RC=$?
}

test_registry_written_host_local_not_vault() {
  _run_scan
  assert_file_exists "$HOME/.ceo/registry.json" "registry must be written host-local under \$HOME/.ceo"
  assert_no_match "$(ls "$CEO_DIR" 2>/dev/null)" "registry.json" \
    "registry.json must NOT be written into the synced vault CEO dir"
}

test_scope_each_passthrough() {
  _run_scan
  local scope
  scope=$(jq -r '.playbooks[] | select(.name=="scope-each") | .scope' "$HOME/.ceo/registry.json")
  assert_eq "$scope" "each" "scope: each must pass through to the registry"
}

test_scope_absent_defaults_to_single() {
  _run_scan
  local scope
  scope=$(jq -r '.playbooks[] | select(.name=="scope-absent") | .scope' "$HOME/.ceo/registry.json")
  assert_eq "$scope" "single" "absent scope must default to the safe value 'single'"
}

test_unknown_scope_skipped_diagnostic_and_failure_exit() {
  _run_scan
  # Absent from the registry.
  local present
  present=$(jq -r '[.playbooks[] | select(.name=="scope-bogus")] | length' "$HOME/.ceo/registry.json")
  assert_eq "$present" "0" "playbook with unknown scope must be absent from the registry"
  # Diagnostic mentions scope.
  assert_contains "$SCAN_OUT" "scope" "skip diagnostic must mention scope"
  assert_contains "$SCAN_OUT" "scope-bogus" "skip diagnostic must name the offending playbook"
  # Counts toward the failure exit, same observable signal as unknown status.
  assert_eq "$SCAN_RC" "1" "unknown scope must produce a non-zero scan exit (failure observability)"
}

test_scan_does_not_install_crontab_block() {
  _run_scan
  # The cron playbook is in the registry — scan parsed it.
  local present
  present=$(jq -r '[.playbooks[] | select(.name=="cron-job")] | length' "$HOME/.ceo/registry.json")
  assert_eq "$present" "1" "precondition: cron playbook must be parsed into the registry"
  # …but scan must NOT have written a `# CEO Agent` block to the crontab. The
  # ceo-schedulerd daemon owns scheduling now; scan only writes the registry.
  local log
  log=$(cat "$CRONTAB_LOG" 2>/dev/null || true)
  assert_not_contains "$log" "# CEO Agent" \
    "scan must NOT install a # CEO Agent crontab block (daemon is the sole scheduler)"
  assert_not_contains "$log" "ceo:cron-job" \
    "scan must NOT write any playbook cron line to the crontab"
}

test_scan_output_omits_crontab_install_message() {
  _run_scan
  assert_not_contains "$SCAN_OUT" "entries installed" \
    "scan must not claim to install crontab entries"
}

_load_ceo_helpers

test_scan_registers_real_cron_failure_digest_with_inline_registry() {
  # Guards fixture drift (test-reproduces-production-conditions): the synthetic
  # agent fixtures in ceo-cron.test.sh use a path-string `registry` with no
  # model/task/artifact, whereas the SHIPPED cron-failure-digest playbook uses an
  # inline-JSON `registry` object. Scan the real file and assert it registers as
  # runner:ollama-agent and the inline JSON survives scan as a string that
  # re-parses to the bridge task spec.
  local real="$SCRIPT_DIR/../docs/playbooks/cron-failure-digest.md"
  assert_file_exists "$real" "the shipped cron-failure-digest playbook must exist"
  cp "$real" "$CEO_DIR/playbooks/cron-failure-digest.md"
  export CEO_OLLAMA_SKIP_PROBE=1
  _run_scan
  unset CEO_OLLAMA_SKIP_PROBE
  local reg="$HOME/.ceo/registry.json"
  assert_eq "$(jq -r '.playbooks[]|select(.name=="cron-failure-digest").runner' "$reg")" \
    "ollama-agent" "real playbook must register with runner=ollama-agent"
  assert_eq "$(jq -r '.playbooks[]|select(.name=="cron-failure-digest").task' "$reg")" \
    "cron-failure-digest" "task field must round-trip through scan"
  local inline tier
  inline=$(jq -r '.playbooks[]|select(.name=="cron-failure-digest").registry' "$reg")
  tier=$(printf '%s' "$inline" | jq -r '.tasks["cron-failure-digest"].tier' 2>/dev/null)
  assert_eq "$tier" "low-stakes-write" \
    "inline-JSON registry must survive scan and re-parse to the bridge task tier"
}

test_discord_report_flags_carried_to_registry() {
  {
    echo "---"; echo "name: flagged"; echo "description: d"; echo "trigger: cron"
    echo "schedule: \"0 9 * * *\""; echo "status: active"; echo "runner: claude"
    echo "discord_report: true"; echo "discord_prior_day_report: true"
    echo "---"; echo ""; echo "# flagged"
  } > "$CEO_DIR/playbooks/flagged.md"
  _run_scan
  local reg="$HOME/.ceo/registry.json"
  assert_eq "$(jq -r '.playbooks[]|select(.name=="flagged").discord_report' "$reg")" "true" \
    "scan must carry discord_report:true from frontmatter into the registry entry"
  assert_eq "$(jq -r '.playbooks[]|select(.name=="flagged").discord_prior_day_report' "$reg")" "true" \
    "scan must carry discord_prior_day_report:true from frontmatter into the registry entry"
}

test_discord_report_flag_null_when_frontmatter_omits() {
  _run_scan
  local reg="$HOME/.ceo/registry.json"
  assert_eq "$(jq -r '.playbooks[]|select(.name=="scope-absent").discord_report' "$reg")" "null" \
    "a playbook with no discord_report frontmatter must leave the registry flag null so delivery falls back to the settings allow-list (backward compat)"
}

test_scan_warns_on_stale_discord_report_trigger() {
  # scope-each is an active playbook this scan produces; no-such-playbook is stale.
  echo '{"discord_report_triggers":["scope-each","no-such-playbook"]}' > "$CEO_DIR/settings.json"
  _run_scan
  assert_contains "$SCAN_OUT" "no-such-playbook" \
    "scan must warn when a discord_report_triggers entry has no matching active playbook"
  assert_not_contains "$SCAN_OUT" "WARN: stale discord_report_trigger: scope-each" \
    "scan must not warn about an allow-list entry that IS an active playbook"
}

test_all_active_skill_runner_playbooks_declare_out_pattern() {
  # Invariant (ceo-cron.sh runner:skill branch, :1408): a runner:skill playbook
  # with an empty out_pattern fails at cron time with "runner:skill but no
  # 'out_pattern' field". weekly-synthesis shipped runner:skill without an
  # out_pattern and failed silently every Sunday 08:00 until the CEO->Discord
  # delivery fix surfaced it. Lint the real shipped docs so no skill-runner can
  # ship without one again (test-expected-from-production-entry-point: reads the
  # shipped files, does not rebuild the frontmatter).
  local pdir="$SCRIPT_DIR/../docs/playbooks"
  assert_file_exists "$pdir/weekly-synthesis.md" "shipped playbook docs must exist"
  local f fm op offenders=""
  for f in "$pdir"/*.md; do
    [ -f "$f" ] || continue
    fm=$(awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f{print}' "$f")
    printf '%s\n' "$fm" | grep -qE '^runner:[[:space:]]*skill[[:space:]]*$' || continue
    printf '%s\n' "$fm" | grep -qE '^status:[[:space:]]*(archived|disabled|retired)' && continue
    op=$(printf '%s\n' "$fm" | grep -E '^out_pattern:' | head -1 | sed 's/^out_pattern:[[:space:]]*//')
    [ -n "$op" ] || offenders="$offenders $(basename "$f")"
  done
  assert_eq "$offenders" "" \
    "every active runner:skill playbook must declare a non-empty out_pattern (ceo-cron.sh :1408 fails the run otherwise)"
}

test_all_runnable_playbooks_declare_a_resolvable_preflight() {
  # A playbook whose preflight_<name>() does not exist has no work gate, and
  # ceo-cron.sh now refuses to dispatch it (exit 78) rather than running
  # unconditionally in silence. That turns a typo into a dead playbook, so catch it
  # here instead of at 09:00. This was live: preflight_has_auto_review_prs() was
  # deleted while archive/auto-review.md still declared it (#307).
  #
  # Same non-recursive "$pdir"/*.md walk as the out_pattern lint above, so
  # docs/playbooks/archive/ is exempt for free — a retired playbook may name a
  # function that was deleted with it.
  #
  # `disabled` and `draft` are deliberately NOT skipped, unlike the out_pattern
  # lint. ceo-cron.sh:1316 allows manual:disabled and manual:draft, so a disabled
  # playbook run by hand hits the same fail-closed branch — and archive/README.md's
  # revive runbook says to check `preflight:` before flipping status, which is
  # exactly the moment an unlinted one bites. All four currently-disabled docs
  # resolve, so this costs nothing today and closes the hole.
  local pdir="$SCRIPT_DIR/../docs/playbooks"
  local cron="$SCRIPT_DIR/ceo-cron.sh"
  assert_file_exists "$cron" "ceo-cron.sh must exist — it defines the preflights"
  local f fm pf offenders=""
  for f in "$pdir"/*.md; do
    [ -f "$f" ] || continue
    fm=$(awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f{print}' "$f")
    # SCHEMA.md and friends live in this dir and are not playbooks.
    printf '%s\n' "$fm" | grep -qE '^name:' || continue
    printf '%s\n' "$fm" | grep -qE '^status:[[:space:]]*(archived|retired)' && continue
    pf=$(printf '%s\n' "$fm" | grep -E '^preflight:' | head -1 | sed 's/^preflight:[[:space:]]*//')
    [ -n "$pf" ] || continue
    # Digits are part of a legal name — preflight_has_log_entries_after_4pm is real,
    # and a [a-z_]-only pattern reports it as missing.
    grep -qE "^preflight_${pf}\(\)" "$cron" || offenders="$offenders $(basename "$f"):$pf"
  done
  assert_eq "$offenders" "" \
    "every runnable playbook's preflight: must name a preflight_<name>() defined in ceo-cron.sh"
}

# cmd_preflight re-defines every preflight inline, because it cannot source
# ceo-cron.sh mid-script (scripts/ceo:636). Two copies of the same list drift, and
# the drift is invisible: a preflight defined only in ceo-cron.sh makes `ceo
# preflight` — the command whose entire job is previewing what cron will do —
# report FAIL for a playbook that runs fine, and one defined only in ceo does the
# reverse. Names are compared, not bodies; the bodies legitimately differ (the
# preview's are read-only probes).
test_preflight_definitions_agree_between_ceo_and_ceo_cron() {
  local cron="$SCRIPT_DIR/ceo-cron.sh"
  local cli="$SCRIPT_DIR/ceo"
  local in_cron in_cli
  # Tolerates `function foo`, a space before the parens, and leading indentation —
  # ceo's copies are indented inside cmd_preflight and ceo-cron.sh's are not, and a
  # pattern that only matched one spelling would report a phantom mismatch on a
  # reformat.
  local _pat='^[[:space:]]*(function[[:space:]]+)?preflight_[a-z0-9_]+[[:space:]]*\(\)'
  in_cron=$(grep -oE "$_pat" "$cron" | grep -oE 'preflight_[a-z0-9_]+' | sort -u)
  in_cli=$(grep -oE "$_pat" "$cli" | grep -oE 'preflight_[a-z0-9_]+' | sort -u)
  assert_contains "$in_cron" "preflight_none" \
    "sanity: the extraction must find ceo-cron.sh's preflights at all"
  assert_contains "$in_cli" "preflight_none" \
    "sanity: and ceo's inline copies too"
  assert_eq "$(comm -23 <(printf '%s\n' "$in_cron") <(printf '%s\n' "$in_cli") | tr '\n' ' ')" "" \
    "every preflight ceo-cron.sh defines must also exist in cmd_preflight, or the preview reports FAIL for a playbook that runs"
  assert_eq "$(comm -13 <(printf '%s\n' "$in_cron") <(printf '%s\n' "$in_cli") | tr '\n' ' ')" "" \
    "and vice versa, or the preview reports RUN for a playbook cron refuses"
}

# docs/playbooks/archive/ is inert only because scan enumerates "$d"/*.md
# non-recursively (ceo:1406). Nothing asserted that, so a change to a find-based or
# **/*.md walk would silently re-register the three retired AwesomeMotive playbooks
# — against a board and repos Nathan can no longer reach — with the suite green.
#
# The fixture is deliberately status: active. #307 also set status: disabled on all
# three archived docs, which is a second gate; this test has to fail on the glob
# alone, or it passes for the wrong reason and stops guarding the thing it names.
test_scan_does_not_recurse_into_a_playbooks_subdirectory() {
  mkdir -p "$CEO_DIR/playbooks/archive"
  _write_playbook "$CEO_DIR/playbooks/archive/retired-thing.md" "retired-thing" ""
  _run_scan
  assert_not_contains "$SCAN_OUT" "retired-thing" \
    "scan must not descend into playbooks/archive/ (ceo:1406 is a non-recursive glob)"
  assert_no_match "$(jq -r '.playbooks[].name' "$HOME/.ceo/registry.json" 2>/dev/null)" \
    "retired-thing" "and must not register it"
}

# The positive control for the test above. If scan stopped registering *anything*,
# the non-recursion assertion would pass while meaning nothing.
test_scan_registers_a_playbook_in_the_top_level_dir() {
  _write_playbook "$CEO_DIR/playbooks/top-level-thing.md" "top-level-thing" ""
  _run_scan
  assert_contains "$(jq -r '.playbooks[].name' "$HOME/.ceo/registry.json" 2>/dev/null)" \
    "top-level-thing" "scan must register a playbook that sits directly in playbooks/"
}

test_scan_warns_when_vault_shadows_repo_with_differing_copy() {
  # The silent-stale foot-gun: a vault playbook shadows a repo playbook of the
  # same name AND the two differ, so scan used the (possibly stale) vault copy.
  # Scan must emit an actionable warning pointing at `ceo playbook sync`.
  local repo="$TMP/repo-playbooks"
  mkdir -p "$repo"
  export CEO_REPO_PLAYBOOK_DIR="$repo"
  # vault copy of 'scope-each' already exists (setup); write a DIFFERING repo copy.
  {
    echo "---"; echo "name: scope-each"; echo "description: scope-each desc"
    echo "trigger: chat"; echo "schedule: \"\""; echo "status: active"
    echo "runner: claude"; echo "scope: each"
    echo "---"; echo ""; echo "# scope-each"; echo "REPO-SIDE DIVERGENT BODY"
  } > "$repo/scope-each.md"
  _run_scan
  assert_contains "$SCAN_OUT" "ceo playbook sync" \
    "scan must tell the user to run 'ceo playbook sync' when a stale vault copy shadows a differing repo playbook"
  assert_contains "$SCAN_OUT" "DIFFERING vault copy" \
    "scan drift warning must name the differing-shadow condition"
}

test_scan_no_shadow_drift_warning_when_no_repo_dir() {
  # Default setup has no repo dir → no shadow possible → no drift warning noise.
  _run_scan
  assert_not_contains "$SCAN_OUT" "ceo playbook sync" \
    "scan must not emit the sync warning when there is no repo dir to shadow"
}

run_tests
