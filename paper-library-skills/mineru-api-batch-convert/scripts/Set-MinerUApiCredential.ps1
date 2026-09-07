[CmdletBinding()]
param([switch]$Clear, [ValidateSet('Auto','Console','Never')][string]$CredentialPrompt = 'Auto')

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "MinerUApiBatch.Core.psm1") -Force
& (Get-Module MinerUApiBatch.Core) { param($mode) $script:CredentialPrompt = $mode } $CredentialPrompt

if ($Clear) {
    Clear-MinerUApiCredential
    Write-Host "Saved MinerU API credential removed."
    return
}

Set-MinerUApiCredential
Write-Host "MinerU API credential saved for the current Windows user."
