param(
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture
)
. "$PSScriptRoot/common.ps1"
Assert-NativeWindows $Architecture
$target = Get-WindowsTarget $Architecture
$root = (Resolve-Path "$PSScriptRoot/../..").Path
Push-Location $root
try {
    if ($env:TAURI_CONFIG -or $env:TOKENOTCH_TEST_HOME) {
        throw 'Production builds require TAURI_CONFIG and TOKENOTCH_TEST_HOME to be unset. Remove smoke overrides explicitly.'
    }
    Invoke-Checked { python scripts/release-config.py }
    $product = Get-Content config/Release.json -Raw | ConvertFrom-Json
    $release = Get-Content windows/config/release.json -Raw | ConvertFrom-Json
    Invoke-Checked { python scripts/make-brand-assets.py --check }
    Invoke-Checked { python scripts/check-project.py }
    npm ls --prefix windows/desktop --depth=0 --silent
    if ($LASTEXITCODE -ne 0) {
        Invoke-Checked { npm ci --prefix windows/desktop --ignore-scripts --no-audit --no-fund }
    }
    Invoke-Checked { npm test --prefix windows/desktop }
    Invoke-Checked { npm run lint --prefix windows/desktop }
    Invoke-Checked { npm run build --prefix windows/desktop }
    npm ls --prefix integrations/VSCode --depth=0 --silent
    if ($LASTEXITCODE -ne 0) {
        Invoke-Checked { npm ci --prefix integrations/VSCode --ignore-scripts --no-audit --no-fund }
    }
    Invoke-Checked { npm run package --prefix integrations/VSCode }
    Invoke-Checked { node --test integrations/VSCode/test/windows.test.cjs }
    Push-Location windows
    try {
        Invoke-Checked { cargo fmt --all -- --check }
        Invoke-Checked { cargo build -p tokenotch-hook --release --target $target --locked }
        Invoke-Checked { python scripts/prepare.py --target $target --helper "target/$target/release/TokenotchHook.exe" }
        Invoke-Checked { cargo clippy --workspace --all-targets --features tokenotch-desktop/custom-protocol --target $target --locked -- -D warnings }
        Invoke-Checked { cargo test --workspace --features tokenotch-desktop/custom-protocol --target $target --locked -- --skip imports_release_runtime_for_live_delivery_within_hook_deadline }
        # Exercise concurrent import/live delivery without unrelated filesystem-heavy tests.
        Invoke-Checked { cargo test -p tokenotch-platform --test runtime --target $target --locked imports_release_runtime_for_live_delivery_within_hook_deadline -- --exact --nocapture }
        Invoke-Checked { npm run tauri --prefix desktop -- build --no-bundle --features custom-protocol --target $target --ci -- --locked }
        Invoke-Checked { python scripts/verify-pe.py --architecture $Architecture --static-runtime "target/$target/release/Tokenotch.exe" "target/$target/release/TokenotchHook.exe" }
        $diagnostic = & "target/$target/release/TokenotchHook.exe" --self-test
        if ($LASTEXITCODE -ne 0) { throw 'Native helper self-test failed.' }
        $status = $diagnostic | ConvertFrom-Json
        $expected = if ($Architecture -eq 'x64') { 'x86_64' } else { 'aarch64' }
        if ($status.runtime.platform -ne 'windows' -or $status.runtime.executableArchitecture -ne $expected -or
            $status.connectionsEnabled -ne $true -or $status.channel -ne $release.channel -or
            $status.version -ne $product.version) {
            throw 'Native helper version, channel or architecture did not match the build configuration.'
        }
        Write-Host "Native $Architecture $($release.channel) build $($product.version) and automated checks passed."
    } finally { Pop-Location }
} finally { Pop-Location }
