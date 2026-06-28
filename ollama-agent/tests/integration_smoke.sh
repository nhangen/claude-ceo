#!/usr/bin/env bash
# integration_smoke.sh — live, end-to-end verification of the local-model stack:
#   bridge (oll)  ·  claude-code-router (ccr)  ·  oll-code (real Claude Code on ollama)
#
# Every check guards its own prerequisites and SKIPs (not fails) when a service
# is absent, so this is safe to run anywhere. Exit code is non-zero only on a
# real FAIL. Not a unit test — it hits live ollama/ccr/claude and is slow.
#
#   bash ollama-agent/tests/integration_smoke.sh
#   OLL_MODEL=gpt-oss:20b bash ollama-agent/tests/integration_smoke.sh
set -uo pipefail

MODEL="${OLL_MODEL:-gpt-oss:20b}"
OLLAMA="${OLLAMA_HOST:-http://127.0.0.1:11434}"
CCR="${CCR_URL:-http://127.0.0.1:3456}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BRIDGE="$REPO_ROOT/ollama-agent/cli.py"
PY="${OLL_PY:-/opt/anaconda3/bin/python}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0; SKIP=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mSKIP\033[0m %s (%s)\n' "$1" "$2"; SKIP=$((SKIP+1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }
ollama_up() { curl -s -m 5 "$OLLAMA/api/tags" 2>/dev/null | grep -q '"models"'; }
model_present() { curl -s -m 5 "$OLLAMA/api/tags" 2>/dev/null | grep -q "\"$MODEL\""; }
ccr_up() { curl -s -m 5 "$CCR/" >/dev/null 2>&1 || curl -s -m 5 "$CCR/v1/messages" -X POST -d '{}' >/dev/null 2>&1; }

anthropic_msg() { # $1=json body -> response body on stdout
  curl -s -m 120 "$CCR/v1/messages" \
    -H 'content-type: application/json' -H 'x-api-key: test' \
    -H 'anthropic-version: 2023-06-01' -d "$1" 2>&1
}

# ---------------------------------------------------------------------------
section "Prerequisites"
if ollama_up; then pass "ollama daemon reachable at $OLLAMA"; else
  skip "ollama daemon" "not reachable at $OLLAMA"; fi
if ollama_up && model_present; then pass "model $MODEL present"; else
  ollama_up && skip "model $MODEL" "not pulled"; fi

# ---------------------------------------------------------------------------
section "Bridge (oll) — native ollama tool API"
if ! ollama_up || ! model_present; then
  skip "bridge edit" "ollama/model unavailable"
elif [ ! -f "$BRIDGE" ]; then
  skip "bridge edit" "bridge not found at $BRIDGE"
elif [ ! -x "$PY" ]; then
  skip "bridge edit" "python not at $PY (set OLL_PY)"
else
  printf 'alpha\nbeta\ngamma\n' > "$WORK/b.txt"
  "$PY" "$BRIDGE" --model "$MODEL" --cwd "$WORK" --no-rules --no-skills --turn-cap 6 \
    --task "Edit b.txt: change 'beta' to 'BETA-OK'. Read it then write it back." >/dev/null 2>&1
  if grep -q "BETA-OK" "$WORK/b.txt"; then pass "bridge edited a file via native tools"; else
    fail "bridge edit did not land (b.txt unchanged)"; fi
fi

# ---------------------------------------------------------------------------
section "ccr proxy — chat + thinking strip + tool round-trip"
if ! ccr_up; then
  skip "ccr chat" "ccr not reachable at $CCR (run: ccr start)"
  skip "ccr thinking-strip" "ccr down"
  skip "ccr tool round-trip" "ccr down"
else
  # chat round-trip. gpt-oss and other reasoning models spend output tokens on
  # reasoning before the visible answer, so the cap must be generous or the
  # response truncates (stop_reason=max_tokens, empty content) before "PONG".
  R=$(anthropic_msg "{\"model\":\"ollama,$MODEL\",\"max_tokens\":1024,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: PONG\"}]}")
  if echo "$R" | grep -qi "PONG"; then pass "ccr chat round-trip"; else
    fail "ccr chat round-trip ($(echo "$R" | head -c 140))"; fi

  # thinking field must not 400
  R=$(anthropic_msg "{\"model\":\"ollama,$MODEL\",\"max_tokens\":1024,\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":1024},\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: PONG\"}]}")
  if echo "$R" | grep -qi "does not support thinking"; then
    fail "thinking-strip: ollama 400'd on thinking field"
  elif echo "$R" | grep -qi "PONG"; then pass "ccr thinking-strip (no 400)"; else
    fail "thinking-strip: unexpected ($(echo "$R" | head -c 140))"; fi

  # tool round-trip via real claude -p (single tool call = deterministic plumbing)
  if have claude; then
    printf 'WATERMELON\n' > "$WORK/probe.txt"
    OUT=$(ANTHROPIC_BASE_URL="$CCR" ANTHROPIC_API_KEY="test" ANTHROPIC_MODEL="ollama,$MODEL" \
      CLAUDE_CODE_MAX_OUTPUT_TOKENS="4096" \
      claude -p "Read $WORK/probe.txt and tell me the single word inside it." \
      --model "ollama,$MODEL" --dangerously-skip-permissions 2>&1)
    if echo "$OUT" | grep -qi "WATERMELON"; then pass "ccr tool round-trip (claude -p read a file)"; else
      fail "ccr tool round-trip ($(echo "$OUT" | grep -iv connectors | head -c 140))"; fi
  else
    skip "ccr tool round-trip" "claude CLI not installed"
  fi
fi

# ---------------------------------------------------------------------------
section "oll-code — real Claude Code harness on the local model"
if ! ccr_up || ! have claude; then
  skip "oll-code" "ccr or claude unavailable"
elif ! have oll-code; then
  skip "oll-code" "oll-code not on PATH"
else
  # Default oll-code: curated always-loaded toolset (ccr ollama-compat cap), no
  # tool-search — local models don't drive ToolSearch reliably (gpt-oss refuses,
  # deepseek hallucinates), so deferred tools are unreachable. Read is in the
  # always-loaded core, so this exercises the real harness end to end.
  printf 'WATERMELON\n' > "$WORK/probe.txt"
  OUT=$(oll-code -p "Read $WORK/probe.txt and tell me the single word inside it." \
    --dangerously-skip-permissions 2>&1)
  if echo "$OUT" | grep -qi "WATERMELON"; then
    pass "oll-code read a file (curated toolset)"
  else
    fail "oll-code read ($(echo "$OUT" | grep -iv connectors | head -c 140))"
  fi
fi

# ---------------------------------------------------------------------------
section "Summary"
printf 'PASS=%d  FAIL=%d  SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
