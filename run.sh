#!/usr/bin/env bash
# Launch the merge-tools container with code, models, and caches mounted.
#
# Usage:
#   ./run.sh                          # interactive shell
#   ./run.sh python merge_tools_archive/merge_pipeline.py --config /config/merge.yml
#
# Override any of these via environment variables:
#   MODELS_DIR  - directory holding input fine-tuned models   (default: /tmp/merge-models)
#   OUTPUT_DIR  - where merged models / eval results land      (default: /tmp/merge-output)
#   CACHE_DIR   - HF hub cache; keep OFF NFS home (9.7G free!) (default: /tmp/hf-cache)
#   CONFIG_DIR  - merge/benchmark configs                      (default: ./config if present)
set -euo pipefail

IMAGE="${IMAGE:-merge-tools:latest}"
CODE_ROOT="${CODE_ROOT:-/nethome/ian6}"
CODE_STAGE="${CODE_STAGE:-/tmp/merge-code}"
MODELS_DIR="${MODELS_DIR:-/tmp/merge-models}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/merge-output}"
CACHE_DIR="${CACHE_DIR:-/tmp/hf-cache}"

mkdir -p "$MODELS_DIR" "$OUTPUT_DIR" "$CACHE_DIR" "$CODE_STAGE"

# The canonical repo name is merge_tools; accept a local checkout under either name.
if [ -d "$CODE_ROOT/merge_tools" ]; then
    MERGE_TOOLS_SRC="$CODE_ROOT/merge_tools"
elif [ -d "$CODE_ROOT/merge_tools_archive" ]; then
    MERGE_TOOLS_SRC="$CODE_ROOT/merge_tools_archive"
else
    echo "error: no merge_tools (or merge_tools_archive) directory under $CODE_ROOT" >&2
    exit 1
fi

# The docker daemon (root) cannot read root-squashed NFS homes, so code must be
# staged on local disk before mounting. Edits go in $CODE_ROOT as usual; each run
# re-syncs. Staged under the canonical name regardless of the source dir name.
rsync -a --delete --exclude __pycache__ \
    "$MERGE_TOOLS_SRC/" "$CODE_STAGE/merge_tools/"
rsync -a --delete --exclude __pycache__ \
    "$CODE_ROOT/unified-llm-eval" "$CODE_STAGE/"

EXTRA_MOUNTS=()
if [ -n "${CONFIG_DIR:-}" ]; then
    EXTRA_MOUNTS+=(-v "$CONFIG_DIR":/config)
fi

exec docker run --rm -it \
    --gpus all \
    --shm-size=16g \
    -v "$CODE_STAGE/merge_tools":/workspace/merge_tools \
    -v "$CODE_STAGE/unified-llm-eval":/workspace/unified-llm-eval \
    -v "$MODELS_DIR":/models \
    -v "$OUTPUT_DIR":/output \
    -v "$CACHE_DIR":/cache \
    "${EXTRA_MOUNTS[@]}" \
    "$IMAGE" "$@"
