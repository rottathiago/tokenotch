param(
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture
)
. "$PSScriptRoot/common.ps1"
Assert-NativeWindows $Architecture
$target = Get-WindowsTarget $Architecture
$root = (Resolve-Path "$PSScriptRoot/../..").Path
Push-Location $root
try {
    Invoke-Checked { python scripts/release-config.py }
    Invoke-Checked { python scripts/make-brand-assets.py --check }
    Invoke-Checked { python scripts/check-project.py }
    Invoke-Checked { npm ci --prefix windows/desktop --ignore-scripts --no-audit --no-fund }
    Invoke-Checked { npm test --prefix windows/desktop }
    Invoke-Checked { npm run lint --prefix windows/desktop }
    Invoke-Checked { npm run build --prefix windows/desktop }
    Push-Location windows
    try {
        Invoke-Checked { cargo fmt --all -- --check }
        Invoke-Checked { cargo build -p tokenotch-hook --release --target $target --locked }
        Invoke-Checked { python scripts/prepare.py --target $target --helper "target/$target/release/TokenotchHook.exe" }
        Invoke-Checked { cargo clippy --workspace --all-targets --features tokenotch-desktop/custom-protocol --target $target --locked -- -D warnings }
        Invoke-Checked { cargo test --workspace --features tokenotch-desktop/custom-protocol --target $target --locked }
        Invoke-Checked { npm run tauri --prefix desktop -- build --no-bundle --features custom-protocol --target $target --ci -- --locked }
        Invoke-Checked { python scripts/verify-pe.py --architecture $Architecture --static-runtime "target/$target/release/Tokenotch.exe" "target/$target/release/TokenotchHook.exe" }
        $diagnostic = & "target/$target/release/TokenotchHook.exe" --self-test
        if ($LASTEXITCODE -ne 0) { throw 'Native helper self-test failed.' }
        $status = $diagnostic | ConvertFrom-Json
        $expected = if ($Architecture -eq 'x64') { 'x86_64' } else { 'aarch64' }
        if ($status.runtime.platform -ne 'windows' -or $status.runtime.executableArchitecture -ne $expected -or
            $status.connectionsEnabled -ne $false -or $status.channel -ne 'development') {
            throw 'Native helper identity or development behavior did not match the target.'
        }
        Write-Host "Native $Architecture development build and automated checks passed."
    } finally { Pop-Location }
} finally { Pop-Location }
