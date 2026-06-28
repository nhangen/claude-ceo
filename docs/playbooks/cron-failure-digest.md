---
name: cron-failure-digest
description: Local-model digest of recent CEO cron failures into a vault report — the first runner:ollama-agent playbook.
trigger: manual
preflight: none
# `tier: read` is the cron-side notification posture; the bridge task tier
# (low-stakes-write, in the `registry` JSON below) is the delegation gate. Two
# axes, not a contradiction — token-intake is likewise tier:read yet writes a
# report. Do not "fix" the read/write divergence.
tier: read
status: active
runner: ollama-agent
model: gpt-oss:20b
task: cron-failure-digest
registry: {"tasks":{"cron-failure-digest":{"runner":"ollama","model":"gpt-oss:20b","tier":"low-stakes-write","tools":["read_file","run_shell","write_file","list_dir"],"rules":false,"skills":false}}}
artifact: CEO/reports/cron-failures/{TODAY}-{HOST}.md
---
You are summarizing recent CEO cron failures. Your working directory is the vault's CEO directory, so every path below is relative to it. Do exactly these steps, then stop:

1. Read the recent run and skip logs, pre-filtered to drop this digest's own lines (either log may be large or absent):
   run_shell: { tail -n 200 log/cron-runs.log 2>/dev/null; echo "===SKIPS==="; tail -n 200 log/cron-skips.log 2>/dev/null; } | grep -v cron-failure-digest
2. Find the failure and skip lines in that output (self-lines are already removed).
3. Compute the output path:
   run_shell: echo "reports/cron-failures/$(date +%F)-$(hostname -s).md"
4. Make the directory:
   run_shell: mkdir -p reports/cron-failures
5. write_file the report to that path. It must start with a `# Cron failures <date>` heading, then one bullet per distinct failing or skipped playbook with its most recent timestamp and reason. If there were no failures or skips, the body must be exactly: `No cron failures or skips in the recent logs.`
6. Reply with a one-line summary (e.g. "Wrote digest: N playbooks with failures") and make no further tool calls.
