# Ollama Setup for CEO Agent

The CEO agent supports local inference via the `runner: ollama` and `runner: ollama-think` options in playbook frontmatter. This allows you to run deterministic, high-throughput, or privacy-sensitive tasks locally without incurring API costs.

## Default Models

If a playbook uses an ollama runner but does not specify a `model:`, the system defaults to:
- `runner: ollama`: `mistral-small3.2:24b`
- `runner: ollama-think`: `gpt-oss:20b`

These models were chosen as the optimal balance between capability and speed for a local 16GB-24GB VRAM environment.

## Bootstrap Script

To quickly pull the required default models on a new host, run the provided bootstrap script:

```bash
bash scripts/ollama-setup.sh
```

## Manual Setup

If you prefer to pull the models manually, or if you want to use custom models:

```bash
# Pull the standard playbook runner (fast, capable)
ollama pull mistral-small3.2:24b

# Pull the thinking/reasoning runner (slower, methodical)
ollama pull gpt-oss:20b
```

## Scan-Time Validation

When you run `ceo playbook scan`, the agent will check your local `ollama list` to verify that the required models (either defaults or explicitly defined `model:` overrides) are available. If a required model is missing, the playbook will be skipped during scan time with a diagnostic message, preventing runtime failures.
