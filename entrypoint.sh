#!/usr/bin/env bash
set -euo pipefail

# Warn (don't fail) if expected mounts are missing, so ad-hoc runs still work.
for d in /workspace/merge_tools /workspace/unified-llm-eval /models /output; do
    [ -e "$d" ] || echo "[entrypoint] note: $d is not mounted" >&2
done

mkdir -p "${HF_HOME:-/cache/huggingface}" 2>/dev/null || true

exec "$@"
