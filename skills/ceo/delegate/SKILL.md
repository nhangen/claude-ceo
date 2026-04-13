---
name: ceo-delegate
description: Hand off a task to the CEO agent for execution. Triggers on "/ceo:delegate", "ceo do this", "hand this off", "delegate this".
version: 0.1.0
---

# CEO Delegate

Accept a task from the user, match it to a playbook, and execute it.

## Config

Read vault path from the obsidian plugin config: `~/.claude/plugins/cache/nhangen/obsidian/*/obsidian.local.md`

Set `$VAULT` to the vault_path value.

## Arguments

The user provides a task description after the command, e.g.:
- `/ceo:delegate review PR #6980`
- `/ceo:delegate triage open PRs`
- `/ceo:delegate fix the linting errors in PR #7001`

## Steps

1. **Read global agent rules** — read `$VAULT/CEO/AGENTS.md`.

2. **Read CEO identity** — read `$VAULT/CEO/IDENTITY.md`.

3. **Read training** — read `$VAULT/CEO/TRAINING.md` and the domain-specific training file matching the task type.

4. **Read skills dispatch table** — read `$VAULT/CEO/SKILLS.md`.

5. **Match task to playbook** — compare the user's task description against the Task Type Index in SKILLS.md:
   - Match by keywords (e.g., "review PR" → pr-review, "triage" → pr-triage, "brief" → morning-brief)
   - If ambiguous, ask the user: "This could match [type A] or [type B]. Which playbook should I follow?"
   - If no match: say "No playbook matches this task. I can attempt it without a playbook, or you can create one. What would you prefer?"

6. **Read matched playbook** — read `$VAULT/CEO/playbooks/<matched-type>.md`.
   - If the playbook file doesn't exist yet, tell the user: "Playbook `<type>.md` is listed in SKILLS.md but hasn't been created yet. Want me to create a starter playbook based on your task?"

7. **Execute playbook** — follow the playbook steps, respecting authority tiers:
   - **Read actions:** execute freely
   - **Low-stakes write actions:** execute and log
   - **High-stakes actions:** propose to user for approval before executing (in interactive mode, ask inline rather than writing to pending.md)

8. **Log results** — append to `$VAULT/CEO/log/YYYY-MM-DD.md`:

   ```markdown
   ## HH:MM — <task-type>

   **Status:** completed | failed | partial
   **Playbook:** playbooks/<type>.md
   **Delegated task:** <user's original description>
   **Actions:**
   - <what was done>
   **Audibles:**
   - <deviations from playbook, if any>
   **Errors:**
   - <errors encountered, if any>
   ```

9. **Report back** — summarize what was done to the user.

## Without a Playbook

If the user confirms they want to proceed without a playbook:
1. Assess the task and propose an action plan with tiers
2. Wait for user approval of the plan
3. Execute approved actions, log results
4. After completion, ask: "Want me to save this as a playbook for next time?"
