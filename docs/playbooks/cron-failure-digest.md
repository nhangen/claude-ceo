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
model: mistral-small3.2:24b
task: cron-failure-digest
registry: {"tasks":{"cron-failure-digest":{"runner":"ollama","model":"mistral-small3.2:24b","tier":"low-stakes-write","tools":["read_file","run_shell","write_file","list_dir"],"rules":false,"skills":false}}}
artifact: CEO/reports/cron-failures/{TODAY}-{HOST}.md
---
You are writing a digest of recent CEO cron failures. Your working directory is the vault's CEO directory. Make EXACTLY two tool calls, then stop with a one-line summary — do NOT run extra searches, greps, or re-reads (over-exploring is what makes this task fail to finish).

1. ONE `run_shell`. Run only this command — it prints the output path, creates the directory, and emits all relevant log content with this digest's own lines removed:
   echo "OUTPATH=reports/cron-failures/$(date +%F)-$(hostname -s).md"; mkdir -p reports/cron-failures; { tail -n 200 log/cron-runs.log 2>/dev/null; echo "===SKIPS==="; tail -n 200 log/cron-skips.log 2>/dev/null; } | grep -v cron-failure-digest
2. ONE `write_file` to the OUTPATH printed in step 1. Write a `# Cron failures <date>` heading, then one bullet per distinct playbook with an action-required line — those containing `ERROR`, `FATAL`, `failed`, `did not complete`, or `not authenticated` — with its latest timestamp and reason. `FATAL` lines (e.g. a missing or corrupt registry) are the highest priority: they mean the whole cron is failing to dispatch, so never omit them. **Ignore only routine "last run too recent" cooldown skips — those are benign.** If nothing matched, the body must be exactly: `No cron failures in the recent logs.`

Then reply with a one-line summary (e.g. "Wrote digest: N failing playbooks") and make NO further tool calls.
