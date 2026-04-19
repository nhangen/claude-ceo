---
name: ceo-train
description: Add a training rule or update a playbook from conversation. Triggers on "/ceo:train", "remember this rule", "add this to training", "update the playbook".
version: 0.1.0
---

# CEO Train

Record a training rule or playbook update from the user's correction or instruction.

## Config

Resolve `$VAULT` using this fallback chain (first match wins):
1. Environment variable `$CEO_VAULT` (if set)
2. Obsidian plugin config: `~/.claude/plugins/cache/nhangen/obsidian/*/obsidian.local.md` → read `vault_path`
3. Default: `~/Documents/Obsidian`

If `$VAULT/CEO/AGENTS.md` does not exist, ask the user where their Obsidian vault is installed and use that path.

## Two Modes

### Mode 1: Explicit Rule

User provides a rule directly:
```
/ceo:train "always check CI before posting review comments"
/ceo:train "morning briefs should include Sentry error counts"
```

Steps:
1. Parse the rule from the user's input.
2. Determine the domain — match keywords to training file names:
   - PR/review/merge/CI → `training/pr-review.md`
   - Brief/morning/summary → `training/briefings.md`
   - Tone/format/style → `training/communication.md`
   - Repo/clone/branch/worktree → `training/repos.md`
   - General/none of the above → `TRAINING.md`
3. Read the target file.
4. Append the rule in format: `- <rule text> (added YYYY-MM-DD)`
5. Update the `last_updated` field in frontmatter.
6. Confirm: "Added to `<file>`: <rule text>"

### Mode 2: Conversational Correction

During a session, the user corrects the CEO's behavior:
```
User: "No, don't post the review comment yet — check if CI has finished first"
```

The CEO detects this is a correction and offers to record it:
```
CEO: "Got it — I'll check CI status before posting comments. Want me to add this as a training rule?"
User: "yes"
```

Steps:
1. Distill the correction into a concise rule (strip conversational context).
2. Follow Mode 1 steps 2-6.

### Mode 3: Playbook Update

If a correction changes a workflow step (not just adding a rule):
```
User: "Add a CI check step before posting comments in the PR review playbook"
```

Steps:
1. Read the relevant playbook from `$VAULT/CEO/playbooks/`.
2. Propose the edit — show the current step and the proposed change.
3. Wait for user approval.
4. Apply the edit.
5. Update `last_updated` in frontmatter.
6. Confirm: "Updated `playbooks/<name>.md`: <description of change>"

### Mode 4: New Playbook

If the user wants to create a new playbook:
```
/ceo:train create playbook for deployment checks
```

Steps:
1. Ask the user to describe the workflow steps.
2. Check `$VAULT/CEO/SKILLS.md` — if a task type with this name already exists, tell the user and ask if they want to update the existing playbook instead.
3. Write to `$VAULT/CEO/playbooks/<name>.md` with numbered steps.
4. Add an entry to `$VAULT/CEO/SKILLS.md` dispatch table (with `status: active`).
5. Confirm: "Created `playbooks/<name>.md` and added to SKILLS.md dispatch table."

## Constraints

- Always show the user what was written and where.
- Never silently modify training files or playbooks.
- If the target file doesn't exist, create it with proper frontmatter.
- Keep rules concise — one line per rule, strip conversational filler.
