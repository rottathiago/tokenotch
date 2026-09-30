param(
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture,
    [switch]$Development
)
. "$PSScriptRoot/common.ps1"
Assert-NativeWindows $Architecture
if (-not $Development) { throw 'Only unsigned development packaging exists. Public release signing is not implemented.' }
$target = Get-WindowsTarget $Architecture
$root = (Resolve-Path "$PSScriptRoot/../..").Path
Push-Location $root
try {
    & "$PSScriptRoot/build.ps1" -Architecture $Architecture
    Invoke-Checked { npm run tauri --prefix windows/desktop -- bundle --bundles nsis --features custom-protocol --target $target --ci --no-sign }
    Invoke-Checked { python windows/scripts/stage-artifacts.py --architecture $Architecture }
} finally { Pop-Location }
