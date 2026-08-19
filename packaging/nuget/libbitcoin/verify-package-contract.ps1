# Verifies an UltrafastSecp256k1 libbitcoin NuGet package against the normative
# consumer contract (see HANDOFF.md). Run against the extracted build\native
# directory. Exit 0 = conforming; nonzero = non-conforming, with itemized FAILs.
#
# Usage:
#   .\verify-package-contract.ps1 -PackageDir <...>\<id>.<version>\build\native

param(
    [Parameter(Mandatory = $true)][string]$PackageDir
)

$script:failed = 0

function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Host "[PASS] $what" -ForegroundColor Green }
    else { Write-Host "[FAIL] $what" -ForegroundColor Red; $script:failed++ }
}

function Warn([string]$what) {
    Write-Host "[WARN] $what" -ForegroundColor Yellow
}

if (-not (Test-Path $PackageDir)) { throw "not found: $PackageDir" }
$bin = Join-Path $PackageDir "bin"
$targetsFile = Get-ChildItem $PackageDir -Filter "*.targets" | Select-Object -First 1
Check ($null -ne $targetsFile) "targets file present"
$targets = if ($targetsFile) { Get-Content $targetsFile.FullName -Raw } else { "" }

# ── Engagement contract ─────────────────────────────────────────────────────
# Selection lives in consumer properties; both packages remain referenced.
Check ($targets -match "'\`$\(Linkage-ultrafast\)'\s*!=\s*''") `
    "engages on Linkage-ultrafast (its own property)"
Check ($targets -notmatch "Linkage-secp256k1") `
    "does NOT key on Linkage-secp256k1 (belongs to the real secp256k1 package)"
Check ($targets -match "'\`$\(Linkage-ultrafast\)'\s*==\s*'dynamic'") `
    "dynamic (DLL-configuration) linkage groups present"

# ── Feature options (orthogonal, property-driven) ───────────────────────────
Check ($targets -match "'\`$\(Option-cuda\)'\s*==\s*'true'") `
    "Option-cuda feature group present"
Check ($targets -match "/INCLUDE:secp256k1_gpu_columns_provider_anchor") `
    "MSVC /INCLUDE hook-retention anchor in the cuda group"
Check ($targets -match "'\`$\(Option-secp256k1\)'\s*==\s*'false'") `
    "Option-secp256k1 substitute-mode group present"

# ── Headers ──────────────────────────────────────────────────────────────────
Check (Test-Path (Join-Path $PackageDir "include\ufsecp\libbitcoin.hpp")) `
    "canonical surface header (ufsecp/libbitcoin.hpp)"
Check (Test-Path (Join-Path $PackageDir "include\secp256k1\ecdsa.hpp")) `
    "engine C++ headers"
Check (Test-Path (Join-Path $PackageDir "include-shim\secp256k1.h")) `
    "shim headers isolated in include-shim (never collide with the real package)"

# ── Library matrix (version-agnostic) ────────────────────────────────────────
function Has([string]$pattern, [string]$what) {
    Check ((Get-ChildItem $bin -Filter $pattern | Measure-Object).Count -gt 0) $what
}
foreach ($crt in "mt-s", "mt-sgd") {
    foreach ($flavor in "static", "ltcg") {
        Has "fastsecp256k1-x64-*-$crt-*.$flavor.lib" "engine $crt $flavor"
        Has "secp256k1_shim-x64-*-$crt-*.$flavor.lib" "shim $crt $flavor"
        Has "secp256k1_gpu_host-x64-*-$crt-*.$flavor.lib" "gpu host $crt $flavor"
        Has "secp256k1_cuda-x64-*-$crt-*.$flavor.lib" "cuda kernels $crt $flavor"
    }
}
foreach ($crt in "md", "mdd") {
    Has "fastsecp256k1-x64-*-$crt-*.static.lib" "engine $crt (DLL configurations)"
    Has "secp256k1_shim-x64-*-$crt-*.static.lib" "shim $crt (DLL configurations)"
}
Has "cudart_static.lib" "CUDA static runtime (toolkit-free consumers)"

# ── Binary properties (requires dumpbin; warn-only without) ─────────────────
$dumpbin = Get-Command dumpbin -ErrorAction SilentlyContinue
if ($dumpbin) {
    $crtMap = @{ "mt-s" = "LIBCMT\b"; "mt-sgd" = "LIBCMTD"; "md" = "MSVCRT\b"; "mdd" = "MSVCRTD" }
    foreach ($crt in $crtMap.Keys) {
        $lib = Get-ChildItem $bin -Filter "fastsecp256k1-x64-*-$crt-*.static.lib" |
            Select-Object -First 1
        if ($lib) {
            $directives = dumpbin /directives $lib.FullName 2>$null | Out-String
            Check ($directives -match $crtMap[$crt]) "engine $crt CRT directive"
        }
    }
    # /GL objects are anonymous (LTCG) and dictate /LTCG to every consumer:
    # forbidden in non-ltcg flavors (WPO is a consumer opt-in, per the top-level
    # CMakeLists SECP256K1_MSVC_WPO policy comment).
    foreach ($crt in "mt-s", "md") {
        $lib = Get-ChildItem $bin -Filter "fastsecp256k1-x64-*-$crt-*.static.lib" |
            Select-Object -First 1
        if ($lib) {
            $symbols = dumpbin /symbols $lib.FullName 2>$null | Out-String
            Check ($symbols -notmatch "Anonymous object|LTCG object") `
                "engine $crt static flavor is not /GL (does not force consumer LTCG)"
        }
    }
    # The engine must be shim-free: in coexistence mode (Option-secp256k1=true)
    # the engine is linked next to the REAL libsecp256k1, so an engine lib that
    # defines secp256k1_* C symbols (Mode-B embedded shim TUs) lets the linker
    # resolve libsecp calls from the engine instead of the real package.
    # Conversely the staged shim libs must be the REAL Mode-A shim, not the
    # Mode-B stub (substitute mode would otherwise silently lack the C ABI).
    foreach ($lib in Get-ChildItem $bin -Filter "fastsecp256k1-*.lib") {
        $members = lib /list $lib.FullName 2>$null | Out-String
        Check ($members -notmatch "shim_") "engine lib shim-free: $($lib.Name)"
    }
    foreach ($lib in Get-ChildItem $bin -Filter "secp256k1_shim-*.lib") {
        $members = lib /list $lib.FullName 2>$null | Out-String
        Check ($members -match "shim_ecdsa") "shim lib carries real shim TUs: $($lib.Name)"
    }
    # Substitute mode drops the real secp256k1 package, so the shim's ellswift
    # surface (libbitcoin-network v2 transport) must be backed by the engine:
    # ellswift_decode must be DEFINED in the engine lib (SECTxx), not stripped
    # by the minimal profile (which would resurface the unresolved-external
    # class of failure at consumer link).
    foreach ($crt in "mt-s", "md") {
        $lib = Get-ChildItem $bin -Filter "fastsecp256k1-x64-*-$crt-*.static.lib" |
            Select-Object -First 1
        if ($lib) {
            $symbols = dumpbin /symbols $lib.FullName 2>$null | Out-String
            Check ($symbols -match "SECT[0-9A-F]+[^\r\n]*ellswift_decode") `
                "engine $crt backs shim ellswift (BIP-324 compiled in)"
        }
    }
}
else {
    Warn "dumpbin not on PATH: CRT-directive and /GL checks skipped (run from a VS shell)"
}

Write-Host ""
if ($script:failed -eq 0) {
    Write-Host "CONFORMING: all contract checks passed." -ForegroundColor Green
    exit 0
}
Write-Host "NON-CONFORMING: $script:failed check(s) failed." -ForegroundColor Red
exit 1
