# merge-tools Docker environment

Dependency containers for `merge_tools` + `unified-llm-eval`. Images hold
**dependencies only**; pipeline code is mounted at runtime, so code edits need no rebuild
and repositories can be swapped freely.

## Two image variants

| Image | pydantic | mergekit | Use for |
|---|---|---|---|
| `merge-tools:latest` | 2.10.6 | fork `ikhyunAn/mergekit@e85a454` | **merge_pipeline.py / mergekit merges**, incl. cross-family; also runs eval |
| `merge-tools:reference` | 2.12.5 (reference-exact) | stock upstream v0.1.3 (present but merge path import-broken under pydantic 2.12 — same as the reference env) | non-mergekit merging repos + eval, maximum fidelity to the researcher's env |

Select via `IMAGE=merge-tools:reference ./run.sh ...` (default is `:latest`).

## Documentation

- **[docs/SETUP.md](docs/SETUP.md)** — full setup guide: prerequisites, pull/build, run,
  storage expectations, end-to-end validation, troubleshooting.
- **[docs/DEPENDENCY_NOTES.md](docs/DEPENDENCY_NOTES.md)** — findings from validating the
  reference dependency list (conflicts, the mergekit/pydantic story, why `--no-deps`).

Published images: `docker pull anjohn0077/merge-tools:latest` (or `:reference`).

## Contents

| File | Purpose |
|---|---|
| `requirements.lock` | Pinned set for `:latest` (355 pins + tinyBenchmarks, pydantic 2.10.6) |
| `requirements-reference.lock` | Pinned set for `:reference` (reference list verbatim + tinyBenchmarks) |
| `Dockerfile` / `Dockerfile.reference` | CUDA 12.8.1 devel base, Python 3.12, installs the respective lock via uv |
| `entrypoint.sh` | Mount sanity warnings, then exec the command |
| `run.sh` | `docker run` wrapper with GPU, shm, and all mounts |

## Provenance of the lock

Source of truth: the `mergeenv` reference list (captured 2026-07-11; Python 3.12.11,
torch 2.9.0+cu128, vllm 0.11.2), with two deliberate amendments:

1. **mergekit** → `ikhyunAn/mergekit@e85a454` (upstream **v0.1.4** + 28-line cross-family
   merge fix). The reference's `mergekit==0.1.3` does not exist on PyPI (it was a source
   install of the upstream v0.1.3 git tag flattened by `pip freeze`), and stock mergekit
   — including upstream main as of 2026-07-12 — still lacks the optional-`t` SLERP
   passthrough and base-architecture preference that cross-family merges require
   (see `merge_tools/MERGEKIT_NEEDS_UPDATE.md`).
   Installed alongside the lock (as a git URL, since it's not on PyPI).
2. **pydantic** → `2.10.6` (+ `pydantic_core 2.27.2`) instead of the reference's 2.12.5.
   Under pydantic 2.12, `mergekit.merge_methods` **fails at import**
   (`PydanticSchemaGenerationError` on `torch.Tensor` in multislerp) — and this affects
   upstream mergekit v0.1.3 identically, so the reference env's merge path was broken as
   captured; it evidently only exercised evaluation. pydantic 2.10.6 is the combination
   the old venv ran merges + vLLM with in practice. vllm 0.11.2 declares `pydantic>=2.12.0`
   but imports and runs fine on 2.10.6 (verified; same combo the venv used with vllm 0.15).
3. **tinyBenchmarks** added at the same commit the old venv used, but from the GitHub
   **tarball** rather than `git+` (the repo has a broken `tutorials/py-irt` submodule
   entry that makes `git submodule update --recursive` — run by pip/uv on git installs —
   fail; the tarball contains identical package code and skips submodules).

`sglang` is intentionally excluded (its flashinfer pin conflicts with the
`flashinfer-python==0.5.2` / `flashinfer-cubin==0.5.2` pair vLLM needs — those two
must stay in lockstep).

**Why `--no-deps`:** the reference env is metadata-inconsistent by strict-resolver
standards — it demonstrably runs `pydantic==2.12.5` against mergekit's `<2.11` bound and
`anthropic==0.71.0` against bfcl-eval's `>=0.75.0` bound. Since the lock is a *complete*
freeze of that working environment, installing it verbatim with `--no-deps` reproduces the
proven state exactly; letting uv/pip re-resolve would either fail or silently change pins.
Completeness is verified post-build by an import sweep (`pip check` will report the known
bound violations — they are expected).

## Build

```bash
cd /nethome/ian6/merge-tools-docker
docker build -t merge-tools:latest .
docker build -f Dockerfile.reference -t merge-tools:reference .
```

Image is ~30 GB; layers live under `/var/lib/docker` (local disk, plenty of room).
Do **not** relocate Docker storage to `/nethome` — the NFS home quota is nearly full.

## Run

```bash
./run.sh                    # interactive shell
./run.sh python -c "import vllm, mergekit, torch; print(torch.cuda.is_available())"

# Plug-and-play merge + eval:
MODELS_DIR=/path/to/finetuned-models \
OUTPUT_DIR=/path/to/results \
./run.sh python merge_tools/merge_pipeline.py ...
```

Container mount points: `/workspace/merge_tools`, `/workspace/unified-llm-eval`
(code), `/models` (inputs), `/output` (results), `/cache` (HF hub cache — defaults to
`/tmp/hf-cache` on local disk; never point it at NFS home).

**NFS caveat:** the Docker daemon (root) cannot read root-squashed NFS homes, so
bind-mounting anything under `/nethome/...` fails with "permission denied". `run.sh`
therefore rsyncs the code repos to `$CODE_STAGE` (default `/tmp/merge-code`) on local disk
before every run. Models/outputs/caches must likewise live on local disk.
