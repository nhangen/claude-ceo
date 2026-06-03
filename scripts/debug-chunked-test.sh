#!/bin/bash
# Debug: run ceo-cron.sh with proper jq stub
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRON="$SCRIPT_DIR/ceo-cron.sh"

TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

export HOME="$TEST_HOME"
export CEO_VAULT="$TEST_HOME/vault"
export CEO_DIR="$CEO_VAULT/CEO"
export CEO_OLLAMA_SKIP_PROBE=1
export CEO_LOCK_FILE="$TEST_HOME/ceo-cron.lock"
mkdir -p "$CEO_DIR/playbooks" "$CEO_DIR/log" "$CEO_DIR/reports" "$CEO_DIR/inbox" "$CEO_DIR/approvals"
: > "$CEO_DIR/AGENTS.md"
: > "$CEO_DIR/IDENTITY.md"
: > "$CEO_DIR/TRAINING.md"
: > "$CEO_DIR/approvals/pending.md"
: > "$HOME/.fake-crontab"
mkdir -p "$TEST_HOME/.bun/bin"
export PATH="$TEST_HOME/.bun/bin:$PATH"

# jq stub — copy the updated jq-stub.js from scripts/
cp "$SCRIPT_DIR/jq-stub.js" "$TEST_HOME/.bun/bin/jq.js"
: << 'DEAD_CODE'
const args = process.argv.slice(2);
let rawOutput = false, compactOutput = false, exitStatus = false;
let filter = '';
let inputFile = null;
const argVars = {};

for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '-r') { rawOutput = true; continue; }
  if (a === '-c') { compactOutput = true; continue; }
  if (a === '-e') { exitStatus = true; continue; }
  if (a === '-rc' || a === '-cr') { rawOutput = true; compactOutput = true; continue; }
  if (a === '--arg') { argVars[args[++i]] = args[++i]; continue; }
  if (a.startsWith('-') && !a.startsWith('--')) { continue; } // unknown flags
  if (!filter) { filter = a; continue; }
  if (!inputFile) { inputFile = a; }
}

function applyFilter(obj, f, vars) {
  f = (f || '.').trim();
  // .field // "default"
  const defaultMatch = f.match(/^(.+?)\s*\/\/\s*("([^"]*)"|\$([a-zA-Z_]\w*)|null|empty|"")$/);
  if (defaultMatch) {
    const inner = defaultMatch[1].trim();
    const defStr = defaultMatch[3] !== undefined ? defaultMatch[3] :
                   defaultMatch[4] ? (vars[defaultMatch[4]] || '') : '';
    const val = applyFilter(obj, inner, vars);
    if (val === null || val === undefined || val === '') return defStr;
    return val;
  }
  // .playbooks[] | select(.name == $t)
  const selectMatch = f.match(/^\.(\w+)\[\]\s*\|\s*select\(\.(\w+)\s*==\s*\$(\w+)\)$/);
  if (selectMatch) {
    const arr = obj ? obj[selectMatch[1]] : null;
    if (!Array.isArray(arr)) return null;
    const key = selectMatch[2], varName = selectMatch[3];
    const wantVal = vars[varName];
    return arr.find(item => item[key] === wantVal) || null;
  }
  // index($k) != null
  const indexMatch = f.match(/^index\(\$(\w+)\)\s*!=\s*null$/);
  if (indexMatch) {
    const needle = vars[indexMatch[1]];
    if (!Array.isArray(obj)) return false;
    return obj.indexOf(needle) !== -1;
  }
  // .field[]? or .field[]
  const iterMatch = f.match(/^\.(\w+)\[\]\??$/);
  if (iterMatch) {
    const arr = obj ? obj[iterMatch[1]] : null;
    return Array.isArray(arr) ? arr : [];
  }
  // .field
  const fieldMatch = f.match(/^\.(\w+)$/);
  if (fieldMatch) {
    const v = obj ? obj[fieldMatch[1]] : null;
    return v !== undefined ? v : null;
  }
  // . (identity)
  if (f === '.') return obj;
  return null;
}

function outputVal(v) {
  if (v === null || v === undefined) {
    if (exitStatus) process.exit(1);
    process.stdout.write('null\n');
    return;
  }
  if (typeof v === 'boolean') {
    if (exitStatus && !v) process.exit(1);
    process.stdout.write((v ? 'true' : 'false') + '\n');
    return;
  }
  if (rawOutput && typeof v === 'string') { process.stdout.write(v + '\n'); return; }
  if (compactOutput) { process.stdout.write(JSON.stringify(v) + '\n'); return; }
  process.stdout.write(JSON.stringify(v, null, 2) + '\n');
}

function processData(input) {
  let data;
  try { data = JSON.parse(input.trim() || 'null'); } catch(e) { process.exit(1); }
  const result = applyFilter(data, filter, argVars);
  const isIterFilter = /\[\]\??/.test(filter) && !filter.includes('select') && !filter.includes('//');
  if (isIterFilter && Array.isArray(result)) {
    result.forEach(item => outputVal(item));
  } else {
    outputVal(result);
  }
}

if (inputFile) {
  try {
    const input = require('fs').readFileSync(inputFile, 'utf8');
    processData(input);
  } catch(e) { process.exit(1); }
} else {
  const chunks = [];
  process.stdin.on('data', d => chunks.push(d));
  process.stdin.on('end', () => processData(Buffer.concat(chunks).toString('utf8')));
}
DEAD_CODE

cat > "$TEST_HOME/.bun/bin/jq" << 'SHIM'
#!/bin/bash
exec node "$(dirname "$0")/jq.js" "$@"
SHIM
chmod +x "$TEST_HOME/.bun/bin/jq"

# crontab stub
cat > "$TEST_HOME/.bun/bin/crontab" << 'STUB'
#!/bin/bash
if [ "${1:-}" = "-l" ]; then cat "$HOME/.fake-crontab" 2>/dev/null || true; exit 0; fi
cat > "$HOME/.fake-crontab"
STUB
chmod +x "$TEST_HOME/.bun/bin/crontab"

# yq stub: prevents path-lookup noise; ceo-cron.sh itself does not call yq
cat > "$TEST_HOME/.bun/bin/yq" << 'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$TEST_HOME/.bun/bin/yq"

# ollama stub
cat > "$TEST_HOME/.bun/bin/ollama" << 'STUB'
#!/bin/bash
if [ "${1:-}" = "run" ]; then
  echo "$2" >> "$HOME/ollama-invoked-model.txt"
  cat >> "$HOME/ollama-invoked-prompts.txt"
  printf '\n---CALL---\n' >> "$HOME/ollama-invoked-prompts.txt"
  echo "LOG_ENTRY:"
  echo "## 03:10 — morning-scan"
  echo "**Status:** completed"
  echo "**Playbook:** playbooks/morning-scan.md"
  echo "**Output:**"
  echo "- chunked-scan-sentinel"
  echo "**Errors:**"
  echo "- none"
  echo "END_LOG_ENTRY"
  exit 0
fi
exit 0
STUB
chmod +x "$TEST_HOME/.bun/bin/ollama"

# registry
cat > "$CEO_DIR/registry.json" << 'JSON'
{
  "schema_version": 3,
  "generated": "2026-06-02T00:00:00Z",
  "playbooks": [{
    "name": "morning-scan",
    "description": "chunked scan test",
    "trigger": "cron",
    "schedule": "50 8 * * 1-5",
    "model": "mistral-small3.2:24b",
    "preflight": "none",
    "tier": "read",
    "status": "active",
    "runner": "ollama",
    "script": "",
    "skill": "",
    "out_pattern": "",
    "inputs": null,
    "requires": null,
    "file": "playbooks/morning-scan.md"
  }]
}
JSON

# playbook
cat > "$CEO_DIR/playbooks/morning-scan.md" << 'PB'
---
name: morning-scan
description: chunked scan test
trigger: cron
schedule: "50 8 * * 1-5"
runner: ollama
model: mistral-small3.2:24b
preflight: none
tier: read
status: active
---
# morning-scan body
PB

touch -t 202501010000 "$CEO_DIR/log/.last-scan"

mkdir -p "$CEO_VAULT/Projects" "$CEO_VAULT/Areas"
for i in $(seq 1 8); do
  echo "project note content $i" > "$CEO_VAULT/Projects/note-$i.md"
done
echo "area work content" > "$CEO_VAULT/Areas/work.md"

_yesterday=$(date -d yesterday +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d)
_today=$(date +%Y-%m-%d)
mkdir -p "$CEO_VAULT/Daily"
{ echo "# Yesterday Daily Note"; for _ in $(seq 1 80); do echo "yesterday content line for morning scan test"; done; } > "$CEO_VAULT/Daily/$_yesterday.md"
{ echo "# Today Daily Note"; for _ in $(seq 1 40); do echo "today content line for morning scan test"; done; } > "$CEO_VAULT/Daily/$_today.md"
{ echo "# CEO Report"; for _ in $(seq 1 40); do echo "yesterday report line for morning scan test"; done; } > "$CEO_DIR/reports/$_yesterday.md"

echo "=== PATH check ==="
which jq
jq --version 2>/dev/null || echo "jq version check failed"

echo "=== registry content ==="
cat "$CEO_DIR/registry.json"

echo "=== registry file exists at ==="
ls -la "$CEO_DIR/registry.json"
echo "=== registry schema_version direct ==="
jq -r '.schema_version' "$CEO_DIR/registry.json"
echo "=== registry version check ==="
QUERY='if has("schema_version") and (.schema_version | type) == "number" and (.schema_version | floor == .) then .schema_version else empty end'
echo "Query: $QUERY"
jq -r "$QUERY" "$CEO_DIR/registry.json"
echo "direct node test:"
node "$TEST_HOME/.bun/bin/jq.js" -r "$QUERY" "$CEO_DIR/registry.json"

echo "=== jq self-test ==="
echo '{"playbooks":[{"name":"morning-scan","file":"playbooks/morning-scan.md","runner":"ollama","tier":"read","model":"mistral-small3.2:24b","status":"active","trigger":"cron","preflight":"none","script":"","inputs":null,"requires":null}]}' \
  | jq -r --arg t morning-scan '.playbooks[] | select(.name == $t)'

echo "=== Running ceo-cron.sh morning-scan ==="
rc=0
CEO_OLLAMA_MAX_PROMPT_BYTES=5000 CEO_VERBOSE=1 bash "$CRON" morning-scan 2>&1 || rc=$?
echo "=== Exit code: $rc ==="
echo "=== Ollama calls ==="
wc -l < "$TEST_HOME/ollama-invoked-model.txt" 2>/dev/null || echo 0
echo "=== Today's report (full) ==="
cat "$CEO_DIR/reports/$_today.md" 2>/dev/null || echo "(none)"
echo "=== cron-skips.log ==="
cat "$CEO_DIR/log/cron-skips.log" 2>/dev/null || echo "(none)"
