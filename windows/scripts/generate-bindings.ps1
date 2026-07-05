#Requires -Version 5.1
<#
.SYNOPSIS
    Regenerates the C# UniFFI bindings for the shared Rust core (otp-ffi).

.DESCRIPTION
    Produces windows/OtpAuthenticator.Interop/Generated/otp.cs from the compiled
    otp-ffi cdylib using NordSecurity's uniffi-bindgen-cs.

    The generated file is COMMITTED to the repository (it is platform-independent C#;
    the native library it binds is discovered at runtime by the name "otp_ffi").
    You only need to run this script when the frozen FFI surface in
    core/crates/otp-ffi/src/lib.rs changes.

    Toolchain (must match docs/ARCHITECTURE.md §7):
      * uniffi          0.29.x   (pinned in core/Cargo.toml)
      * uniffi-bindgen-cs v0.10.0+v0.29.4  (NordSecurity, matches uniffi 0.29)

.NOTES
    Config (namespace + public access modifier) lives in
    windows/OtpAuthenticator.Interop/uniffi.toml.
#>
[CmdletBinding()]
param(
    # cargo build profile used to produce the cdylib to introspect.
    [ValidateSet('debug', 'release')]
    [string]$Profile = 'debug'
)

$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Resolve-Path (Join-Path $ScriptDir '..\..')
$CoreDir    = Join-Path $RepoRoot 'core'
$InteropDir = Join-Path $RepoRoot 'windows\OtpAuthenticator.Interop'
$OutDir     = Join-Path $InteropDir 'Generated'
$ConfigFile = Join-Path $InteropDir 'uniffi.toml'

$UniffiTag = 'v0.10.0+v0.29.4'

# Windows produces otp_ffi.dll; the same script works on macOS/Linux for local checks
# (libotp_ffi.dylib / libotp_ffi.so).
$LibCandidates = @(
    (Join-Path $CoreDir "target\$Profile\otp_ffi.dll"),
    (Join-Path $CoreDir "target/$Profile/libotp_ffi.dylib"),
    (Join-Path $CoreDir "target/$Profile/libotp_ffi.so")
)

Write-Host '==> Ensuring uniffi-bindgen-cs is installed' -ForegroundColor Cyan
if (-not (Get-Command uniffi-bindgen-cs -ErrorAction SilentlyContinue)) {
    Write-Host "    installing uniffi-bindgen-cs $UniffiTag from git" -ForegroundColor Yellow
    cargo install uniffi-bindgen-cs `
        --git https://github.com/NordSecurity/uniffi-bindgen-cs `
        --tag $UniffiTag
}

Write-Host '==> Building otp-ffi cdylib' -ForegroundColor Cyan
Push-Location $CoreDir
try {
    if ($Profile -eq 'release') {
        cargo build -p otp-ffi --release
    } else {
        cargo build -p otp-ffi
    }
} finally {
    Pop-Location
}

$Lib = $LibCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Lib) {
    throw "Could not find a built otp-ffi library. Looked for: $($LibCandidates -join ', ')"
}

Write-Host "==> Generating C# bindings from $Lib" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
uniffi-bindgen-cs --library $Lib --config $ConfigFile --out-dir $OutDir

Write-Host "==> Done. Wrote $(Join-Path $OutDir 'otp.cs')" -ForegroundColor Green
Write-Host '    Remember to commit the regenerated Generated/otp.cs.' -ForegroundColor Green
