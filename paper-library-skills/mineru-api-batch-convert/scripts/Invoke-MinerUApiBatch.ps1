[CmdletBinding()]
param(
    [ValidateSet("Scan", "Convert", "Recycle", "Configure", "ClearCredential", "Environment")]
    [string]$Action = "Scan",

    [string[]]$RootPath,
    [string[]]$PdfPath,
    [switch]$Recurse,

    [ValidateSet("vlm", "pipeline")]
    [string]$Model = "vlm",
    [string]$Language = "en",
    [switch]$Ocr,
    [string]$PageRanges,
    [ValidateRange(1, 50)][int]$BatchSize = 20,
    [ValidateRange(0, 300)][int]$IntervalSeconds = 10,
    [ValidateRange(1, 86400)][int]$TimeoutSeconds = 1800,
    [ValidateRange(1, 3600)][int]$OneDriveTimeoutSeconds = 120,
    [ValidateRange(0, 60)][int]$StabilitySeconds = 2,

    [string]$ApiBase = "https://mineru.net/api/v4",
    [string]$StateRoot,
    [string]$ReportPath,
    [switch]$ConfirmRecycle
)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path $PSScriptRoot "MinerUApiBatch.Core.psm1"
Import-Module $modulePath -Force

if ($Action -eq "Configure") {
    Set-MinerUApiCredential
    [pscustomobject]@{ action = "Configure"; configured = $true; credentialPath = Get-MinerUApiCredentialPath }
    return
}

if ($Action -eq "ClearCredential") {
    Clear-MinerUApiCredential
    [pscustomobject]@{ action = "ClearCredential"; configured = $false }
    return
}

if ($Action -eq "Environment") {
    Get-MinerUApiEnvironment
    return
}

if (-not $ReportPath) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $ReportPath = Join-Path ([System.IO.Path]::GetTempPath()) "mineru-api-batch-report-$timestamp.json"
}

if ($Action -eq "Recycle") {
    $recycled = Invoke-MinerURecycle -ReportPath $ReportPath -ConfirmRecycle:$ConfirmRecycle
    [pscustomobject]@{
        action = "Recycle"
        reportPath = [System.IO.Path]::GetFullPath($ReportPath)
        recycledCount = @($recycled | Where-Object status -eq "Recycled").Count
        skippedCount = @($recycled | Where-Object status -eq "Skipped").Count
        results = @($recycled)
    }
    return
}

if (@($RootPath).Count -eq 0 -and @($PdfPath).Count -eq 0) {
    throw "Scan and Convert require -RootPath or -PdfPath."
}

$report = New-MinerUScanReport -RootPath $RootPath -PdfPath $PdfPath -Recurse:$Recurse
if ($Action -eq "Convert") {
    try {
        $token = Get-MinerUApiToken
        $conversions = Invoke-MinerUApiConversions `
            -ScanReport $report `
            -Token $token `
            -ApiBase $ApiBase `
            -Model $Model `
            -Language $Language `
            -Ocr:$Ocr `
            -PageRanges $PageRanges `
            -BatchSize $BatchSize `
            -IntervalSeconds $IntervalSeconds `
            -TimeoutSeconds $TimeoutSeconds `
            -OneDriveTimeoutSeconds $OneDriveTimeoutSeconds `
            -StabilitySeconds $StabilitySeconds `
            -StateRoot $StateRoot
    }
    catch {
        if ($_.Exception.Data["MinerUAuthFailure"]) {
            throw "MinerU rejected the saved API token. Run this script with -Action Configure to replace it."
        }
        throw
    }

    $report = New-MinerUScanReport -RootPath $RootPath -PdfPath $PdfPath -Recurse:$Recurse
    $report.action = "Convert"
    $report.conversions = @($conversions)
    $report.summary | Add-Member -NotePropertyName convertedCount -NotePropertyValue @($conversions | Where-Object status -eq "Converted").Count
    $report.summary | Add-Member -NotePropertyName resumedCount -NotePropertyValue @($conversions | Where-Object resumed -eq $true).Count
    $report.summary | Add-Member -NotePropertyName failedCount -NotePropertyValue @($conversions | Where-Object status -eq "Failed").Count
}

$writtenReport = Write-MinerUReport -Report $report -Path $ReportPath
[pscustomobject]@{
    action = $report.action
    reportPath = $writtenReport
    summary = $report.summary
    warnings = @($report.warnings)
    orphans = @($report.orphans)
    renameCandidates = @($report.renameCandidates)
    conversions = @($report.conversions)
}
