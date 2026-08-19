# UltrafastSecp256k1-vc145 NuGet — canonical libbitcoin packaging (v4.5.0.0)

Handoff for the package maintainer. This directory replaces the ad-hoc process that
produced `UltrafastSecp256k1-vc145` 4.4.0.4 and packages the CANONICAL bridge-free
libbitcoin surface instead of the legacy bridge. Everything here was built and
verified locally (2026-07-20, VS 18 / v145, CUDA 13.3, RTX PRO 6000 Blackwell).

## NORMATIVE consumer contract (read this first, especially if you are an agent)

The `.targets` and `package.xml` in this directory are the SPECIFICATION, not an
example. Ship them with version-string substitution as the only edit. A package is
conforming if and only if `verify-package-contract.ps1` passes against its extracted
`build\native` directory — run it before publishing; iterate until it exits 0.

MUST:
- Engage on `Linkage-ultrafast` (`'' | dynamic | static | ltcg`). This is the
  package's own selector property.
- Provide the feature groups as orthogonal properties: `Option-cuda` (GPU host +
  kernels + cudart + `/INCLUDE:secp256k1_gpu_columns_provider_anchor`; static-CRT
  linkages), `Option-secp256k1 == 'false'` (substitute mode: shim headers from
  `include-shim\` + shim lib). Future features follow the same pattern: a new
  `Option-*` property, never a new package id.
- Ship the full flavor matrix including `md`/`mdd` (DLL configurations).
- Keep non-ltcg flavors free of `/GL` (WPO is a CONSUMER opt-in: a `/GL` static lib
  forces every consumer into `/LTCG` — see `SECP256K1_MSVC_WPO` in the top-level
  CMakeLists).

MUST NOT (each of these has already been produced by an agent and rejected):
- Key any engagement condition on `Linkage-secp256k1`. That property belongs to the
  real secp256k1 package; overloading it makes the two packages mutually exclusive,
  which moves UF selection out of machine-local properties and into generated
  package references (the `ultrafast_secp256k1_* 4.5.0.2` anti-pattern).
- Require a package-identity swap for any selection. Both packages remain referenced
  permanently in the generated projects; ALL selection happens via properties in the
  consumer's machine-local `Directory.Build.props`.
- Bundle features into package ids (no `*-cuda`, `*-arm64` id variants). Features
  are `Option-*` properties in one package.

Rationale: libbitcoin's build holds selection axes independent — engine
(`Option-ultrafast`), ABI provider (`Option-secp256k1`), acceleration
(`Option-cuda`) — so any combination is a per-machine toggle with zero repo diffs.
Package identity is the worst possible selector because it entangles all axes into
generated, committed files.

## Why 4.4.0.4 had to be replaced

- It shipped the LEGACY bridge (`ufsecp_lbtc_ctrl_*`) as a CPU-only build: the bridge
  lib contained zero GPU symbols, and the `secp256k1_cuda` lib it carried was the raw
  kernel archive that nothing referenced — the linker discarded it. GPU could never
  bind (`UFSECP_ERR_GPU_UNAVAILABLE`), silently.
- Upstream has since moved libbitcoin integration to a canonical, bridge-free
  header-only surface: `ufsecp::lbtc::*` via `<ufsecp/libbitcoin.hpp>`, GPU as an
  internal math engine with transparent CPU fallback (see
  `docs/LIBBITCOIN_INTEGRATION.md`). libbitcoin-system migrates its `batch.cpp`
  accordingly (coordinated with Eric).

## The pipeline

`build-nuget-vc145.ps1` — six configs (static /MT, static-debug /MTd, ltcg /MT+/GL,
ltcg-debug, dynamic /MD, dynamic-debug /MDd; CUDA in the four static-CRT configs),
stages `build/native/{bin,include,UltrafastSecp256k1-vc145.targets,package.xml}`,
packs a cosmetic .nupkg, and with `-Install` copies the extracted layout into the
local libbitcoin package cache (`<evoskuil>\.nuget\packages`; restore is disabled
there — packages are consumed pre-extracted).

Key CMake ingredients (see the script for the full argument set):
- `-DSECP256K1_BUILD_LIBBITCOIN=ON` (+`_GPU=ON`, `-DSECP256K1_BUILD_CUDA=ON`)
- `-DCMAKE_CUDA_RESOLVE_DEVICE_SYMBOLS=ON` — REQUIRED: embeds the device-link object
  in each static archive so plain-link.exe consumers work (they cannot device-link).
- `-DCMAKE_CUDA_ARCHITECTURES=89-real;120-real;120-virtual` (Ada + Blackwell + PTX).
- All eight `SECP256K1_GPU_BUILD_*` modules OFF — the upstream-designed "minimal node
  GPU" surface. REQUIRED: the libbitcoin profile strips those kernels, and leaving
  the dispatch flags ON makes the GPU host reference missing kernels at link.
- `-DSECP256K1_LIBBITCOIN_BIP324=ON` — keeps CPU BIP-324 (ellswift/ChaCha20-
  Poly1305/HKDF) in the engine, which the minimal profile otherwise strips.
  REQUIRED: substitute mode (the deployed UF configuration — the real secp256k1
  package is dropped) serves libbitcoin-network's v2-transport
  `secp256k1_ellswift_*` calls through the shim, whose engine backing must exist.
  Independent of the GPU module flags above (GPU BIP-324 kernels stay OFF).
- Debug configs override `CMAKE_CUDA_FLAGS_DEBUG` to drop `/RTC1` (upstream forces
  `-O3` on CUDA in all configs; nvcc forwards `/O2` to the MSVC host → D8016).
- `-DCMAKE_MSVC_RUNTIME_LIBRARY=...` per config (upstream defaults /MD).

## Consumer contract (matches the libbitcoin props conventions)

- `Linkage-ultrafast` ∈ `'' | dynamic | static | ltcg` — engagement + engine flavor.
  `dynamic` = /MD-CRT STATIC archive for DLL configurations (the engine is
  static-only by design). No `cuda` linkage value (removed).
- `Option-cuda == 'true'` (static/ltcg only): links `secp256k1_gpu_host` +
  `secp256k1_cuda` + `cudart_static.lib` and forces
  `/INCLUDE:secp256k1_gpu_columns_provider_anchor` (retains the self-installing
  GpuColumnsVerifyHook that a normal static link would dead-strip). GPU is
  API-invisible: transparent acceleration of `*_verify_columns`, silent CPU
  fallback. First CUDA touch costs ~250 ms one-time context init per process.
- Defines: the targets emit `WITH_ULTRAFAST` (libbitcoin's have.hpp maps it to
  `HAVE_ULTRAFAST`).
- **Substitute mode** (`Option-secp256k1 == 'false'` with ultrafast engaged): the
  package provides the libsecp256k1 interface itself — shim headers from
  `include-shim\` (kept separate so they can never collide with the real secp256k1
  package) plus the `secp256k1_shim` lib (v4.5 shim over the engine; built via
  `SECP256K1_BUILD_LIBBITCOIN_BRIDGE=ON`, only the shim is staged). This preserves
  the original libbitcoin contract: enabling ultrafast and deselecting secp256k1
  makes UltrafastSecp256k1 a full drop-in substitute. With secp256k1 left enabled,
  both packages coexist (the canonical build exports no `secp256k1_*` symbols).
  The shim headers require C++ (they overlay the engine's C++ headers).

## Local source fixes carried in this fork (upstream these to shrec)

1. `src/cuda/include/secp256k1.cuh` — parameter renamed `small` → `factor`:
   `windows.h` (via `secure_erase.hpp`) pulls `rpcndr.h`, which `#define small char`.
   Broke every Windows GPU-host compile; nobody had ever built Windows CUDA.
2. `compat/libbitcoin_direct/CMakeLists.txt` — hook retention flag is GNU-ld-only
   (`--undefined=`); MSVC needs `LINKER:/INCLUDE:...`. Without it MSVC silently
   dead-strips the hook (exactly the 4.4.0.4 failure mode, reproduced from source).
3. Suggested upstream (not source-fixable here): a compile-only `windows-cuda` CI job
   (hosted runners need no GPU to compile) — every defect above was invisible to
   upstream's Linux-only GPU CI.

## Licensing gate before any publication

`cudart_static.lib` is copied from the local CUDA Toolkit into `bin\` so consumers
need no toolkit. Fine for local/team use; before publishing beyond that, verify the
CUDA EULA redistributable attachment covers the STATIC runtime lib for the toolkit
version used (the DLL runtime is unambiguously listed; the static lib must be
confirmed, not assumed). Fallback: reference `$(CUDA_PATH)\lib\x64` in the cuda
group instead and require the toolkit on build machines.

## Verification performed (all green)

- UF CTests from the static-release tree: `lbtc_direct_verify`,
  `lbtc_direct_operations`, `lbtc_direct_gpu_columns_hook` (hook self-install).
- `bench_lbtc_direct_batch` (1M sigs, pool 50k): ECDSA columns 23.6 M sig/s,
  Schnorr columns 29.3 M sig/s (GPU, thread-count invariant); CPU row path
  2.0–2.6 M sig/s at 128 threads, ~33 µs/sig single-thread.
- Degradation soak (canonical single-verify, 300k unique inputs, 15 passes): flat
  rate (~40 µs/verify), flat working set, flat handle count. (The leak-like 2×
  slowdown Eric measured over a sync was on the 4.4-era engine/shim and does not
  reproduce on the v4.5 canonical path.)
- Consumer smoke built ONLY from the installed package (plain cl/link, no repo, no
  toolkit): single verify OK; columns 500k → 18 M sig/s steady-state after the
  one-time context init. CRT directives verified per flavor (LIBCMT/LIBCMTD/MSVCRT);
  anchor symbol present; device-link members present in the archives.
- v4.5 shim soak (substitute mode surface, 300k unique-input sign/verify via the
  libsecp256k1 API): flat ~30 µs/verify, flat memory/handles — the leak-like
  degradation observed on the 4.4-era shim does not reproduce.
- libbitcoin-system built in substitute mode (secp256k1 fully disengaged, UF shim +
  canonical batch + CUDA) — crypto/signature/threshold test suites all pass.

## Still pending on the libbitcoin side (Eric)

version4.xml v145 package version → 4.5.0.0 + regeneration; removal of the interim
props mapping (`Option-cuda` → `Linkage-ultrafast=cuda`) and the interim
`$(CUDA_PATH)` lib path in the machine-local Directory.Build.props; `batch.cpp`
migration to `ufsecp::lbtc::*_verify_columns`; full-stack build verification.
