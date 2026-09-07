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
    [switch]$AllowReplaceStale,
    [ValidateRange(1, 50)][int]$BatchSize = 20,
    [ValidateRange(1, 8)][int]$TransferConcurrency = 3,
    [ValidateRange(0, 300)][int]$IntervalSeconds = 10,
    [ValidateRange(1, 86400)][int]$TimeoutSeconds = 1800,
    [ValidateRange(1, 3600)][int]$OneDriveTimeoutSeconds = 120,
    [ValidateRange(0, 60)][int]$StabilitySeconds = 2,

    [string]$ApiBase = "https://mineru.net/api/v4",
    [string]$StateRoot,
    [string]$ReportPath,
    [ValidateSet('Auto','Console','Never')][string]$CredentialPrompt = 'Auto',
    [switch]$ConfirmRecycle
)

$ErrorActionPreference = "Stop"
$modulePath = Join-Path $PSScriptRoot "MinerUApiBatch.Core.psm1"
Import-Module $modulePath -Force
& (Get-Module MinerUApiBatch.Core) { param($mode) $script:CredentialPrompt = $mode } $CredentialPrompt

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
    $ReportPath = Join-Path ([System.IO.Path]::GetTempPath()) ('mineru-api-batch-report-' + [guid]::NewGuid().ToString('N') + '.json')
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

$totalClock = [Diagnostics.Stopwatch]::StartNew()
$scanClock = [Diagnostics.Stopwatch]::StartNew()
$report = New-MinerUScanReport -RootPath $RootPath -PdfPath $PdfPath -Recurse:$Recurse
$scanClock.Stop()
$fatalError = $null
if ($Action -eq "Convert") {
    try {
        $conversions = Invoke-MinerUApiConversions `
            -ScanReport $report `
            -ApiBase $ApiBase `
            -Model $Model `
            -Language $Language `
            -Ocr:$Ocr `
            -PageRanges $PageRanges `
            -AllowReplaceStale:$AllowReplaceStale `
            -BatchSize $BatchSize `
            -TransferConcurrency $TransferConcurrency `
            -IntervalSeconds $IntervalSeconds `
            -TimeoutSeconds $TimeoutSeconds `
            -OneDriveTimeoutSeconds $OneDriveTimeoutSeconds `
            -StabilitySeconds $StabilitySeconds `
            -StateRoot $StateRoot
    }
    catch {
        $fatalError = [regex]::Replace($_.Exception.Message, 'https?://\S+', '[redacted URL]')
        if ($_.Exception.Data['MinerUAuthFailure']) {
            $fatalError = 'MinerU authentication was not resolved. ' + $fatalError + ' Run -Action Configure to replace the token.'
        }
        $conversions = @($_.Exception.Data['MinerUPartialResults'] | Where-Object { $null -ne $_ })
        foreach ($item in $report.items) {
            if (@($conversions | Where-Object pdfPath -eq $item.pdfPath).Count -gt 0) { continue }
            if ($item.status -eq 'Missing' -or ($item.status -eq 'Stale' -and $AllowReplaceStale)) {
                $conversions += [pscustomobject]@{status='Failed'; pdfPath=$item.pdfPath; batchId=$null; resumed=$false; error=$fatalError}
            }
            elseif ($item.status -notlike 'Current*') {
                $conversions += [pscustomobject]@{status='ReviewRequired'; pdfPath=$item.pdfPath; batchId=$null; resumed=$false; error="Output status $($item.status) requires review; output preserved."}
            }
        }
    }

    # Verify the original PDF scope; do not enumerate unrelated/new directory entries again.
    $verifyClock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $verified = New-MinerUScanReport -PdfPath @($report.items | ForEach-Object { $_.pdfPath })
        $report.items = $verified.items
        $report.warnings = @($report.warnings) + @($verified.warnings)
        foreach ($name in @('pdfCount','missingCount','currentCount','untrackedCount','staleCount','incompleteCount','invalidMarkerCount')) {
            $report.summary.$name = $verified.summary.$name
        }
    }
    catch {
        $fatalError = 'Final verification failed; initial scan and conversion results are preserved. ' + $_.Exception.Message
        $report.warnings = @($report.warnings) + @($fatalError)
    }
    $verifyClock.Stop()
    $report.action = "Convert"
    $report.conversions = @($conversions)
    $report.summary | Add-Member -NotePropertyName convertedCount -NotePropertyValue @($conversions | Where-Object status -eq "Converted").Count
    $report.summary | Add-Member -NotePropertyName resumedCount -NotePropertyValue @($conversions | Where-Object resumed -eq $true).Count
    $report.summary | Add-Member -NotePropertyName failedCount -NotePropertyValue @($conversions | Where-Object status -eq "Failed").Count
    $report.summary | Add-Member -NotePropertyName reviewRequiredCount -NotePropertyValue @($conversions | Where-Object status -eq 'ReviewRequired').Count
    $report | Add-Member fatalError $fatalError
    $timing = Get-MinerURunTiming
    $timing | Add-Member scanSeconds ([math]::Round($scanClock.Elapsed.TotalSeconds,3))
    $timing | Add-Member verificationSeconds ([math]::Round($verifyClock.Elapsed.TotalSeconds,3))
    $timing | Add-Member totalSeconds ([math]::Round($totalClock.Elapsed.TotalSeconds,3))
    $report | Add-Member timing $timing
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
    timing = if ($Action -eq 'Convert') { $report.timing } else { $null }
}
if ($fatalError) { throw "MinerU conversion stopped: $fatalError Report saved: $writtenReport" }
