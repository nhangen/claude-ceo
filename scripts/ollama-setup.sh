#!/bin/bash
# ollama-setup.sh — Bootstrap script to pull default local models for the CEO agent
set -euo pipefail
trap 'echo "ERROR: ollama-setup failed at line $LINENO" >&2' ERR

if ! command -v ollama &>/dev/null; then
  echo "ERROR: ollama CLI not found. Please install Ollama first:"
  echo "https://ollama.com/download"
  exit 1
fi

echo "Pulling default models for CEO agent runners..."

echo "1/2: Pulling gemma4:12b-it-qat (default for 'runner: ollama')..."
ollama pull gemma4:12b-it-qat
echo "1/2: OK"

echo "2/2: Pulling gpt-oss:20b (default for 'runner: ollama-think')..."
ollama pull gpt-oss:20b
echo "2/2: OK"

echo ""
echo "Setup complete. The CEO agent is ready to dispatch local playbooks."
