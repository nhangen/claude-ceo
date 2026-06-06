---
name: ticket-triage-autopilot
description: Poll for merged PRs every 30 min; on new merges route ticket-triage by repo owner (ZenHub for AM, GitHub issues for personal) and append top-3 adjacency-scored tickets to inbox.md
trigger: cron
schedule: "*/30 * * * *"
preflight: none
tier: low-stakes write
status: active
runner: script
script: ceo-triage-autopilot.sh
---

# Ticket Triage Autopilot

Shell-only playbook. Every 30 minutes it checks for newly merged PRs by the configured author across the repos in `~/.config/branch-cleanup/repos.md`. If any new merges are seen since the last check, it spawns `claude --print` to invoke the `/ticket-triage` skill, parses a strict JSON contract from the output, and appends the top-3 tickets to `$CEO_VAULT/CEO/inbox.md`.

State machine, not signal generator. A cron tick with no new merges writes the state file and a log line and does nothing else.

## Owner routing (#146)

ZenHub and the `nhangenam` account are AM-only; personal `nhangen/*` repos have no ZenHub board, so their tickets come from GitHub issues (the `ticket-triage` skill's GitHub source, #133). On a tick with new merges, each merge's repo is classified by owner:

| Owner class (default) | Source | Spawn |
|---|---|---|
| `awesomemotive`, `nhangenam` | ZenHub pipeline (`CEO_TRIAGE_PIPELINE`) | One spawn covering all AM merges — the OM ZenHub workspace is "All Products", unified across optinmonster/trustpulse/beacon/comment-converter, so a single pipeline triage serves every AM repo. |
| `nhangen` | GitHub issues for that repo | One spawn per distinct personal repo (the skill takes a single `owner/repo` slug). |
| anything else (e.g. `altamira2`) | — | Skipped with a logged reason. The merge still advances the cursor so it is not re-evaluated every tick. |

A tick is `firing` only if at least one triage spawn ran. Skip-only ticks are `clear` and advance the cursor. If **any** spawned source fails, the cursor is held (the existing retry-cap give-up still applies on the aggregate failure count) so a failed source's merge window is not dropped — re-running next tick is cheap because inbox markers dedup already-written tickets.

## Origin

Issue #125. Initial design used a Stop hook on `pr-review-panel` — that doesn't work because Stop fires on agent yield, not GitHub events. The cron-poll mechanism replaces it.

## Outputs

| File | Mode | When |
|---|---|---|
| `CEO/alerts/triage-autopilot-<host>.md` | overwrite | Every run. Frontmatter: `status: firing\|clear`, `since:`, `last_check:`, `host:`, `last_merge_check:` (the search-cursor timestamp for the next run), `new_merges:` (count seen this run), `triage_ran:` (`0\|1`), `consec_failures:`, `last_error:` (one of `none`, `gh_failed:<slug>`, `jq_annotate:<slug>`, `missing_remote:<basename>`, `inbox_append_failed`). |
| `CEO/log/triage-autopilot/YYYY-MM.md` | append | Every run. One line. |
| `CEO/inbox.md` | append `- [ ]` lines | (a) On a tick where new merges were seen AND triage emitted valid JSON: one line per ticket (≤3). (b) On retry-cap give-up: one self-deduping `<!-- triage-autopilot:giveup:<date> -->` line so the user knows the playbook abandoned a merge window. Per-ticket idempotency via `<!-- triage-autopilot:<ticket-id> -->`. |

## State-machine semantics

- **First run**: records `last_merge_check = now`, status `clear`, does NOT spawn triage. The first cron tick after install establishes the baseline; the first *real* fire happens on the next merge after that.
- **No new merges**: status `clear`, refresh `last_merge_check`, log a one-liner.
- **New merges seen, triage runs, JSON valid**: status `firing`, append up to 3 inbox lines (dedup against existing markers in `inbox.md`), advance `last_merge_check` to "now".
- **`gh` failure on every repo (auth expiry, rate-limit, network)**: status `clear`, `last_error: gh_failed:<slug>`, cursor does NOT advance. The next tick retries the same merge window. Per `safety-invariant-scope`, `gh` errors and "no merges" are distinguished structurally — failures never collapse to a clean tick.
- **New merges seen but triage fails or JSON invalid**: status `firing`, do NOT advance `last_merge_check`, log the failure, no inbox writes. Bounded retry: after 3 consecutive failures the cursor advances AND a `- [ ] Triage autopilot gave up after N tries — manual /ticket-triage needed for merges since <ts> <!-- triage-autopilot:giveup:<date> -->` line is appended to `inbox.md` (idempotent within the day). This prevents a permanently-broken triage from blocking the cursor *and* surfaces the give-up to the user.

## Idempotency

`inbox.md` is the canonical inbox file for the user's notes. Every line written by this playbook carries `<!-- triage-autopilot:<ticket-id> -->`. Before append, the playbook greps `inbox.md` for that exact marker — if present (checked or unchecked), the line is skipped. Multi-host vault sync is tolerated: another host that already wrote the line is detected at write time, not via state-file coordination.

## Environment overrides (test seams)

- `CEO_GH_BIN` — substitute `gh` binary. Tests inject a stub.
- `CEO_TRIAGE_CLAUDE_BIN` — substitute `claude` binary. Tests inject a stub emitting canned JSON.
- `CEO_TRIAGE_REPO_LIST` — substitute repo-list markdown file (default `~/.config/branch-cleanup/repos.md`).
- `CEO_TRIAGE_PIPELINE` — ZenHub pipeline alias to pass to `/ticket-triage` for AM repos (default `inbox`).
- `CEO_TRIAGE_ZENHUB_OWNERS` — space-separated repo owners routed to the ZenHub source (default `awesomemotive nhangenam`).
- `CEO_TRIAGE_GITHUB_OWNERS` — space-separated repo owners routed to the GitHub-issues source (default `nhangen`).

## The JSON contract with claude

The wrapper prompt instructs claude to invoke `/ticket-triage <pipeline>` and emit a **single fenced JSON block** at end-of-output with this schema:

```json
{
  "tickets": [
    { "id": "OM-1234", "title": "Short title", "url": "https://app.zenhub.com/...", "score": 0.83, "reason": "adjacent to recent work on X" }
  ]
}
```

Up to 3 entries. The wrapper extracts the first JSON block, validates `tickets` is an array of length ≤ 3 with required keys, and only then appends to inbox. Any parse failure → no inbox writes, failure logged.

## Disable

Set `status: disabled` in this file (or in a vault override at `$CEO_VAULT/CEO/playbooks/ticket-triage-autopilot.md`) and re-scan **on ML-1** (`ceo playbook scan` installs host-local schedulers + rewrites the synced `registry.json`, so it runs only on ML-1 — see the `ceo-scan-only-on-ml1` rule). Editing this file activates nothing on its own; the next ML-1 scan picks up the status change.
