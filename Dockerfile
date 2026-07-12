# Dependency image for the model-merging pipeline (merge_tools_archive + unified-llm-eval).
# Code is NOT baked in — mount it at runtime (see run.sh).
#
# Pins come from requirements.lock: the mergeenv reference list (Python 3.12,
# torch 2.9.0+cu128, vllm 0.11.2) with two amendments:
#   * mergekit installed from ikhyunAn/mergekit@e85a454 (upstream v0.1.4 + cross-family
#     merge fixes; the reference's mergekit==0.1.3 does not exist on PyPI and stock
#     mergekit breaks cross-family selective SLERP merges)
#   * tinyBenchmarks added (used by the eval path; absent from the reference list)
# sglang is intentionally absent: its flashinfer_cubin pin conflicts with the
# flashinfer-python==0.5.2 / flashinfer-cubin==0.5.2 pair vLLM needs.

FROM nvidia/cuda:12.8.1-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.12 python3.12-venv python3.12-dev \
        git curl ca-certificates build-essential ffmpeg \
    && rm -rf /var/lib/apt/lists/*

RUN python3.12 -m venv /opt/venv
ENV VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH

# --no-deps: the lock is a complete freeze of a working env, so no resolution is
# needed — and the reference env is metadata-inconsistent by strict standards
# (e.g. it runs pydantic 2.12.5 against mergekit's <2.11 bound and anthropic 0.71.0
# against bfcl-eval's >=0.75.0 bound). Installing the exact frozen set reproduces
# the proven-working state; a strict resolver would refuse it.
COPY requirements.lock /tmp/requirements.lock
RUN pip install --no-cache-dir uv==0.9.11 \
    && uv pip install --no-cache --no-deps -r /tmp/requirements.lock \
        "mergekit @ git+https://github.com/ikhyunAn/mergekit.git@e85a454f39ec3669d9ed37d9455dfdb61bbb3cf4"

# Runtime layout (all mounted, nothing stored in the image):
#   /workspace/merge_tools       - merge pipeline code (repo canonical name)
#   /workspace/unified-llm-eval  - evaluation code
#   /models                      - input fine-tuned models
#   /output                      - merged models + eval results
#   /cache                       - HF hub cache (keep off NFS home!)
ENV HF_HOME=/cache/huggingface \
    PYTHONPATH=/workspace/merge_tools:/workspace/unified-llm-eval

WORKDIR /workspace

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
