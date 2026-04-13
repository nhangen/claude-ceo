#!/bin/bash
set -euo pipefail

# ceo-cron.sh — Autonomous CEO agent execution via cron.
# Usage: ceo-cron.sh <trigger>
# Example: ceo-cron.sh morning-brief
#
# Two-phase execution:
#   1. Plan: read-only, outputs JSON action list with tiers
#   2. Execute: shell filters out high-stakes actions, executes the rest
#
# High-stakes actions are written to CEO/approvals/pending.md, not executed.

TRIGGER="${1:?Usage: ceo-cron.sh <trigger>}"
VAULT="$HOME/Documents/Obsidian"
CEO_DIR="$VAULT/CEO"
LOG_DIR="$CEO_DIR/log"
TODAY=$(date +%Y-%m-%d)
NOW=$(date +%H:%M)
LOG_FILE="$LOG_DIR/$TODAY.md"

# --- Runaway protection ---
if [ -f "$LOG_FILE" ]; then
  LAST_MOD=$(stat -c %Y "$LOG_FILE" 2>/dev/null || stat -f %m "$LOG_FILE" 2>/dev/null || echo 0)
  NOW_EPOCH=$(date +%s)
  if [ $((NOW_EPOCH - LAST_MOD)) -lt 1800 ]; then
    echo "$(date): Skipping $TRIGGER — last run too recent" >> "$LOG_DIR/cron-skips.log"
    exit 0
  fi
fi

# --- Validate vault ---
if [ ! -f "$CEO_DIR/AGENTS.md" ]; then
  echo "$(date): ERROR — CEO vault structure not found at $CEO_DIR" >> "$LOG_DIR/cron-skips.log"
  exit 1
fi

if [ ! -f "$CEO_DIR/SKILLS.md" ]; then
  echo "$(date): ERROR — SKILLS.md not found" >> "$LOG_DIR/cron-skips.log"
  exit 1
fi

# --- Match trigger to playbook ---
# Read SKILLS.md, find the row matching the trigger, extract the playbook path
PLAYBOOK_REL=$(grep "^| $TRIGGER " "$CEO_DIR/SKILLS.md" | awk -F'|' '{print $3}' | xargs)

if [ -z "$PLAYBOOK_REL" ]; then
  echo "$(date): No playbook matched trigger '$TRIGGER'" >> "$LOG_DIR/cron-skips.log"
  exit 0
fi

PLAYBOOK_FILE="$CEO_DIR/$PLAYBOOK_REL"

if [ ! -f "$PLAYBOOK_FILE" ]; then
  echo "$(date): Playbook file not found: $PLAYBOOK_FILE (trigger: $TRIGGER)" >> "$LOG_DIR/cron-skips.log"
  exit 0
fi

# --- Check playbook status ---
STATUS=$(grep "^| $TRIGGER " "$CEO_DIR/SKILLS.md" | awk -F'|' '{print $6}' | xargs)
if [ "$STATUS" != "active" ]; then
  echo "$(date): Playbook '$TRIGGER' is not active (status: $STATUS)" >> "$LOG_DIR/cron-skips.log"
  exit 0
fi

# --- Read context files ---
AGENTS_CONTENT=$(cat "$CEO_DIR/AGENTS.md")
IDENTITY_CONTENT=$(cat "$CEO_DIR/IDENTITY.md")
TRAINING_CONTENT=$(cat "$CEO_DIR/TRAINING.md")
PLAYBOOK_CONTENT=$(cat "$PLAYBOOK_FILE")

# Read domain-specific training if it exists
DOMAIN_TRAINING=""
for TF in "$CEO_DIR/training/"*.md; do
  if [ -f "$TF" ] && grep -qi "$TRIGGER" "$TF" 2>/dev/null; then
    DOMAIN_TRAINING=$(cat "$TF")
    break
  fi
done

# --- Ensure log directory exists ---
mkdir -p "$LOG_DIR"

# --- Create log file header if new ---
if [ ! -f "$LOG_FILE" ]; then
  cat > "$LOG_FILE" << LOGEOF
---
date: $TODAY
type: ceo-log
---

# CEO Log — $TODAY
LOGEOF
fi

# --- Phase 1: Plan (read-only) ---
PLAN_PROMPT="You are the CEO agent running autonomously via cron.

GLOBAL AGENT RULES:
$AGENTS_CONTENT

CEO IDENTITY:
$IDENTITY_CONTENT

TRAINING:
$TRAINING_CONTENT

$DOMAIN_TRAINING

PLAYBOOK ($TRIGGER):
$PLAYBOOK_CONTENT

Execute this playbook now. You are running autonomously — there is no human in the loop.

For any action that is HIGH-STAKES (push code, merge PRs, create PRs, close issues, delete remote branches, or anything that sends notifications to others):
DO NOT EXECUTE IT. Instead, write a proposal in this exact format:
PROPOSAL: {description of action} | repo: {repo} | reasoning: {why}

For all other actions (read, low-stakes write), execute them directly.

After completing all actions, write a summary in this exact format:
LOG_ENTRY:
## $NOW — $TRIGGER
**Status:** {completed|failed|partial}
**Playbook:** $PLAYBOOK_REL
**Actions:**
- {what you did}
**Proposals:**
- {any high-stakes proposals, or 'none'}
**Errors:**
- {any errors, or 'none'}
END_LOG_ENTRY"

# --- Execute ---
OUTPUT=$(claude --print --max-turns 10 "$PLAN_PROMPT" 2>&1) || true

# --- Extract log entry ---
LOG_ENTRY=$(echo "$OUTPUT" | sed -n '/^LOG_ENTRY:/,/^END_LOG_ENTRY/p' | sed '1d;$d')

if [ -n "$LOG_ENTRY" ]; then
  echo "" >> "$LOG_FILE"
  echo "$LOG_ENTRY" >> "$LOG_FILE"
else
  # Fallback: write raw output summary
  cat >> "$LOG_FILE" << FALLBACK

## $NOW — $TRIGGER

**Status:** unknown
**Playbook:** $PLAYBOOK_REL
**Note:** Could not parse structured log output. Raw output saved to cron-raw.log.
FALLBACK
  echo "$(date) [$TRIGGER] Raw output:" >> "$LOG_DIR/cron-raw.log"
  echo "$OUTPUT" >> "$LOG_DIR/cron-raw.log"
  echo "---" >> "$LOG_DIR/cron-raw.log"
fi

# --- Extract and append proposals to pending.md ---
PROPOSALS=$(echo "$OUTPUT" | grep "^PROPOSAL:" | sed 's/^PROPOSAL: //')

if [ -n "$PROPOSALS" ]; then
  PENDING="$CEO_DIR/approvals/pending.md"
  echo "" >> "$PENDING"
  echo "## $TODAY $NOW" >> "$PENDING"
  echo "" >> "$PENDING"
  while IFS= read -r proposal; do
    DESC=$(echo "$proposal" | awk -F'|' '{print $1}' | xargs)
    REPO=$(echo "$proposal" | awk -F'|' '{print $2}' | xargs | sed 's/repo: //')
    REASON=$(echo "$proposal" | awk -F'|' '{print $3}' | xargs | sed 's/reasoning: //')
    echo "- [ ] **$DESC**" >> "$PENDING"
    echo "  - repo: $REPO" >> "$PENDING"
    echo "  - playbook: $TRIGGER" >> "$PENDING"
    echo "  - reasoning: $REASON" >> "$PENDING"
    echo "" >> "$PENDING"
  done <<< "$PROPOSALS"
fi

echo "$(date): $TRIGGER completed" >> "$LOG_DIR/cron-runs.log"
