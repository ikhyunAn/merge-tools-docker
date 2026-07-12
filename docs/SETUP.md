# Setup Guide — merge-tools Docker environment

This guide covers everything needed to run the model-merging + evaluation stack from a
clean machine: what the container provides, what you must supply, and the exact steps for
building or pulling the image and running an end-to-end merge + eval.

---

## 1. What this container is (and is not)

The image is a **dependency environment only** — a pinned Python 3.12 stack (torch
2.9.0+cu128, vLLM 0.11.2, transformers, lm-eval, mergekit, …) on top of the CUDA 12.8.1
runtime. It contains **no pipeline code**. The code lives in separate repositories that you
mount at runtime. This is deliberate: you can edit code or swap in a different merging repo
without rebuilding the 23 GB image.

| The image provides | You provide (at runtime) |
|---|---|
| Python 3.12 + all pinned dependencies | `merge_tools` repo (merge pipeline) |
| CUDA 12.8 userspace + PyTorch/vLLM | `unified-llm-eval` repo (evaluation) |
| mergekit (fork or stock, per variant) | Input fine-tuned models |
| entrypoint + env (`PYTHONPATH`, `HF_HOME`) | Output + HF cache directories |

---

## 2. Prerequisites (host machine)

1. **NVIDIA GPU + driver** capable of CUDA 12.8 (H200 verified; any recent datacenter or
   RTX card with a driver ≥ 550 works).
2. **Docker** (v25+; v29 verified) with the **NVIDIA Container Toolkit** installed, so
   `--gpus` works. Quick check:
   ```bash
   docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu24.04 nvidia-smi
   ```
   If that prints your GPUs, you are ready.
3. **Local disk space:** ~25 GB for the image, plus room for model weights and the HF
   cache. Keep all of this **off networked/NFS home directories** (see §6).
4. **The two code repositories** checked out locally:
   - `merge_tools` (the merge pipeline; may be checked out under the legacy name
     `merge_tools_archive` — `run.sh` accepts either)
   - `unified-llm-eval` (the evaluation orchestrator)

---

## 3. Get the image

### Option A — pull the prebuilt image (fastest)

```bash
docker pull anjohn0077/merge-tools:latest       # working variant (fork mergekit)
docker pull anjohn0077/merge-tools:reference    # reference-faithful variant
docker tag anjohn0077/merge-tools:latest merge-tools:latest   # run.sh expects this tag
```

### Option B — build from source

```bash
git clone <this-repo> merge-tools-docker
cd merge-tools-docker
docker build -t merge-tools:latest .
docker build -f Dockerfile.reference -t merge-tools:reference .
```

A build downloads ~25 GB of wheels and takes 10–30 min depending on bandwidth.

---

## 4. Which variant to use

| Variant | pydantic | mergekit | Choose when |
|---|---|---|---|
| `merge-tools:latest` | 2.10.6 | fork `ikhyunAn/mergekit@e85a454` | You run `merge_pipeline.py` / mergekit merges, **including cross-family**. Also runs eval. |
| `merge-tools:reference` | 2.12.5 | stock upstream v0.1.3 | You use a **non-mergekit** merging repo and want the researcher's exact reference env. Note: its mergekit merge path is import-broken under pydantic 2.12 — same as the reference env — so it cannot run `merge_pipeline.py`. |

When in doubt, use `:latest`. See [../README.md](../README.md#provenance-of-the-lock) for
why the two differ.

---

## 5. Run

`run.sh` is the supported entrypoint. It stages code to local disk, then launches the
container with GPU access and all mount points wired up.

```bash
# Interactive shell inside the environment
./run.sh

# Sanity check
./run.sh python -c "import torch, vllm, mergekit; print('cuda:', torch.cuda.is_available())"

# End-to-end: merge two models, then evaluate the result
MODELS_DIR=/data/finetuned-models \
OUTPUT_DIR=/data/merge-output \
./run.sh python merge_tools/merge_pipeline.py --help
```

### Environment variables `run.sh` honors

| Var | Default | Meaning |
|---|---|---|
| `IMAGE` | `merge-tools:latest` | Which image/variant to run |
| `CODE_ROOT` | `/nethome/ian6` | Where your `merge_tools` + `unified-llm-eval` checkouts live |
| `CODE_STAGE` | `/tmp/merge-code` | Local-disk staging dir the daemon can read (see §6) |
| `MODELS_DIR` | `/tmp/merge-models` | Input fine-tuned models → mounted at `/models` |
| `OUTPUT_DIR` | `/tmp/merge-output` | Merged models + eval results → mounted at `/output` |
| `CACHE_DIR` | `/tmp/hf-cache` | HuggingFace hub cache → mounted at `/cache` |
| `CONFIG_DIR` | (unset) | Optional; mounted at `/config` if set |

### Container mount points

`/workspace/merge_tools`, `/workspace/unified-llm-eval` (code), `/models`, `/output`,
`/cache`. `PYTHONPATH` and `HF_HOME` are preset so imports and the model cache "just work".

---

## 6. Storage expectations (read this)

- **NFS / root-squashed homes cannot be bind-mounted.** The Docker daemon runs as root,
  and root is squashed on NFS homes, so mounting `/nethome/...` fails with
  `permission denied`. `run.sh` works around this by rsyncing your code to `CODE_STAGE`
  (local disk) before each run. Your edits still happen in `CODE_ROOT`; the sync is
  automatic.
- **Keep image layers, model weights, and the HF cache on local disk** (e.g. under `/tmp`
  or a scratch partition), never on the NFS home — home quotas are small and fill fast.
- Do **not** relocate Docker's storage root (`/var/lib/docker`) onto NFS.

---

## 7. End-to-end validation (what "working" looks like)

Both variants have been validated on an H200:

1. **Import sweep** — 382 packages import cleanly (the handful of nominal failures are
   metadata placeholders, not real breakage).
2. **Merge** (`:latest`) — a real SLERP merge of two Qwen2.5-0.5B models via the fork's
   mergekit produces a valid merged model.
3. **Serve** — vLLM boots on the merged model and generates coherent text.
4. **Evaluate** — `lm_eval` runs a benchmark (LAMBADA) against the merged model through the
   vLLM backend and returns a score.

To reproduce the quickest smoke test:

```bash
./run.sh python -c "
import torch, vllm, mergekit
from mergekit.merge_methods.slerp import SlerpMerge
print('torch cuda:', torch.cuda.is_available())
print('vllm:', vllm.__version__)
print('SLERP t optional (fork only):',
      not {d.name: d.required for d in SlerpMerge().parameters()}['t'])
"
```

On `:latest` the last line prints `True`; on `:reference` importing `mergekit.merge_methods`
raises (expected — that variant is not for mergekit merges).

---

## 8. Swapping in a different merging repo

Because code is mounted, adopting the researcher's non-mergekit merging repo needs no image
change:

1. Clone it next to the others under `CODE_ROOT`.
2. Add a mount line to `run.sh` (`-v "$CODE_STAGE/<repo>":/workspace/<repo>`) and include it
   in the rsync staging block.
3. Run as usual. Its dependencies are already covered as long as it ran in the reference
   `mergeenv` (plain torch/safetensors merging always does).

---

## 9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `permission denied` mounting `/nethome/...` | NFS root-squash; use `run.sh` (stages to local disk) or set `CODE_STAGE`/`MODELS_DIR` to local paths. |
| `PydanticSchemaGenerationError` importing mergekit | You're on `:reference` (pydantic 2.12). Use `:latest` for merges. |
| vLLM `An attempt has been made to start a new process before…` | Your script calls `LLM(...)` at import time. Wrap it in `if __name__ == "__main__":` (vLLM v1 uses spawn). |
| `docker: could not select device driver … gpu` | NVIDIA Container Toolkit not installed/configured. |
| Out of disk during build/run | Image + caches landed on a small partition; move to local scratch, keep off NFS home. |
