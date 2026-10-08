param(
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture,
    [Parameter(Mandatory)][string]$Installer,
    [switch]$DisposableEnvironment
)
. "$PSScriptRoot/common.ps1"
Assert-NativeWindows $Architecture
if (-not $DisposableEnvironment) {
    throw 'Installer smoke checks require an explicitly designated disposable Windows environment.'
}
$installerPath = (Resolve-Path $Installer).Path
$directory = Join-Path ([IO.Path]::GetTempPath()) ("Tokenotch-install-check-" + [guid]::NewGuid().ToString('N'))
$uninstaller = Join-Path $directory 'uninstall.exe'
$installed = $false
try {
    $install = Start-Process $installerPath -ArgumentList @('/S', "/D=$directory") -PassThru -Wait
    if ($install.ExitCode -ne 0) { throw "Installer failed with exit code $($install.ExitCode)." }
    $installed = $true
    Invoke-Checked { python "$PSScriptRoot/verify-pe.py" --architecture $Architecture --static-runtime "$directory/Tokenotch.exe" "$directory/TokenotchHook.exe" }
    $statusText = & "$directory/TokenotchHook.exe" --self-test
    if ($LASTEXITCODE -ne 0) { throw 'Installed helper self-test failed.' }
    $status = $statusText | ConvertFrom-Json
    $product = Get-Content "$PSScriptRoot/../../config/Release.json" -Raw | ConvertFrom-Json
    $release = Get-Content "$PSScriptRoot/../config/release.json" -Raw | ConvertFrom-Json
    $expected = if ($Architecture -eq 'x64') { 'x86_64' } else { 'aarch64' }
    if ($status.runtime.platform -ne 'windows' -or $status.runtime.executableArchitecture -ne $expected -or
        $status.connectionsEnabled -ne $true -or $status.version -ne $product.version -or $status.channel -ne $release.channel) {
        throw 'Installed helper did not report the expected version, channel and architecture.'
    }
    if (-not (Test-Path "$directory/LICENSE" -PathType Leaf)) { throw 'Installed license notice is missing.' }
    Write-Host "Installed $Architecture payload and helper passed. Desktop/live-client acceptance is still separate."
} finally {
    if ($installed -and (Test-Path $uninstaller -PathType Leaf)) {
        $remove = Start-Process $uninstaller -ArgumentList @('/S', "_?=$directory") -PassThru -Wait
        if ($remove.ExitCode -ne 0) { throw "Uninstaller failed. Inspect the test installation at $directory." }
        foreach ($name in @('Tokenotch.exe', 'TokenotchHook.exe')) {
            if (Test-Path (Join-Path $directory $name)) { throw "Uninstall left $name in the test installation." }
        }
    } elseif ($installed) {
        throw "The test installation has no uninstaller. Inspect $directory."
    }
}
