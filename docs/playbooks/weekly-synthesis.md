---
name: weekly-synthesis
description: Candid weekly memo on Nathan's work — themes, new ideas, drift, rule incidents. Not a PR list.
trigger: cron
schedule: "0 8 * * SUN"
model: opus
preflight: none
tier: read
status: active
discord_report: true
runner: skill
skill: weekly-synthesis
out_pattern: CEO/reports/weekly-synthesis-${TODAY}.md
---

# Weekly Synthesis

Produces a 600–900 word candid memo over the past 7 days. Loads the Synthesist identity (separate voice from the CEO), gathers data across GitHub, local git, Obsidian daily notes, and new rules, then synthesizes themes / new ideas / drift / rule patterns / flagged items.

## Origin

Written 2026-05-30 in a session that began as a request for a weekly work analysis. The conversation surfaced that there is no opinionated weekly report — only `personal-weekly-merges` (data pull, not synthesis). This playbook codifies the synthesis pass the user kept getting only by manually asking follow-up questions.

## Identity

Loads `CEO/agents/synthesist.md`. Distinct voice from `CEO/IDENTITY.md` — direct, opinionated, anchors every claim to a citation, calls out drift, refuses pep talks. Hard rule baked in: verify before diagnosing the day-job gap.

## Outputs

| File | Mode | When |
|---|---|---|
| `CEO/reports/weekly-synthesis-YYYY-MM-DD.md` | create | Every Sunday 08:00. The full memo. (Ceo-cron substitutes `${TODAY}`.) |
| `Daily/YYYY-MM-DD.md` (today's daily) | append link under `## Session Links` | Every run. |
| Discord webhook (`weekly-synthesis` trigger) | post | Executive summary only (top line + new ideas + flagged items) + vault link. Requires `weekly-synthesis` in `CEO/settings.json -> .discord_report_triggers`. |

## Inputs Gathered

- `gh search prs --author nhangen` (merged / open / closed in last 7d)
- `git log --author=nhangen --since=-7d` across every repo in `~/.config/branch-cleanup/repos.md`
- `~/Documents/Obsidian/Daily/*.md` for the 7-day window (cause-checking for day-job gap)
- `~/.claude/rules/*.md` with mtime in window (new rule = incident)
- `gh issue list --author nhangen --state open` (drift / aging idle epics)

## Synthesis Rules (enforced by skill)

- Capability vs signal — every new project gets tagged one way or the other.
- Drift requires a day-count, not just a name.
- Day-job gap is verified against daily notes before being called drift.
- No false themes — if the week was uneven, say so.

## Documented Gaps

- **Skill distribution.** Source lives at `~/Code/llm-tools/home/.claude/skills/weekly-synthesis/` (canonical, git-tracked in llm-tools, sibling to `workload-report`). Installed at `~/.claude/skills/weekly-synthesis/` on each host via the llm-tools sync mechanism. NOT shipped via the `nhangen-tools/ceo` plugin — the `runner: skill` ceo-cron field references CEO-skill names under `~/.claude/skills/`, distinct from Claude Code plugin skills.
- **No retry / failure routing.** If the synthesis run fails mid-flight, no alert lands in `CEO/inbox/`. Add a `CEO/alerts/weekly-synthesis.md` state file with `last_run_status` if this becomes load-bearing.

## Disable

Set `status: inactive` in this file and the vault playbook, then run `ceo playbook scan` on ML-1.

## Related

- Vault playbook: `CEO/playbooks/weekly-synthesis.md` (active definition; this doc is the registry-side declaration per `ceo-automated-writers-are-playbooks` rule).
- Identity: `CEO/agents/synthesist.md`.
- Skill source: `llm-tools` repo → `home/.claude/skills/weekly-synthesis/` (scripts/run-report.sh + prompt.md + SKILL.md). Installed at `~/.claude/skills/weekly-synthesis/` per host.
- Sibling discord-reporting playbook: `morning-brief`.
