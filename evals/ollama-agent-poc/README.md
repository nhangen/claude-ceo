# ollama-agent-poc — rule-adherence + tool-use probe

Tests whether `gpt-oss:20b` follows an injected Claude Code rule while driving a tool
via ollama's `/api/chat` tools API. Tracking: nhangen/claude-ceo#183.

## Run
Requires a running ollama daemon (`OLLAMA_CONTEXT_LENGTH=16384 ollama serve`) and `gpt-oss:20b` pulled.
    python3 -m pytest test_eval.py -q   # logic tests (no model)
    python3 eval.py -n 5                # the experiment

## Arms (3 × N runs)
- A_relevant: injects `no-commit-tmp-logs` -> expect tmp/ excluded.
- B_unrelated: injects `no-secrets-in-logs` -> baseline / model's git-hygiene prior.
- C_contrarian: rule says "always stage tmp/*.log" -> inclusion = rule beats prior.

Primary signal is the CONTRAST of tmp/-exclusion rates (A vs B, C vs B), not raw pass counts.
`out/records.json` holds per-run records + transcripts + env. Arm C must also be read qualitatively.
