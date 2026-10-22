#!/bin/bash
# Guard: no credential-shaped literal in the tree (#572).
#
# A credential-shaped literal is a provider prefix (ghp_, sk-, AKIA, ...)
# followed by a token-length body (>= 16 alnum chars) in the same line.
# The two sanctioned assembly sites (fake-credentials.sh, fake_credentials.py)
# are exempt because they ARE the convention; every other hit is a regression.
#
# Run: bash scripts/ceo-fake-credentials.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# The two sanctioned assembly sites. Their body literals are the convention;
# a scanner pattern needs a provider prefix AND a token-length body in one
# line, and the example lines in both files show the joined shape.
EXEMPT=(
  "scripts/fake-credentials.sh"
  "ollama-agent/tests/fake_credentials.py"
)

# Provider prefixes that a secret scanner would key on, followed by >= 16
# alnum chars. Word-boundary guards prevent false positives on identifiers
# like `task_spec` matching `sk_` + 16 chars.
#   \b before the prefix: no alnum immediately before
#   \b after the body:    no alnum immediately after
PATTERN='\b(gh[pousr]_|github_pat_|xox[abprs]-|AIza|AKIA|sk-|(sk|rk|pk)_(live|test)_|hf_|npm_|glpat-)[A-Za-z0-9_-]{16,}\b'

FILES=$(git -C "$REPO_ROOT" ls-files -- '*.sh' '*.py' '*.js' '*.ts' '*.jsonl' '*.json') || {
  echo "FAIL: git ls-files failed; the guard cannot enumerate the tree"
  exit 1
}

FAILS=0
CHECKED=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  rel="${f#"$REPO_ROOT"/}"
  skip=0
  for ex in "${EXEMPT[@]}"; do
    [ "$rel" = "$ex" ] && skip=1 && break
  done
  [ "$skip" = 1 ] && continue
  CHECKED=$((CHECKED + 1))
  hits=$(grep -nE "$PATTERN" "$REPO_ROOT/$f"); rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "FAIL: grep could not read $rel (exit $rc)"
    FAILS=$((FAILS + 1))
  elif [ "$rc" -eq 0 ]; then
    FAILS=$((FAILS + 1))
    echo "FAIL: credential-shaped literal in $rel"
    echo "$hits" | head -5
    echo "  -> use fake_token (scripts/fake-credentials.sh) or fake_secret (ollama-agent/tests/fake_credentials.py)"
    echo "  -> #572: assemble at runtime, never bake a credential-shaped literal into source"
    echo
  fi
done <<< "$FILES"

if [ "$CHECKED" -eq 0 ]; then
  echo "FAIL: no files were checked; the guard would pass vacuously"
  exit 1
fi
if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS file(s) with credential-shaped literals ($CHECKED checked)."
  echo "Fix: source the helper and assemble at runtime. See #572."
  exit 1
fi
echo "OK: no credential-shaped literals found ($CHECKED files checked)."
