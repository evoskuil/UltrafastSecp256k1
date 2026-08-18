# Build the UltrafastSecp256k1-vc145 NuGet package (libbitcoin canonical surface).
#
# Builds the canonical bridge-free libbitcoin profile (static engine + optional CUDA
# backend) across the CRT/linkage matrix, stages the package layout, and optionally
# installs it into the local libbitcoin package cache (restore is disabled there;
# packages are consumed pre-extracted).
#
# Requires: VS 18 (v145), CUDA Toolkit (nvcc + cudart_static.lib), Ninja/CMake (VS-bundled).
#
# Usage:
#   .\build-nuget-vc145.ps1                         # build all configs, stage, pack
#   .\build-nuget-vc145.ps1 -Install                # ...and install to the local cache
#   .\build-nuget-vc145.ps1 -Configs static-release # single config (iteration)

param(
    [string]$Version = "4.5.0.0",
    [ValidateSet("static-release", "static-debug", "ltcg-release", "ltcg-debug",
        "dynamic-release", "dynamic-debug")]
    [string[]]$Configs = @("static-release", "static-debug", "ltcg-release", "ltcg-debug",
        "dynamic-release", "dynamic-debug"),
    [string]$VsRoot = "C:\Program Files\Microsoft Visual Studio\18\Community",
    [string]$CudaArchitectures = "89-real;120-real;120-virtual",
    [switch]$SkipBuild,
    [switch]$Install,
    [string]$InstallRoot = ""
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$packageId = "UltrafastSecp256k1-vc145"
$vunder = $Version -replace '\.', '_'
$buildRoot = Join-Path $repo "build-nuget"
$stage = Join-Path $buildRoot "package\$packageId.$Version"
if ($InstallRoot -eq "") { $InstallRoot = (Resolve-Path (Join-Path $repo "..")).Path + "\.nuget\packages" }

# key -> crt tag, CMake runtime library, build type, WPO, artifact flavor, cuda
$matrix = @{
    "static-release"  = @{ crt = "mt-s";   runtime = "MultiThreaded";         type = "Release"; wpo = $false; flavor = "static"; cuda = $true }
    "static-debug"    = @{ crt = "mt-sgd"; runtime = "MultiThreadedDebug";    type = "Debug";   wpo = $false; flavor = "static"; cuda = $true }
    "ltcg-release"    = @{ crt = "mt-s";   runtime = "MultiThreaded";         type = "Release"; wpo = $true;  flavor = "ltcg";   cuda = $true }
    "ltcg-debug"      = @{ crt = "mt-sgd"; runtime = "MultiThreadedDebug";    type = "Debug";   wpo = $true;  flavor = "ltcg";   cuda = $true }
    "dynamic-release" = @{ crt = "md";     runtime = "MultiThreadedDLL";      type = "Release"; wpo = $false; flavor = "static"; cuda = $false }
    "dynamic-debug"   = @{ crt = "mdd";    runtime = "MultiThreadedDebugDLL"; type = "Debug";   wpo = $false; flavor = "static"; cuda = $false }
}

# VS developer environment (cl/cmake/ninja) and CUDA.
& "$VsRoot\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -SkipAutomaticLocation | Out-Null
if (-not $env:CUDA_PATH) { $env:CUDA_PATH = [Environment]::GetEnvironmentVariable("CUDA_PATH", "Machine") }
if (-not (Test-Path "$env:CUDA_PATH\lib\x64\cudart_static.lib")) {
    throw "CUDA Toolkit not found (CUDA_PATH=$env:CUDA_PATH)."
}

function Stage-Lib([string]$build, [string]$libName, [string]$stagedName) {
    $lib = Get-ChildItem -Path $build -Recurse -Filter $libName | Select-Object -First 1
    if (-not $lib) { throw "$libName not found under $build" }
    Copy-Item $lib.FullName (Join-Path "$stage\build\native\bin" $stagedName) -Force
}

New-Item -ItemType Directory -Force "$stage\build\native\bin" | Out-Null

foreach ($key in $Configs) {
    $c = $matrix[$key]
    $build = Join-Path $buildRoot $key
    Write-Host "==== $key (crt=$($c.crt) flavor=$($c.flavor) cuda=$($c.cuda)) ====" -ForegroundColor Cyan

    if (-not $SkipBuild) {
        $cmakeArgs = @(
            "-S", $repo, "-B", $build, "-G", "Ninja",
            "-DCMAKE_BUILD_TYPE=$($c.type)",
            "-DCMAKE_MSVC_RUNTIME_LIBRARY=$($c.runtime)",
            "-DSECP256K1_BUILD_LIBBITCOIN=ON",
            # Bridge opt-in solely for the libsecp256k1 shim: consumers that deselect
            # secp256k1 (Option-secp256k1=false) use UltrafastSecp256k1 as a full
            # substitute (same headers, same C API). Bridge/CABI byproducts are not staged.
            "-DSECP256K1_BUILD_LIBBITCOIN_BRIDGE=ON"
        )
        if ($c.wpo) { $cmakeArgs += "-DSECP256K1_MSVC_WPO=ON" }
        if ($c.cuda) {
            $cmakeArgs += @(
                "-DSECP256K1_BUILD_LIBBITCOIN_GPU=ON",
                "-DSECP256K1_BUILD_CUDA=ON",
                "-DCMAKE_CUDA_RESOLVE_DEVICE_SYMBOLS=ON",
                "-DCMAKE_CUDA_ARCHITECTURES=$CudaArchitectures"
            )
            # Minimal node GPU surface (upstream-designed combination): script-signature
            # verification only. The libbitcoin profile strips these modules' kernels;
            # the GPU dispatch flags must match or the host backend references missing
            # kernels at link.
            foreach ($mod in "ZK", "BIP324", "FROST", "BIP352", "ECDH", "MSM", "HASH160", "ECRECOVER") {
                $cmakeArgs += "-DSECP256K1_GPU_BUILD_${mod}=OFF"
            }
            # Upstream forces -O3 on CUDA compilation in all configs; nvcc forwards /O2
            # to the MSVC host compiler, colliding with the default Debug /RTC1 (D8016).
            # Drop RTC from the CUDA host Debug flags (host .cu wrappers only; CXX TUs
            # keep full debug checks).
            if ($c.type -eq "Debug") {
                $cmakeArgs += "-DCMAKE_CUDA_FLAGS_DEBUG=-g -Xcompiler=/Zi -Xcompiler=/Od"
            }
        }
        # Integration tests ride the primary config only (used for package verification).
        if ($key -eq "static-release") { $cmakeArgs += "-DSECP256K1_BUILD_LIBBITCOIN_TESTS=ON" }

        cmake @cmakeArgs
        if ($LASTEXITCODE -ne 0) { throw "configure failed: $key" }

        $targets = @("fastsecp256k1", "secp256k1_shim")
        if ($c.cuda) { $targets += @("secp256k1_gpu_host", "secp256k1_cuda_lib") }
        if ($key -eq "static-release") { $targets += @("test_lbtc_direct_verify") }
        cmake --build $build --target @targets
        if ($LASTEXITCODE -ne 0) { throw "build failed: $key" }
    }

    Stage-Lib $build "fastsecp256k1.lib" "fastsecp256k1-x64-v145-$($c.crt)-$vunder.$($c.flavor).lib"
    Stage-Lib $build "secp256k1_shim.lib" "secp256k1_shim-x64-v145-$($c.crt)-$vunder.$($c.flavor).lib"
    if ($c.cuda) {
        Stage-Lib $build "secp256k1_gpu_host.lib" "secp256k1_gpu_host-x64-v145-$($c.crt)-$vunder.$($c.flavor).lib"
        Stage-Lib $build "secp256k1_cuda_lib.lib" "secp256k1_cuda-x64-v145-$($c.crt)-$vunder.$($c.flavor).lib"
    }
}

# Headers: engine public tree + engine C++ headers (the include dir the engine target
# exports) + canonical libbitcoin surface, merged.
New-Item -ItemType Directory -Force "$stage\build\native\include" | Out-Null
Copy-Item "$repo\include\*" "$stage\build\native\include\" -Recurse -Force
Copy-Item "$repo\src\cpu\include\*" "$stage\build\native\include\" -Recurse -Force
Copy-Item "$repo\compat\libbitcoin_direct\include\*" "$stage\build\native\include\" -Recurse -Force

# libsecp256k1-compatible shim headers, in a SEPARATE dir: only on the include path
# when the consumer deselects secp256k1 (never collides with the real package).
New-Item -ItemType Directory -Force "$stage\build\native\include-shim" | Out-Null
Copy-Item "$repo\compat\libsecp256k1_shim\include\*" "$stage\build\native\include-shim\" -Recurse -Force

# CUDA static runtime: shipped so consumers need no CUDA Toolkit to build.
# LICENSE NOTE: verify the CUDA EULA redistributable attachment covers cudart_static.lib
# before publishing this package beyond local/team use.
Copy-Item "$env:CUDA_PATH\lib\x64\cudart_static.lib" "$stage\build\native\bin\" -Force

# MSBuild integration + schema + nuspec + docs. The checked-in targets/nuspec are
# the 4.5.0.0-reference specification; version strings are substituted at stage
# time so -Version is the single source of the package version (HANDOFF: ship
# with version-string substitution as the only edit).
(Get-Content "$PSScriptRoot\UltrafastSecp256k1-vc145.targets" -Raw).
    Replace("4_5_0_0", $vunder).Replace("4.5.0.0", $Version) |
    Set-Content "$stage\build\native\UltrafastSecp256k1-vc145.targets" -Encoding utf8 -NoNewline
Copy-Item "$PSScriptRoot\package.xml" "$stage\build\native\" -Force
(Get-Content "$PSScriptRoot\$packageId.nuspec" -Raw).Replace("4.5.0.0", $Version) |
    Set-Content "$stage\$packageId.nuspec" -Encoding utf8 -NoNewline
New-Item -ItemType Directory -Force "$stage\docs" | Out-Null
Copy-Item "$repo\docs\LIBBITCOIN_INTEGRATION.md" "$stage\docs\" -Force

# Pack (cosmetic archive; the libbitcoin cache consumes the extracted layout).
$nupkg = Join-Path $buildRoot "package\$packageId.$Version.nupkg"
if (Test-Path $nupkg) { Remove-Item $nupkg -Force }
Compress-Archive -Path "$stage\*" -DestinationPath "$nupkg.zip" -Force
Move-Item "$nupkg.zip" $nupkg -Force
Copy-Item $nupkg "$stage\" -Force

if ($Install) {
    $dest = Join-Path $InstallRoot "$packageId.$Version"
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Copy-Item $stage $dest -Recurse -Force
    Write-Host "installed: $dest" -ForegroundColor Green
}

Write-Host "package staged: $stage" -ForegroundColor Green
