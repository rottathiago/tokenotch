param(
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture,
    [switch]$AllowUnsigned
)
. "$PSScriptRoot/common.ps1"
if (-not $AllowUnsigned) { throw 'Signing is not configured. Pass -AllowUnsigned to explicitly create an unsigned local installer.' }
Assert-NativeWindows $Architecture
$target = Get-WindowsTarget $Architecture
$root = (Resolve-Path "$PSScriptRoot/../..").Path
Push-Location $root
try {
    & "$PSScriptRoot/build.ps1" -Architecture $Architecture
    Invoke-Checked { npm run tauri --prefix windows/desktop -- bundle --bundles nsis --features custom-protocol --target $target --ci --no-sign }
    Invoke-Checked { python windows/scripts/stage-artifacts.py --architecture $Architecture }
} finally { Pop-Location }
