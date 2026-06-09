#!/usr/bin/env bash
# Run every prompt in prompts/ through each model via the local ollama API
# (temperature 0, deterministic), writing one output file per (task,model) and
# a stats TSV. Grading is a separate step (grade.py) so outputs are inspectable.
#
#   bash run.sh "gemma4:12b-it-qat gpt-oss:20b"
#   MODELS="gemma4:12b-it-qat gpt-oss:20b mistral-small3.2:24b" bash run.sh
#
# Requires: a running ollama daemon (default 127.0.0.1:11434), jq, curl.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS="$HERE/prompts"
OUT="$HERE/out"
HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
MODELS="${1:-${MODELS:-gemma4:12b-it-qat gpt-oss:20b}}"
# Cap output so a degenerate runaway (observed: gemma4 once emitted 65k tokens /
# ~18 min on the contradiction task) can't hang a run. All tasks here answer in
# well under this. Raise via env for genuinely long-form tasks.
NUM_PREDICT="${CEO_EVAL_NUM_PREDICT:-2048}"

mkdir -p "$OUT"
command -v jq >/dev/null   || { echo "ERROR: jq not found" >&2; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl not found" >&2; exit 1; }

STATS="$OUT/stats.tsv"
printf 'task\tmodel\teval_count\ttoks_per_sec\ttotal_dur_s\n' > "$STATS"

for PFILE in "$PROMPTS"/*.txt; do
  TASK="$(basename "$PFILE" .txt)"
  P="$(cat "$PFILE")"
  for MODEL in $MODELS; do
    SAFE="$(echo "$MODEL" | tr ':/' '.-')"
    REQ="$(jq -n --arg m "$MODEL" --arg p "$P" --argjson n "$NUM_PREDICT" '{model:$m,prompt:$p,stream:false,options:{temperature:0,num_predict:$n}}')"
    # Distinguish an infrastructure failure (daemon down, model not pulled, HTTP
    # error, non-JSON body) from a real model answer. Without this a failed call
    # is graded as a wrong answer and reads as a model-quality loss.
    BODY="$(curl -s --max-time "${CEO_EVAL_HTTP_TIMEOUT:-600}" -w '\n%{http_code}' "http://$HOST/api/generate" -d "$REQ")"
    CURL_RC=$?
    HTTP="${BODY##*$'\n'}"; BODY="${BODY%$'\n'*}"
    APIERR="$(printf '%s' "$BODY" | jq -r '.error // empty' 2>/dev/null)"
    if [ "$CURL_RC" -ne 0 ] || [ "$HTTP" != "200" ] || [ -n "$APIERR" ]; then
      printf '__EVAL_ERROR__ curl_rc=%s http=%s %s\n' "$CURL_RC" "$HTTP" "$APIERR" > "$OUT/$TASK--$SAFE.txt"
      printf '%s\t%s\tERR\tERR\tERR\n' "$TASK" "$MODEL" >> "$STATS"
      echo "ERROR $TASK / $MODEL : curl_rc=$CURL_RC http=$HTTP ${APIERR:+ollama: $APIERR}" >&2
      continue
    fi
    printf '%s' "$BODY" | jq -r '.response // "ERROR"' > "$OUT/$TASK--$SAFE.txt"
    EC="$(printf '%s' "$BODY" | jq -r '.eval_count // 0')"
    ED="$(printf '%s' "$BODY" | jq -r '.eval_duration // 1')"
    TD="$(printf '%s' "$BODY" | jq -r '.total_duration // 0')"
    TPS="$(awk -v c="$EC" -v d="$ED" 'BEGIN{ if(d>0) printf "%.1f", c/(d/1e9); else print "0" }')"
    TDS="$(awk -v d="$TD" 'BEGIN{ printf "%.0f", d/1e9 }')"
    printf '%s\t%s\t%s\t%s\t%s\n' "$TASK" "$MODEL" "$EC" "$TPS" "$TDS" >> "$STATS"
    echo "ran $TASK / $MODEL : ${TPS} tok/s, ${TDS}s"
  done
done

echo "=== stats ==="
cat "$STATS"
echo "outputs in $OUT/  — grade with: python3 grade.py"
