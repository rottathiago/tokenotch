Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param([Parameter(Mandatory)][scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Required command failed with exit code $LASTEXITCODE."
    }
}

function Get-WindowsTarget {
    param([Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture)
    if ($Architecture -eq 'x64') { return 'x86_64-pc-windows-msvc' }
    return 'aarch64-pc-windows-msvc'
}

function Assert-NativeWindows {
    param([Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string]$Architecture)
    if (-not $IsWindows) { throw 'Run this command in Windows, not PowerShell on macOS or Linux.' }
    $native = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($native -ne $Architecture) {
        throw "Native $Architecture execution is required; the operating system is $native."
    }
}
