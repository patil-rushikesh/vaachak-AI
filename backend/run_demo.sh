#!/bin/sh
set -eu
cd "$(dirname "$0")"
export VAACHAK_DATA_DIR="${VAACHAK_DATA_DIR:-$(pwd)/data}"
if [ -z "${VAACHAK_WHISPER_MODEL:-}" ]; then
  model_path=$(find "$VAACHAK_DATA_DIR/models" -name model.bin 2>/dev/null | head -n 1 || true)
  if [ -n "$model_path" ]; then
    export VAACHAK_WHISPER_MODEL="$(dirname "$model_path")"
  fi
fi
# Opt in to semantic AI explicitly; no external provider is selected by default.
# Example: VAACHAK_TEXT_PROVIDER=ollama VAACHAK_TEXT_MODEL=qwen2.5:0.5b-instruct ./run_demo.sh
uv run --extra speech uvicorn vaachak_backend.api:create_app --factory --host 127.0.0.1 --port "${PORT:-8000}"
