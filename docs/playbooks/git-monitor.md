---
name: git-monitor
description: Scans repositories for dirty worktrees and out-of-date branches
trigger: cron
schedule: "0 10,16 * * 1-5"
preflight: none
tier: read
status: active
runner: script
script: ceo-git-monitor.sh
---

# Git Monitor

Scans known workspace directories for Git repositories and alerts if any have dirty worktrees (uncommitted changes) or if their current branch is behind the remote tracking branch.

## Origin

Written by Antigravity in response to a request for proactive dirty-worktree monitoring.

## Outputs

| File | Mode | When |
|---|---|---|
| `CEO/alerts/git-monitor.md` | overwrite | Every run. Contains a list of dirty repos and repos behind origin. |
| `CEO/inbox/git-monitor.md` | append `- [ ]` line | On `clear → firing` transition. Idempotent. |

## Disable

Set `status: inactive` in this file and run `ceo playbook scan`.
