[CmdletBinding()]
param([switch]$Clear)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "MinerUApiBatch.Core.psm1") -Force

if ($Clear) {
    Clear-MinerUApiCredential
    Write-Host "Saved MinerU API credential removed."
    return
}

Set-MinerUApiCredential
Write-Host "MinerU API credential saved for the current Windows user."
