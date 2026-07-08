# ollama-agent

Run a local [ollama](https://ollama.com) model as a tool-using agent on **bounded** tasks — so a local model can do real work (inspect files, run commands, drive git) without burning Claude tokens, where its quality is good enough.

Part of the [local-agent bridge epic (#185)](https://github.com/nhangen/claude-ceo/issues/185). This is **path A** — local models as cheap workers for bounded tasks under a *curated* slice of the rule/skill/tool stack — not a full reimplementation of the Claude Code harness.

## Status

| Slice | What | State |
|------|------|-------|
| 1 (#186) | Bridge core + real shell/fs/git tools over the `/api/chat` tools API | shipped |
| 2 (#187) | Rule loading + relevance selection | shipped |
| 3 (#188) | Skill resolver | shipped |
| 4 (#189) | MCP tool adapter | shipped |
| 5 (#190) | Governance + task registry (`runner: ollama`) | shipped |
| #200 | `min_score` delegation gate (eval-score-pinned competence) | shipped |

## Usage

```bash
# requires a running ollama daemon with the model pulled
# --ungated: an ad-hoc run applies no delegation gate, so it must opt in explicitly
python ollama-agent/cli.py --task "summarize the README in 3 bullets" \
  --model gpt-oss:20b --cwd /path/to/repo --ungated
```

Flags: `--model`, `--cwd` (the directory tools operate in), `--host`, `--temperature`,
`--num-ctx`, `--turn-cap`, `--shell-timeout`, `--json` (full record), `--system` (override the system prompt),
`--ungated` (opt into an ad-hoc, ungated run — required unless `--task-name` selects a gated registered task).

Governance flags: `--registry` + `--task-name` run a registered task (its model/tier/tools/rules
apply, gated before any model call); `--scores` points at a model-matrix `scores.tsv` for the
`min_score` gate (`--scores-stale-days` warns on old scores).

## Governance (registry + delegation gate)

The canonical registry ships at [`ollama-agent/registry.json`](registry.json). It
intentionally ships **empty** (no delegable entries): enabling a task that pins a
local model in a delegable tier is gated behind the delegation spike ([#255](https://github.com/nhangen/claude-ceo/issues/255))
and blast-radius routing policy ([#254](https://github.com/nhangen/claude-ceo/issues/254)).
A CI guard (`test_committed_registry_enables_no_delegable_tier`) fails if a delegable
entry is added here instead of through that gated work.

Entry shape (`tasks.<name>`):

```jsonc
{
  "runner": "ollama",          // required; only "ollama" is a known runner
  "model": "gpt-oss:20b",      // required; the local model to run
  "tier": "deterministic",     // required; deterministic | low-stakes-write | high-stakes
  "tools": "*",                // optional; "*" or a list of allowed tool names
  "rules": true,               // optional; inject relevance-selected rules (default true)
  "skills": false,             // optional; expose the skill catalog (default false)
  "min_score": 0.9,            // optional; refuse unless the model earned this on eval_task
  "eval_task": "think-02",     // required WHEN min_score is set ("*" = cross-task mean)
  "eval_model": null           // optional; override which model's score is checked
}
```

A registered task (`--registry registry.json --task-name <name>`) is gated **before any model call**:

- `tier: high-stakes` is never delegated to a local model (refused, exit 3); only `deterministic`
  and `low-stakes-write` run. Unknown `runner`/`tier` is rejected, never defaulted.
- `min_score` (optional) refuses delegation unless the model's measured ratio on a pinned
  `eval_task` (from model-matrix `scores.tsv`) meets the threshold. `eval_task` is **required**
  when `min_score` is set — use `eval_task: "*"` to opt into the cross-task mean; an aggregate
  default would let a model that fails the task that matters pass on unrelated tasks. A missing
  score is a refusal, not a silent pass. `eval_model` overrides which model's score is checked.

## Tools

The model is given five real tools, each bounded (timeout + truncated output) and scoped to `--cwd`:

| Tool | Does |
|------|------|
| `run_shell` | run a shell command, return returncode/stdout/stderr |
| `git` | run a git subcommand |
| `read_file` | read a file under cwd |
| `write_file` | write a file under cwd (creates parent dirs) |
| `list_dir` | list a directory under cwd |

**Trust boundary:** `run_shell` runs arbitrary commands by design — that *is* the tool.
There is no command allowlist or path jail yet; per-task tool restriction and
safe-delegation tiering arrive in the governance slice (#190). Until then, treat this
as a deliberately-invoked local tool: you choose `--cwd` and the model you trust.

## Driving a local model three ways

The bridge is one of three ways to put a local ollama model behind a harness:

| Command | Harness | Tools | Use for |
|---------|---------|-------|---------|
| `oll "task"` | the bridge (this dir) | 5 native + `use_skill` + 1 MCP (`--mcp`) | autonomous bounded local work; broad MCP via `--mcp` |
| `oll` | codex REPL | codex's | interactive read/explore |
| `oll-code` | **real Claude Code** via [claude-code-router](https://github.com/musistudio/claude-code-router) → ollama | curated always-loaded set (capped below the ~25 ceiling) | the full Claude harness on a local model |

`oll-code` routes Claude Code's Anthropic API through ccr to ollama's OpenAI
endpoint. ccr needs the `ollama-compat` transformer (`use: ["openai",
"ollama-compat", ["maxtoken", …]]`): the `openai` transformer carries the tools
array (a bare custom transformer list makes ccr drop it), and `ollama-compat`
strips `thinking`/`reasoning` and caps the tool count.

**Tool ceiling (measured):** Claude Code exposes 100+ tools; past ~25 a local
model stops emitting structured `tool_calls` and dumps the call into `content`
as text, breaking the loop. Native tool-search (deferring tools behind a
`ToolSearch` tool) wires all tools but **no installed local model drives it** —
gpt-oss:20b refuses, deepseek-r1:70b hallucinates calls. So `oll-code` defaults
to a curated always-loaded set; for broad MCP with a local model, use the bridge.

## Tests

```bash
python -m pytest ollama-agent/tests -q          # logic tests, no daemon needed
bash ollama-agent/tests/integration_smoke.sh    # live stack: bridge + ccr + oll-code (guarded, self-skips)
```
