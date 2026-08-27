#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
THUNDERAGENT_DIR="$ROOT_DIR/.deps/ThunderAgent"
HARBOR="$ROOT_DIR/.venv/bin/harbor"
max_attempts=${HARBOR_WARMUP_MAX_ATTEMPTS:-5}
concurrency=${HARBOR_WARMUP_CONCURRENCY:-8}

[[ -x "$HARBOR" ]] || { echo "ERROR: run scripts/setup_harbor.sh first." >&2; exit 1; }
docker info >/dev/null

cd "$THUNDERAGENT_DIR/examples/datagen/harbor"
for ((attempt = 1; attempt <= max_attempts; attempt++)); do
  echo "Harbor image warm-up pass $attempt/$max_attempts (concurrency=$concurrency)."
  "$HARBOR" warmup pull --path datasets/swebench --n-concurrent "$concurrency"
  cache_status=$("$HARBOR" warmup pull --path datasets/swebench --dry-run)
  printf '%s\n' "$cache_status"
  if grep -q '^Need: 0 pulls, 0 builds$' <<<"$cache_status"; then
    echo "Harbor image cache verified complete."
    exit 0
  fi
  sleep 5
done

echo "ERROR: Harbor image cache is incomplete after $max_attempts passes." >&2
exit 1
