[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$testsRoot = $PSScriptRoot
$skillRoot = Join-Path (Split-Path -Parent $testsRoot) "mineru-api-batch-convert"
$entry = Join-Path $skillRoot "scripts\Invoke-MinerUApiBatch.ps1"
$module = Join-Path $skillRoot "scripts\MinerUApiBatch.Core.psm1"
$mockServer = Join-Path $testsRoot "mock_mineru_server.py"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("mineru-api-tests-" + [guid]::NewGuid().ToString("N"))
$papers = Join-Path $tempRoot "papers"
$stateRoot = Join-Path $tempRoot "state"
$readyFile = Join-Path $tempRoot "server.port"
$serverProcess = $null
$originalToken = $env:MINERU_TOKEN
$originalLocalData = $env:MINERU_API_LOCAL_DATA

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function New-TestPdf {
    param([string]$Path, [string]$Label)
    $body = "%PDF-1.4`n1 0 obj<</Type/Catalog>>endobj`n% $Label`n%%EOF`n"
    [System.IO.File]::WriteAllText($Path, $body, [System.Text.Encoding]::ASCII)
}

function Invoke-Entry {
    param([hashtable]$Parameters)
    $output = & $entry @Parameters
    return $output | Select-Object -Last 1
}

New-Item -ItemType Directory -Path $papers -Force | Out-Null
New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
try {
    $parseErrors = New-Object System.Collections.Generic.List[object]
    foreach ($scriptPath in @(Get-ChildItem -LiteralPath (Join-Path $skillRoot "scripts") -File | Where-Object Extension -in @(".ps1", ".psm1"))) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptPath.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        foreach ($error in @($errors)) { $parseErrors.Add($error) }
    }
    Assert-True ($parseErrors.Count -eq 0) "PowerShell scripts must parse without errors."

    $argumentList = @('"' + $mockServer + '"', '--ready-file', '"' + $readyFile + '"')
    $serverProcess = Start-Process -FilePath "python" -ArgumentList $argumentList -PassThru -WindowStyle Hidden
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $readyFile) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    Assert-True (Test-Path -LiteralPath $readyFile) "Mock MinerU server did not start."
    $port = [System.IO.File]::ReadAllText($readyFile).Trim()
    $apiBase = "http://127.0.0.1:$port/api/v4"
    $env:MINERU_TOKEN = "test-token"
    $env:MINERU_API_LOCAL_DATA = Join-Path $tempRoot "local-data"

    Import-Module $module -Force
    $secureToken = ConvertTo-SecureString "stored-test-token" -AsPlainText -Force
    Set-MinerUApiCredential -Token $secureToken | Out-Null
    $env:MINERU_TOKEN = $null
    Assert-True ((Get-MinerUApiToken) -eq "stored-test-token") "DPAPI credential should round-trip for the current user."
    Clear-MinerUApiCredential
    Assert-True (-not (Test-Path -LiteralPath (Get-MinerUApiCredentialPath))) "Credential clear should remove only the encrypted local file."
    $env:MINERU_TOKEN = "test-token"

    $pdf = Join-Path $papers "Alpha paper.pdf"
    New-TestPdf -Path $pdf -Label "alpha"
    $originalHash = (Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash
    $scanReport = Join-Path $tempRoot "scan.json"
    $scan = Invoke-Entry @{ Action = "Scan"; RootPath = @($papers); Recurse = $true; ReportPath = $scanReport }
    Assert-True ($scan.summary.pdfCount -eq 1) "Scan should find one PDF."
    Assert-True ($scan.summary.missingCount -eq 1) "Fresh PDF should be missing Markdown."

    $convertReport = Join-Path $tempRoot "convert.json"
    $convert = Invoke-Entry @{
        Action = "Convert"; RootPath = @($papers); Recurse = $true; ReportPath = $convertReport
        ApiBase = $apiBase; StateRoot = $stateRoot; IntervalSeconds = 0; TimeoutSeconds = 30
        StabilitySeconds = 0; BatchSize = 2
    }
    Assert-True ($convert.summary.convertedCount -eq 1) "Mock API conversion should succeed."
    $markdown = [System.IO.Path]::ChangeExtension($pdf, ".md")
    $assets = Join-Path $papers "Alpha paper.assets"
    Assert-True (Test-Path -LiteralPath $markdown -PathType Leaf) "Markdown should be published beside PDF."
    Assert-True (Test-Path -LiteralPath (Join-Path $assets "images\figure.png") -PathType Leaf) "Image should be published under assets."
    $markdownText = [System.IO.File]::ReadAllText($markdown)
    Assert-True ($markdownText.Contains("<!-- mineru-batch-convert")) "Markdown should contain a compatible ownership marker."
    Assert-True ($markdownText.Contains("Alpha%20paper.assets/images/figure.png")) "Image link should target the URL-encoded sidecar assets directory."
    Assert-True (-not $markdownText.Contains("Alpha%20paper.assets/Alpha%20paper.assets")) "Image links must not be rewritten twice."
    Assert-True ((Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash -eq $originalHash) "Source PDF hash must remain unchanged."

    $current = Invoke-Entry @{ Action = "Scan"; RootPath = @($papers); Recurse = $true; ReportPath = (Join-Path $tempRoot "current.json") }
    Assert-True ($current.summary.currentCount -eq 1) "Converted PDF should scan as current."

    $betaPdf = Join-Path $papers "Beta.pdf"
    $gammaPdf = Join-Path $papers "Gamma.pdf"
    New-TestPdf -Path $betaPdf -Label "beta"
    New-TestPdf -Path $gammaPdf -Label "gamma"
    $multi = Invoke-Entry @{
        Action = "Convert"; PdfPath = @($betaPdf, $gammaPdf); ReportPath = (Join-Path $tempRoot "multi.json")
        ApiBase = $apiBase; StateRoot = $stateRoot; IntervalSeconds = 0; TimeoutSeconds = 30
        StabilitySeconds = 0; BatchSize = 2
    }
    Assert-True ($multi.summary.convertedCount -eq 2) "Two PDFs should convert in one API batch."
    Assert-True (Test-Path -LiteralPath ([System.IO.Path]::ChangeExtension($betaPdf, ".md"))) "First batch Markdown should exist."
    Assert-True (Test-Path -LiteralPath ([System.IO.Path]::ChangeExtension($gammaPdf, ".md"))) "Second batch Markdown should exist."

    [System.IO.File]::AppendAllText($pdf, "updated")
    $updatedHash = (Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash
    $stale = Invoke-Entry @{ Action = "Scan"; PdfPath = @($pdf); ReportPath = (Join-Path $tempRoot "stale-scan.json") }
    Assert-True ($stale.summary.staleCount -eq 1) "Changed source content should scan as stale."
    $updated = Invoke-Entry @{
        Action = "Convert"; PdfPath = @($pdf); ReportPath = (Join-Path $tempRoot "stale-convert.json")
        ApiBase = $apiBase; StateRoot = $stateRoot; IntervalSeconds = 0; TimeoutSeconds = 30; StabilitySeconds = 0
    }
    Assert-True ($updated.summary.convertedCount -eq 1) "Tracked stale output should be replaced safely."
    Assert-True ((Get-FileHash -LiteralPath $pdf -Algorithm SHA256).Hash -eq $updatedHash) "Stale reconversion must not modify the updated PDF."

    $collisionPdf = Join-Path $papers "Collision.pdf"
    $collisionMd = Join-Path $papers "Collision.md"
    New-TestPdf -Path $collisionPdf -Label "collision"
    [System.IO.File]::WriteAllText($collisionMd, "# User note", [System.Text.Encoding]::UTF8)
    $collision = Invoke-Entry @{ Action = "Scan"; PdfPath = @($collisionPdf); ReportPath = (Join-Path $tempRoot "collision.json") }
    Assert-True ($collision.summary.untrackedCount -eq 1) "Untracked same-name Markdown must be protected."

    Remove-Item -LiteralPath $pdf -Force
    $orphanReport = Join-Path $tempRoot "orphan.json"
    $orphan = Invoke-Entry @{ Action = "Scan"; RootPath = @($papers); Recurse = $true; ReportPath = $orphanReport }
    Assert-True ($orphan.summary.orphanCount -eq 1) "Removed PDF should produce one orphan."
    $recycle = Invoke-Entry @{ Action = "Recycle"; ReportPath = $orphanReport; ConfirmRecycle = $true }
    Assert-True ($recycle.recycledCount -eq 1) "Confirmed orphan should move to Recycle Bin."
    Assert-True (-not (Test-Path -LiteralPath $markdown)) "Recycled Markdown should leave its source directory."
    Assert-True (-not (Test-Path -LiteralPath $assets)) "Recycled assets should leave their source directory."

    $resumePdf = Join-Path $papers "resume.pdf"
    New-TestPdf -Path $resumePdf -Label "resume"
    $firstResume = Invoke-Entry @{
        Action = "Convert"; PdfPath = @($resumePdf); ReportPath = (Join-Path $tempRoot "resume-first.json")
        ApiBase = $apiBase; StateRoot = $stateRoot; IntervalSeconds = 1; TimeoutSeconds = 1; StabilitySeconds = 0
    }
    Assert-True ($firstResume.summary.failedCount -eq 1) "Timed-out batch should be reported without resubmission."
    Assert-True (@(Get-ChildItem -LiteralPath $stateRoot -File -Filter "*.json").Count -eq 1) "Timed-out batch state should persist."
    $secondResume = Invoke-Entry @{
        Action = "Convert"; PdfPath = @($resumePdf); ReportPath = (Join-Path $tempRoot "resume-second.json")
        ApiBase = $apiBase; StateRoot = $stateRoot; IntervalSeconds = 0; TimeoutSeconds = 30; StabilitySeconds = 0
    }
    Assert-True ($secondResume.summary.convertedCount -eq 1) "Next run should complete the pending batch."
    Assert-True ($secondResume.summary.resumedCount -eq 1) "Completed pending batch should be marked resumed."
    Assert-True (@(Get-ChildItem -LiteralPath $stateRoot -File -Filter "*.json").Count -eq 0) "Successful resume should remove pending state."

    $evilPdf = Join-Path $papers "evil.pdf"
    New-TestPdf -Path $evilPdf -Label "evil"
    $evil = Invoke-Entry @{
        Action = "Convert"; PdfPath = @($evilPdf); ReportPath = (Join-Path $tempRoot "evil.json")
        ApiBase = $apiBase; StateRoot = $stateRoot; IntervalSeconds = 0; TimeoutSeconds = 30; StabilitySeconds = 0
    }
    Assert-True ($evil.summary.failedCount -eq 1) "Unsafe ZIP should fail conversion."
    Assert-True (-not (Test-Path -LiteralPath ([System.IO.Path]::ChangeExtension($evilPdf, ".md")))) "Unsafe ZIP must not publish Markdown."

    Remove-Item -LiteralPath $stateRoot -Recurse -Force
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    $env:MINERU_TOKEN = "invalid-token"
    $authFailed = $false
    try {
        Invoke-Entry @{
            Action = "Convert"; PdfPath = @($evilPdf); ReportPath = (Join-Path $tempRoot "auth.json")
            ApiBase = $apiBase; StateRoot = $stateRoot; IntervalSeconds = 0; TimeoutSeconds = 30; StabilitySeconds = 0
        } | Out-Null
    }
    catch {
        $authFailed = $_.Exception.Message -match "rejected the saved API token"
    }
    Assert-True $authFailed "HTTP 401 should request credential replacement."

    [pscustomobject]@{
        passed = $true
        checks = 33
        tempRoot = $tempRoot
    }
}
finally {
    $env:MINERU_TOKEN = $originalToken
    $env:MINERU_API_LOCAL_DATA = $originalLocalData
    if ($serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
        $serverProcess.WaitForExit()
    }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
