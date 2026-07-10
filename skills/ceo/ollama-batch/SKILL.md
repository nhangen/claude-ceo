---
name: ceo-ollama-batch
description: Batch-delegate oracle-gated coding tasks to a local ollama model with a lean Haiku subagent as PM, so Claude's cost stays small and fixed while the local model authors and iterates for free. Triggers on "/ceo:ollama-batch", "delegate this to ollama", "write code with ollama", "batch these to the local model".
version: 0.1.0
---

# Ollama Batch Delegation (lean-PM recipe)

Delegate code authoring to a local ollama model through the `ollama-agent`
bridge, with a **Haiku subagent as the project manager**. The main session
never writes the code, never reads the code, and never hosts the orchestration
turns. Canonizes the measured 2026-07-09 recipe (issue #266).

**The economics this enforces:** the PM's cost is small and *fixed per task*
($0.21–0.37 measured, 3-task batch ÷ its $0.63–1.10 PM cost), while the local
model's authoring and iteration are free. Savings therefore scale with
authoring volume. The two ways to destroy the savings are (a) orchestrating
from a fat main session (measured 2026-07-09: $0.10–0.90/turn in context
replay — more than an entire small task) and (b) letting the PM read the
implementations. This skill exists to make both hard to do by accident.

## When NOT to use

- **No cheap complete oracle.** If a correctness gate (pytest or equivalent)
  would cost as much to write as the implementation itself (subjective output,
  UI polish, integration surfaces), the mechanism collapses — author directly.
- **Ambiguity the oracle can't capture.** Drive-to-green optimizes to *pass the
  oracle*, not to be right. Delegation handles implementation-ambiguity fine
  (the oracle defines correctness) but not requirement-ambiguity.

## Preconditions

1. `ollama` daemon running with the model pulled — default **`gpt-oss:20b`**
   (tool-capable; `glm4` is text-only and cannot tool-call).
2. A bridge checkout whose head includes the run ledger + session attribution
   (#264, #265): `ollama-agent/` in this repo at current `main`.
3. Each task is self-contained in its own directory (module + test file — no
   repo-wide side effects) or an equivalently isolated worktree.

## Steps

### 1. Scope the batch

Collect N related tasks (batching amortizes the PM's fixed context cost — one
task is allowed but wastes amortization). For each, write a one-paragraph spec
precise enough that a pytest oracle follows mechanically from it.

### 2. Dispatch ONE Haiku subagent as PM

Use the Agent tool: `subagent_type: general-purpose`, `model: haiku`. The PM
prompt must contain, verbatim:

- The base dir, the bridge dir, and the per-task specs.
- **Oracle authoring:** per task, write a pytest oracle (12–18 focused tests:
  happy paths, edges, error cases, roundtrips where applicable — hard to pass
  by hardcoding) plus a stub module where every function raises
  `NotImplementedError` so imports resolve.
- **Oracle-constant validation (mandatory pre-fire step):** any test constant
  with a checkable property (checksums, encodings, known-value pairs) is
  verified by an independent one-liner *before* the bridge fires. This is the
  luhn lesson: a Haiku-authored oracle asserted `5425233010103442` is
  Luhn-valid — it isn't; a correct implementation was flagged red by a wrong
  test. Fail-closed, but it costs a re-run and muddies the ledger.
- **The bridge invocation** (one chained Bash call per task, 600000 timeout):

  ```bash
  cd <bridge-dir> && \
  OLLAMA_AGENT_LEDGER="${XDG_STATE_HOME:-$HOME/.local/state}/ollama-agent/runs.jsonl" \
  CLAUDE_CODE_SESSION_ID=<main-session-id> \
  python3 cli.py \
    --task "<spec>. Edit <mod>.py using your file tools, then run the tests." \
    --model gpt-oss:20b --cwd <task-dir> \
    --verify-cmd "python3 -m pytest -q" \
    --no-rules --no-skills --temperature 0 --turn-cap 10 \
    --ungated --run-id <batch-id>-<n> > <task-dir>/bridge.log 2>&1; \
  grep -E '^(completed|verified)=' <task-dir>/bridge.log
  ```

  `--no-rules --no-skills` is load-bearing: omitting them injects rules/skills
  context into every ollama turn (measured 37k vs 9k input tokens for the same
  task). `--verify-cmd` is the whole mechanism — pytest failures feed back to
  the model automatically and it keeps iterating; nobody billed is in that loop.
- **Blindness rules:** never write implementation code; never read
  implementation files or `bridge.log` beyond `tail -3`; do not use `--json`
  (the record embeds the full transcript). Ground-truth = re-run pytest,
  read the last line. A red task is recorded and moved past — at most one
  re-fire, no hand-fixing.
- **Data-only final report:** per task — run_id, verified, turns,
  `ollama_input_tokens`/`ollama_output_tokens`, read from the ledger by
  **run_id match** (`grep '"run_id": "<batch-id>-<n>"' <ledger> | tail -1`),
  never by file position — the default ledger is shared, and a concurrent
  bridge run (e.g. a ceo-cron task) can append between fire and read. Plus
  the ground-truth pytest tail and one line affirming no implementation was
  written or read. Nothing else.

### 3. Ground-truth and triage (main session, cheap)

Re-run each task's pytest yourself (last line only). For any red task, check
the *oracle* before blaming the implementation: independently verify the
failing test's constants/expectations first. Measured base rate so far:
implementations 4/4 correct; the only red was a bad oracle constant.

**First use of a new task class:** spot-audit the diff once (or dispatch an
auditor) before trusting green — oracle-gaming ships green garbage precisely
when nobody looks.

### 4. Measure

- Ledger rows carry the batch's `--run-id` prefix and the session attribution.
- PM cost: subagent-bucket delta between `token-scope --spend --session <id>`
  runs taken before/after the dispatch (subagent cost is session-wide in v1 —
  isolate the dispatch or account for concurrent agents).
- Net: `token-scope --savings --session <id> --pm-cost <measured-usd>`
  (labels the denominator `measured (caller)`; nhangen/token-scope#16).

## Guardrails (non-negotiable)

1. Main session does not orchestrate — one Agent dispatch in, one data report out.
2. PM never reads or writes implementations.
3. Oracle constants validated programmatically before the bridge fires.
4. `--ungated` is for ad-hoc batches; registered recurring tasks go through the
   registry gate instead (`--registry`/`--task-name`, see `ollama-agent/README.md`).
5. Red ≠ implementation bug until the oracle is checked.
