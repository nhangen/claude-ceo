#!/bin/bash
# Tests that this repo's .gitignore actually ignores the paths that must never
# reach a commit.
#
# Asserted against `git check-ignore` rather than by grepping .gitignore for the
# pattern text, because a pattern's presence is not the property that matters —
# whether git ignores the path is, and the two diverge (a later negation, a
# nested .gitignore, a pattern that anchors differently than it reads). Reverting
# any of the .gitignore lines these cover turns the matching case red.
#
# tmp/ holds cron stdout and hand-run report output that can carry production
# data (no-commit-tmp-logs). evals/*/out/ is generated model output. A single
# mis-staged `git add` nearly committed both on 2026-08-13 (#313).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/test-harness.sh"

# check-ignore needs a path git can decide on, not a path that happens to exist,
# so these are all hypothetical files under the ignored dirs. --no-index keeps a
# tracked path from short-circuiting the answer.
_is_ignored() {
  git -C "$REPO_ROOT" check-ignore -q --no-index "$1" && echo yes || echo no
}

test_tmp_dir_is_ignored() {
  assert_eq "$(_is_ignored tmp/cron-full.out)" "yes" "tmp/ cron stdout is ignored"
  assert_eq "$(_is_ignored tmp/scratch.md)" "yes" "tmp/ scratch markdown is ignored"
}

test_eval_output_dirs_are_ignored() {
  assert_eq "$(_is_ignored evals/ollama-matrix/out/think-01--m.txt)" "yes" \
    "generated eval output is ignored"
  assert_eq "$(_is_ignored evals/some-future-eval/out/x.txt)" "yes" \
    "the rule covers eval dirs that do not exist yet"
}

test_pytest_cache_is_ignored() {
  assert_eq "$(_is_ignored .pytest_cache/CACHEDIR.TAG)" "yes" \
    "root pytest cache is ignored"
  assert_eq "$(_is_ignored ollama-agent/.pytest_cache/v/cache/lastfailed)" "yes" \
    "nested pytest cache is ignored"
}

# The evals/*/out/ rule must not swallow the tracked sentinel that already lives
# in one of those dirs, or a `git status` there stops reporting a real change to
# a file this repo tracks.
test_tracked_sentinel_is_not_ignored() {
  assert_eq "$(_is_ignored evals/ollama-agent-poc/out/.gitignore)" "no" \
    "the tracked out/.gitignore sentinel stays visible"
}

# Guard the inverse: an over-broad pattern that ignored the source tree would
# make every assertion above pass while quietly hiding real work.
test_source_paths_are_not_ignored() {
  assert_eq "$(_is_ignored scripts/ceo)" "no" "the CLI is not ignored"
  assert_eq "$(_is_ignored evals/ollama-agent-poc/eval.py)" "no" \
    "eval source next to an ignored out/ is not ignored"
  assert_eq "$(_is_ignored docs/playbooks/morning-scan.md)" "no" \
    "playbook docs are not ignored"
}

run_tests
