[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "MinerUApiBatch.Core.psm1") -Force
Get-MinerUApiEnvironment
