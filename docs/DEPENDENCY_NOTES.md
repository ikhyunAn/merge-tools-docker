# Dependency Notes — findings from validating the reference list

The container's dependency set started from a colleague's `mergeenv` freeze (the
"reference list"). Validating it against a working run surfaced several issues in the list
as captured. These are documented here so the reference list can eventually be corrected at
the source.

## The reference list is not installable by a strict resolver

Installing it verbatim requires `--no-deps`. It is a *complete* freeze of a working
environment, but its pins violate several declared bounds:

| Package | Declares | List pins | Status |
|---|---|---|---|
| mergekit | `pydantic~=2.10.6` | pydantic 2.12.5 | conflict |
| bfcl-eval | `anthropic>=0.75.0` | anthropic 0.71.0 | conflict |
| bfcl-eval | `numpy==1.26.4` | numpy 2.2.6 | conflict |
| outlines | `outlines_core==0.1.26` | outlines-core 0.2.11 | conflict |
| vllm 0.11.2 | `pydantic>=2.12.0` | (see below) | tolerated at runtime |

These are expected `pip check` output, not build failures — installing the frozen set
verbatim reproduces the proven-working state.

## `mergekit==0.1.3` is not a real PyPI release

PyPI only has mergekit 0.1.4 and 0.0.x. A freeze showing `mergekit==0.1.3` came from a
**source install of the upstream v0.1.3 git tag**, which `pip freeze` flattens to a version
pin. The container resolves this explicitly:
- `:latest` → the fork `ikhyunAn/mergekit@e85a454` (upstream v0.1.4 + cross-family fix).
- `:reference` → stock upstream **v0.1.3 git tag** (`arcee-ai/mergekit@2aa8542`).

## pydantic 2.12 breaks mergekit at import

Under pydantic ≥ 2.12, `import mergekit.merge_methods` raises
`PydanticSchemaGenerationError` (on `torch.Tensor` in the multislerp task model). This
affects **upstream v0.1.3 and the fork identically**. Consequence: the reference env, as
frozen (pydantic 2.12.5), **could not have run a mergekit merge** — it must have exercised
only the evaluation path. The `:latest` variant pins **pydantic 2.10.6 / pydantic_core
2.27.2** (the combination the original working venv actually merged with). vLLM 0.11.2
declares `pydantic>=2.12.0` but imports and runs correctly on 2.10.6 (verified).

## Cross-family merges require the fork

`merge_tools/merge_pipeline.py` routes every merge through mergekit's Python API. Its
cross-family selective mode (`--layer_component_selective_cross_family`) deliberately omits
SLERP's `t` parameter so unselected tensors pass through unchanged — stock mergekit requires
`t` and would error. Only the fork makes `t` optional (plus a base-model architecture
preference for mixed families). Same-family merges work on stock mergekit. See
`merge_tools/MERGEKIT_NEEDS_UPDATE.md` for the original analysis.

## tinyBenchmarks must be installed from a tarball, not `git+`

The tinyBenchmarks repo has a broken `tutorials/py-irt` submodule entry, so
`git submodule update --recursive` (run by pip/uv on any `git+` install) fails. Both locks
install it from the GitHub commit **tarball** instead — identical package code, no
submodule step.

## sglang is intentionally excluded

Its `flashinfer_cubin==0.6.1` pin conflicts with the
`flashinfer-python==0.5.2` / `flashinfer-cubin==0.5.2` pair that vLLM's engine boot requires
(the two flashinfer packages must stay in lockstep). sglang is not used by this pipeline.
