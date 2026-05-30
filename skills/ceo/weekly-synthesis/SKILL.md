---
name: weekly-synthesis
description: Generate the candid weekly memo on Nathan's work. Loads the Synthesist identity, gathers GitHub / local git / Obsidian / claude-mem / rules data for the past 7 days, synthesizes themes + new ideas + drift, writes to CEO/reports/, and pipes the executive summary to Discord. Invoked by the weekly-synthesis playbook (Sun 08:00).
---

# Weekly Synthesis Skill

## Identity

**Before doing anything else**, load `~/Documents/Obsidian/CEO/agents/synthesist.md` and adopt that voice for the duration of this skill. Not the CEO voice. The Synthesist voice.

## Window

`WINDOW_START = date -v-7d +%Y-%m-%d`
`WINDOW_END = date +%Y-%m-%d`
`ISO_WEEK = date +%G-W%V`

## Steps

1. **Gather inputs in parallel** (single message, multiple tool calls):
   - `gh search prs --author nhangen --merged ">=$WINDOW_START" --limit 200 --json repository,number,title,state,mergedAt`
   - `gh search prs --author nhangen --updated ">=$WINDOW_START" --state open --limit 100 --json repository,number,title,updatedAt`
   - For each repo in `~/.config/branch-cleanup/repos.md`: `git -C <path> log --all --author=nhangen --since=$WINDOW_START --pretty=format:'%h %ai %s'`
   - `find ~/Documents/Obsidian/Daily -name "*.md" -newer <reference> -type f`
   - `find ~/.claude/rules -name "*.md" -newer <reference> -type f`
   - `mcp__plugin_claude-mem_mcp-search__timeline` for the window
   - `gh issue list --author nhangen --state open --limit 100 --json repository,number,title,createdAt,updatedAt`

2. **Read daily notes** for the window before drawing any conclusions about the day-job. Cite causes when explaining gaps.

3. **Diff capability vs signal** for new projects. Tag explicitly.

4. **Count drift** — every idle epic gets a day-count.

5. **Read rule incidents** — for each new file in `~/.claude/rules/` this week, extract the "Why" / "Incident" section. The pattern across them is the meta-observation.

6. **Synthesize** following the structure in `synthesist.md`. 600–900 words. Pick. Don't list.

7. **Write** to `~/Documents/Obsidian/CEO/reports/weekly-synthesis-{ISO_WEEK}.md` with frontmatter.

8. **Link** the report from this week's daily note under `## Session Links`. If the daily note doesn't exist for today, create it from `~/Documents/Obsidian/Templates/daily.md`.

9. **Extract executive summary** — the top-line + new-ideas list + flagged-items section only. Add a vault link to the full memo.

10. **Post to Discord** via `~/Code/claude-ceo/scripts/ceo-discord-report.sh weekly-synthesis "<executive-summary>"`. Verify `weekly-synthesis` is in `~/Documents/Obsidian/CEO/settings.json -> .discord_report_triggers` before posting.

## Anti-Patterns

- **Do not** open with a productivity-praise sentence.
- **Do not** list every PR. Aggregate by theme.
- **Do not** assume drift before reading daily notes.
- **Do not** invent file paths, PR numbers, or commit hashes.
- **Do not** post the full memo to Discord. Executive summary only.
- **Do not** end with a pep talk.

## Failure Modes

- `gh` offline → log skip, exit 0.
- Repo list missing → log skip, exit 0.
- claude-mem MCP down → continue without observations; note in the memo.
- Discord webhook missing → write the report, log Discord skip, exit 0.

## Output Contract

The user opens his vault Sunday morning. He reads the report. If it tells him something he didn't already know — a drift he hadn't noticed, an idea he hadn't named, a pattern across the rules — the skill succeeded. If it reads like a polished `gh search` output, it failed.
