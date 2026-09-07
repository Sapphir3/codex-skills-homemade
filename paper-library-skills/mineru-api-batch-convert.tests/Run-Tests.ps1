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
$script:checks = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    $script:checks++
}

function New-TestPdf {
    param([string]$Path, [string]$Label)
    $body = "%PDF-1.4`n1 0 obj<</Type/Catalog>>endobj`n% $Label`n%%EOF`n"
    [System.IO.File]::WriteAllText($Path, $body, [System.Text.Encoding]::ASCII)
}

function Test-PathWithinForTests {
    param([string]$Path, [string]$Root)
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return [IO.Path]::GetFullPath($Path).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
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
    foreach($case in @('quota403','rate429','server503','quota200','invalid200')) {
        $authFlag=& (Get-Module MinerUApiBatch.Core) {
            param($url)
            try { Invoke-MinerUApiRequest -Uri $url -Token 'test-token'|Out-Null; 'UnexpectedSuccess' }
            catch { [bool]$_.Exception.Data['MinerUAuthFailure'] }
        } "$apiBase/authprobe/$case"
        Assert-True ($authFlag -eq ($case -eq 'invalid200')) 'Only authentication errors should request credential replacement.'
    }
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
    Assert-True ($convert.summary.convertedCount -eq 1) ("Mock API conversion should succeed. " + ($convert.conversions | ConvertTo-Json -Compress))
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
    $currentState=Get-Content -LiteralPath (Join-Path $tempRoot 'current.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert-True ($currentState.items[0].status -eq 'Current') 'Timestamp deserialization must not force an unchanged PDF into the rehash path.'
    $env:MINERU_TOKEN=$null
    $noWork=Invoke-Entry @{Action='Convert'; PdfPath=@($pdf); ApiBase=$apiBase; StateRoot=$stateRoot; ReportPath=(Join-Path $tempRoot 'no-work.json')}
    Assert-True ($noWork.summary.convertedCount -eq 0 -and $noWork.summary.currentCount -eq 1) 'Current outputs must skip without credentials.'
    $env:MINERU_TOKEN='test-token'

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
    $beforeConsent = (Get-FileHash -LiteralPath $markdown).Hash
    $beforeBatches = (Invoke-RestMethod "http://127.0.0.1:$port/stats").batches
    $env:MINERU_TOKEN = $null
    $preserved = Invoke-Entry @{
        Action='Convert'; PdfPath=@($pdf); ReportPath=(Join-Path $tempRoot 'no-consent.json')
        ApiBase=$apiBase; StateRoot=$stateRoot; CredentialPrompt='Never'
    }
    Assert-True ($preserved.summary.reviewRequiredCount -eq 1 -and $preserved.summary.convertedCount -eq 0) 'Stale conversion requires explicit consent without asking for a credential.'
    Assert-True ((Get-FileHash -LiteralPath $markdown).Hash -eq $beforeConsent -and (Invoke-RestMethod "http://127.0.0.1:$port/stats").batches -eq $beforeBatches) 'Unapproved replacement must preserve Markdown and allocate no batch.'
    $env:MINERU_TOKEN = 'test-token'
    $updated = Invoke-Entry @{
        Action = "Convert"; PdfPath = @($pdf); ReportPath = (Join-Path $tempRoot "stale-convert.json")
        ApiBase = $apiBase; StateRoot = $stateRoot; IntervalSeconds = 0; TimeoutSeconds = 30; StabilitySeconds = 0; AllowReplaceStale = $true
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

    $common=@{Action='Convert'; ApiBase=$apiBase; StateRoot=$stateRoot; IntervalSeconds=0; TimeoutSeconds=30; StabilitySeconds=0; ReportPath=(Join-Path $tempRoot 'extended.json'); TransferConcurrency=3}
    $rich=Join-Path $papers 'richimages # figure (1).pdf'
    New-TestPdf $rich 'rich'
    $r=Invoke-Entry ($common + @{PdfPath=@($rich)})
    Assert-True ($r.summary.convertedCount -eq 1) 'HTML, reference-style, and parenthesized image destinations convert.'
    $body=[IO.File]::ReadAllText([IO.Path]::ChangeExtension($rich,'.md'))
    Assert-True ($body.Contains('richimages%20%23%20figure%20%281%29.assets/images/b%23.png')) 'Filename URL encoding must include hash and parentheses.'
    Assert-True ($body.Contains('Prose: images/figure.png')) 'Image-path prose must not be rewritten.'
    Assert-True ($r.conversions[0].assetCount -eq 3) 'Copy only the three referenced images, not unused images.'

    $textOnly=Join-Path $papers 'noimages.pdf'
    New-TestPdf $textOnly 'plain'
    $r=Invoke-Entry ($common + @{PdfPath=@($textOnly)})
    Assert-True ($r.summary.convertedCount -eq 1 -and $r.conversions[0].assetCount -eq 0) 'Text-only documents must convert without an assets directory.'

    $missing=Join-Path $papers 'missingimage.pdf'
    New-TestPdf $missing 'missing image'
    $r=Invoke-Entry ($common + @{PdfPath=@($missing)})
    Assert-True ($r.summary.failedCount -eq 1 -and !(Test-Path -LiteralPath ([IO.Path]::ChangeExtension($missing,'.md')))) 'Missing referenced images must prevent publication.'

    $omitted=Join-Path $papers 'omitted.pdf'
    New-TestPdf $omitted 'partial response'
    $r=Invoke-Entry ($common + @{PdfPath=@($omitted)})
    Assert-True ($r.summary.convertedCount -eq 1 -and $r.timing.pollRequests -ge 2) 'An omitted document must be polled again, not silently dropped.'

    $uploadFail=Join-Path $papers 'uploadfail.pdf'
    $uploadOk=Join-Path $papers 'uploadok.pdf'
    New-TestPdf $uploadFail 'fail first upload'
    New-TestPdf $uploadOk 'success first upload'
    $before=Invoke-RestMethod "http://127.0.0.1:$port/stats"
    $r=Invoke-Entry ($common + @{PdfPath=@($uploadFail,$uploadOk)})
    Assert-True ($r.summary.failedCount -eq 2) 'Interrupted upload must retain a recoverable batch.'
    $saved=@(Get-ChildItem -LiteralPath $stateRoot -Filter '*.json' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8|ConvertFrom-Json } | Where-Object { @($_.items|Where-Object pdfPath -eq $uploadFail).Count -gt 0 })[0]
    Assert-True ($saved.schemaVersion -eq 2 -and $saved.submissionConfirmed) 'Batch identity must exist before uploads finish.'
    $savedText=[IO.File]::ReadAllText($saved.statePath)
    Assert-True (!$savedText.Contains('/upload/') -and !$savedText.Contains('test-token')) 'State must not contain plaintext signed URLs or API tokens.'
    $r=Invoke-Entry ($common + @{PdfPath=@($uploadFail,$uploadOk)})
    $after=Invoke-RestMethod "http://127.0.0.1:$port/stats"
    Assert-True ($r.summary.convertedCount -eq 2 -and $r.summary.resumedCount -eq 2) 'Resume must recover failed uploads and publish all selected outputs.'
    Assert-True ($after.batches -eq $before.batches+1) 'Upload recovery must not allocate another batch.'
    $okAttempts=@($after.attempts.PSObject.Properties|Where-Object Name -like '*uploadok*')[0].Value
    Assert-True ($okAttempts -eq 1) 'Successfully uploaded files must not upload again.'

    $fast=Join-Path $papers 'early.pdf'
    $slow=Join-Path $papers 'slow.pdf'
    New-TestPdf $fast 'early result'
    New-TestPdf $slow 'late result'
    $p=$common.Clone(); $p.IntervalSeconds=1; $p.TimeoutSeconds=1; $p.PdfPath=@($fast,$slow)
    $r=Invoke-Entry $p
    Assert-True ($r.summary.convertedCount -eq 1 -and $r.summary.failedCount -eq 1) 'Publish the ready result before the slow document completes.'
    $pending=@(Get-ChildItem -LiteralPath $stateRoot -Filter '*.json'|ForEach-Object {Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8|ConvertFrom-Json}|Where-Object {@($_.items|Where-Object pdfPath -eq $slow).Count -gt 0})[0]
    $before=Invoke-RestMethod "http://127.0.0.1:$port/stats"
    $r=Invoke-Entry ($common + @{PdfPath=@($fast)})
    Assert-True (!(Test-Path -LiteralPath ([IO.Path]::ChangeExtension($slow,'.md')))) 'Subset recovery must not publish a sibling outside the requested scope.'
    $r=Invoke-Entry ($common + @{PdfPath=@($slow)})
    $after=Invoke-RestMethod "http://127.0.0.1:$port/stats"
    Assert-True ($r.summary.convertedCount -eq 1 -and $r.summary.resumedCount -eq 1) 'The remaining sibling must be independently recoverable.'
    Assert-True ($after.batches -eq $before.batches) 'Partial-scope recovery must reuse its batch.'
    Assert-True (@($after.downloads|Where-Object {$_[0] -like '*early'}).Count -eq 1) 'Published results must never be downloaded again during recovery.'
    Assert-True ((Test-Path -LiteralPath ([IO.Path]::ChangeExtension($missing,'.md'))) -eq $false) 'Unrelated pending batches must remain untouched.'

    $unicodePdf=Join-Path $papers ([string][char]0x6D4B+[char]0x8BD5+' D'+[char]0xFA+'zs.pdf')
    New-TestPdf $unicodePdf 'unicode filename'
    $r=Invoke-Entry ($common + @{PdfPath=@($unicodePdf)})
    Assert-True ($r.summary.convertedCount -eq 1) 'UTF-8 filenames must survive request, state, and publication.'

    $reviewPdf=Join-Path $papers 'review.pdf'
    New-TestPdf $reviewPdf 'assets collision'
    New-Item -ItemType Directory -Path (Join-Path $papers 'review.assets')|Out-Null
    $before=Invoke-RestMethod "http://127.0.0.1:$port/stats"
    $r=Invoke-Entry ($common + @{PdfPath=@($reviewPdf)})
    $after=Invoke-RestMethod "http://127.0.0.1:$port/stats"
    Assert-True ($r.summary.incompleteCount -eq 1 -and $after.batches -eq $before.batches) 'Incomplete assets require review without upload.'
    Assert-True ($r.timing.totalSeconds -ge 0 -and $r.timing.pollRequests -eq 0) 'No-work conversion must return timing and make no polling requests.'

    $integrityRoot = Join-Path $papers 'integrity'
    New-Item -ItemType Directory -Path $integrityRoot | Out-Null
    $integrityPdf = Join-Path $integrityRoot 'integrity.pdf'
    New-TestPdf $integrityPdf 'image integrity'
    $parameters = $common.Clone(); $parameters.PdfPath = @($integrityPdf)
    $integrity = Invoke-Entry $parameters
    Assert-True ($integrity.summary.convertedCount -eq 1) 'Prepare isolated integrity fixture.'
    $integrityMarkdown = [IO.Path]::ChangeExtension($integrityPdf, '.md')
    $integrityAssets = Join-Path $integrityRoot 'integrity.assets'
    $figure = Join-Path $integrityAssets 'images\figure.png'
    $figureBytes = [IO.File]::ReadAllBytes($figure)
    $originalMarkdown = [IO.File]::ReadAllText($integrityMarkdown)
    $marker = & (Get-Module MinerUApiBatch.Core) { param($path) Read-MinerUMarker $path } $integrityMarkdown
    Remove-Item -LiteralPath $figure
    $broken = Invoke-Entry $parameters
    Assert-True ($broken.summary.incompleteCount -eq 1 -and $broken.summary.convertedCount -eq 0) 'A missing referenced image is incomplete even when the directory still exists.'
    $otherFigure = Join-Path $integrityAssets 'images\other.png'
    [IO.File]::WriteAllBytes($otherFigure, $figureBytes)
    $broken = Invoke-Entry $parameters
    Assert-True ($broken.summary.incompleteCount -eq 1) 'An equal asset count cannot conceal a missing referenced image.'
    Remove-Item -LiteralPath $otherFigure
    [IO.File]::WriteAllBytes($figure, $figureBytes)
    Assert-True ((Invoke-Entry $parameters).summary.currentCount -eq 1) 'Restored image integrity permits a current result.'

    foreach ($malformation in @('assetsEscape','sourceEscape','missingField','badDate','badHash')) {
        $badMarker = $marker | ConvertTo-Json | ConvertFrom-Json
        switch ($malformation) {
            'assetsEscape' { $badMarker.assetsDirectory = '..\outside' }
            'sourceEscape' { $badMarker.sourcePdf = '..\other.pdf' }
            'missingField' { $badMarker.PSObject.Properties.Remove('sourceLength') }
            'badDate' { $badMarker.sourceLastWriteUtc = 'not-a-date' }
            'badHash' { $badMarker.sourceSha256 = 'not-a-hash' }
        }
        [IO.File]::WriteAllText($integrityMarkdown, '<!-- mineru-batch-convert ' + ($badMarker | ConvertTo-Json -Compress) + " -->`n# fixture")
        $invalid = Invoke-Entry $parameters
        Assert-True ($invalid.summary.invalidMarkerCount -eq 1 -and $invalid.summary.reviewRequiredCount -eq 1) 'Malformed markers must require review instead of crashing or uploading.'
    }
    [IO.File]::WriteAllText($integrityMarkdown, $originalMarkdown)
    $legacyMarker = $marker | ConvertTo-Json | ConvertFrom-Json
    $legacyMarker.PSObject.Properties.Remove('sourceSha256')
    [IO.File]::WriteAllText($integrityMarkdown, '<!-- mineru-batch-convert ' + ($legacyMarker | ConvertTo-Json -Compress) + " -->`n![Figure](integrity.assets/images/figure.png)")
    Assert-True ((Invoke-Entry $parameters).summary.currentCount -eq 1) 'Legacy markers without an optional source hash remain readable.'
    [IO.File]::WriteAllText($integrityMarkdown, $originalMarkdown)

    $heldPdf = Join-Path $tempRoot 'held-integrity.pdf'
    if (!(Test-PathWithinForTests $integrityPdf $tempRoot) -or !(Test-PathWithinForTests $heldPdf $tempRoot)) { throw 'Unsafe fixture move.' }
    Move-Item -LiteralPath $integrityPdf -Destination $heldPdf
    $cleanupReportPath = Join-Path $tempRoot 'safety-orphan.json'
    $null = Invoke-Entry @{Action='Scan'; RootPath=@($integrityRoot); ReportPath=$cleanupReportPath}
    $cleanupReport = Get-Content -LiteralPath $cleanupReportPath -Raw | ConvertFrom-Json
    Assert-True ($cleanupReport.orphans.Count -eq 1) 'Prepare a reviewed orphan fixture.'
    $lateRename = Join-Path $integrityRoot 'renamed-later.pdf'
    Copy-Item -LiteralPath $heldPdf -Destination $lateRename
    $recheck = Invoke-Entry @{Action='Recycle'; ReportPath=$cleanupReportPath; ConfirmRecycle=$true}
    Assert-True ($recheck.skippedCount -eq 1 -and (Test-Path -LiteralPath $integrityMarkdown)) 'A rename appearing after the scan must prevent recycling.'
    Remove-Item -LiteralPath $lateRename

    $outside = Join-Path $tempRoot 'outside'
    New-Item -ItemType Directory -Path $outside | Out-Null
    $sentinel = Join-Path $outside 'keep.txt'
    [IO.File]::WriteAllText($sentinel, 'must survive')
    $cleanupReport.orphans[0].assetsPath = $outside
    $null = Write-MinerUReport -Report $cleanupReport -Path $cleanupReportPath
    $recheck = Invoke-Entry @{Action='Recycle'; ReportPath=$cleanupReportPath; ConfirmRecycle=$true}
    Assert-True ($recheck.skippedCount -eq 1 -and (Test-Path -LiteralPath $sentinel)) 'Report asset paths outside the canonical sibling directory are rejected.'

    $escapedMarker = $marker | ConvertTo-Json | ConvertFrom-Json
    $escapedMarker.assetsDirectory = '..\..\outside'
    [IO.File]::WriteAllText($integrityMarkdown, '<!-- mineru-batch-convert ' + ($escapedMarker | ConvertTo-Json -Compress) + " -->`n# fixture")
    $cleanupReport.orphans[0].marker = $escapedMarker
    $cleanupReport.orphans[0].markdownLength = (Get-Item -LiteralPath $integrityMarkdown).Length
    $cleanupReport.orphans[0].markdownLastWriteUtc = (Get-Item -LiteralPath $integrityMarkdown).LastWriteTimeUtc.ToString('o')
    $null = Write-MinerUReport -Report $cleanupReport -Path $cleanupReportPath
    $recheck = Invoke-Entry @{Action='Recycle'; ReportPath=$cleanupReportPath; ConfirmRecycle=$true}
    Assert-True ($recheck.skippedCount -eq 1 -and (Test-Path -LiteralPath $sentinel)) 'Matching escaped marker and report paths must not authorize external recycling.'
    $invalidOrphan = Invoke-Entry @{Action='Scan'; RootPath=@($integrityRoot); ReportPath=(Join-Path $tempRoot 'invalid-orphan.json')}
    Assert-True ($invalidOrphan.summary.orphanCount -eq 0 -and $invalidOrphan.warnings.Count -gt 0) 'Malformed orphan markers are excluded from cleanup candidates.'
    [IO.File]::WriteAllText($integrityMarkdown, $originalMarkdown)
    $null = Invoke-Entry @{Action='Scan'; RootPath=@($integrityRoot); ReportPath=$cleanupReportPath}
    $cleanupReport = Get-Content -LiteralPath $cleanupReportPath -Raw | ConvertFrom-Json
    $cleanupReport.scanScopes[0].path = $papers
    $cleanupReport.scanScopes[0].recursive = $false
    $null = Write-MinerUReport -Report $cleanupReport -Path $cleanupReportPath
    $recheck = Invoke-Entry @{Action='Recycle'; ReportPath=$cleanupReportPath; ConfirmRecycle=$true}
    Assert-True ($recheck.skippedCount -eq 1) 'A nonrecursive scan does not authorize nested cleanup.'
    [IO.File]::WriteAllText($integrityMarkdown, '<!-- mineru-batch-convert ' + ($legacyMarker | ConvertTo-Json -Compress) + " -->`n![Figure](integrity.assets/images/figure.png)")
    $null = Invoke-Entry @{Action='Scan'; RootPath=@($integrityRoot); ReportPath=$cleanupReportPath}
    $recheck = Invoke-Entry @{Action='Recycle'; ReportPath=$cleanupReportPath; ConfirmRecycle=$true}
    Assert-True ($recheck.skippedCount -eq 1 -and (Test-Path -LiteralPath $integrityMarkdown)) 'A legacy orphan without a source hash requires manual rename review.'
    [IO.File]::WriteAllText($integrityMarkdown, $originalMarkdown)
    if (!(Test-PathWithinForTests $heldPdf $tempRoot) -or !(Test-PathWithinForTests $integrityPdf $tempRoot)) { throw 'Unsafe fixture move.' }
    Move-Item -LiteralPath $heldPdf -Destination $integrityPdf

    $heldAssets = Join-Path $tempRoot 'held-assets'
    if (!(Test-PathWithinForTests $integrityAssets $tempRoot) -or !(Test-PathWithinForTests $heldAssets $tempRoot)) { throw 'Unsafe fixture move.' }
    Move-Item -LiteralPath $integrityAssets -Destination $heldAssets
    $null = New-Item -ItemType Junction -Path $integrityAssets -Target $outside
    try {
        $linked = Invoke-Entry $parameters
        Assert-True ($linked.summary.invalidMarkerCount -eq 1 -and (Test-Path -LiteralPath $sentinel)) 'An assets junction must not redirect ownership checks outside the sibling directory.'
    }
    finally {
        if (!(Test-PathWithinForTests $integrityAssets $tempRoot) -or !((Get-Item -LiteralPath $integrityAssets -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe junction cleanup.' }
        [IO.Directory]::Delete($integrityAssets)
        if (!(Test-PathWithinForTests $heldAssets $tempRoot) -or !(Test-PathWithinForTests $integrityAssets $tempRoot)) { throw 'Unsafe fixture move.' }
        Move-Item -LiteralPath $heldAssets -Destination $integrityAssets
    }

    $staleResumePdf = Join-Path $papers 'resumestale.pdf'
    New-TestPdf $staleResumePdf 'stale checkpoint consent'
    $resumeParameters = $common.Clone(); $resumeParameters.PdfPath = @($staleResumePdf)
    $resumeParameters.StateRoot = Join-Path $tempRoot 'stale-consent-state'
    $null = Invoke-Entry $resumeParameters
    [IO.File]::AppendAllText($staleResumePdf, 'changed source')
    $resumeParameters.AllowReplaceStale = $true; $resumeParameters.IntervalSeconds = 1; $resumeParameters.TimeoutSeconds = 1
    $pendingConsent = Invoke-Entry $resumeParameters
    Assert-True ($pendingConsent.summary.failedCount -eq 1) 'Prepare a pending authorized stale replacement.'
    $beforeBatches = (Invoke-RestMethod "http://127.0.0.1:$port/stats").batches
    $resumeParameters.AllowReplaceStale = $false; $resumeParameters.IntervalSeconds = 0; $resumeParameters.TimeoutSeconds = 30
    $pendingConsent = Invoke-Entry $resumeParameters
    Assert-True ($pendingConsent.summary.reviewRequiredCount -eq 1 -and $pendingConsent.timing.pollRequests -eq 0) 'A checkpoint cannot bypass replacement consent on a later invocation.'
    $resumeParameters.AllowReplaceStale = $true
    $pendingConsent = Invoke-Entry $resumeParameters
    Assert-True ($pendingConsent.summary.convertedCount -eq 1 -and $pendingConsent.summary.resumedCount -eq 1 -and (Invoke-RestMethod "http://127.0.0.1:$port/stats").batches -eq $beforeBatches) 'Approved stale recovery reuses its original batch.'

    $environment = Invoke-Entry @{Action='Environment'}
    Assert-True ($environment.skillVersion -eq '2.0.0' -and $environment.skillPath -eq [IO.Path]::GetFullPath($skillRoot)) 'Environment identifies the actual runtime version and source directory.'

    foreach ($rejection in @('rejectquota','rejectvalidation','rejectlogical')) {
        $rejectedPdf = Join-Path $papers ($rejection + '.pdf')
        New-TestPdf $rejectedPdf $rejection
        $parameters = $common.Clone(); $parameters.PdfPath = @($rejectedPdf)
        $parameters.StateRoot = Join-Path $tempRoot ($rejection + '-state')
        $beforeBatches = (Invoke-RestMethod "http://127.0.0.1:$port/stats").batches
        $rejected = Invoke-Entry $parameters
        Assert-True ($rejected.summary.failedCount -eq 1 -and (Invoke-RestMethod "http://127.0.0.1:$port/stats").batches -eq $beforeBatches) 'A definite submission rejection must not allocate a batch.'
        Assert-True (@(Get-ChildItem -LiteralPath $parameters.StateRoot -Filter '*.json').Count -eq 0) 'A definite rejection must not leave an unknown-outcome checkpoint.'
        $retried = Invoke-Entry $parameters
        Assert-True ($retried.summary.convertedCount -eq 1) 'An explicit later retry can succeed after quota or validation rejection.'
    }
    $ambiguousLogical = & (Get-Module MinerUApiBatch.Core) {
        param($uri)
        try { Invoke-MinerUApiRequestOnce -Uri $uri -Token 'test-token'; $false }
        catch { !$_.Exception.Data['MinerUSubmissionRejected'] -and !$_.Exception.Data['MinerUAuthFailure'] }
    } "$apiBase/authprobe/ambiguous200"
    Assert-True $ambiguousLogical 'Unknown service errors must not be classified as definite submission rejection.'

    $failureRoot = Join-Path $papers 'partial-report'
    New-Item -ItemType Directory -Path $failureRoot | Out-Null
    $beforeAuth = Join-Path $failureRoot 'a-completed.pdf'
    $authStop = Join-Path $failureRoot 'b-authstop.pdf'
    $unsubmitted = Join-Path $failureRoot 'c-unsubmitted.pdf'
    foreach ($failurePdf in @($beforeAuth,$authStop,$unsubmitted)) { New-TestPdf $failurePdf 'partial authentication failure' }
    $parameters = $common.Clone()
    $parameters.PdfPath = @($beforeAuth,$authStop,$unsubmitted); $parameters.BatchSize = 1
    $parameters.StateRoot = Join-Path $tempRoot 'partial-auth-state'
    $parameters.ReportPath = Join-Path $tempRoot 'partial-auth.json'
    $stopped = $false
    try { Invoke-Entry $parameters | Out-Null } catch { $stopped = $_.Exception.Message.Contains($parameters.ReportPath) }
    $partial = Get-Content -LiteralPath $parameters.ReportPath -Raw | ConvertFrom-Json
    Assert-True ($stopped -and $partial.summary.convertedCount -eq 1 -and $partial.summary.failedCount -eq 2) 'Fatal authentication preserves earlier batch successes and reports remaining files before throwing.'
    Assert-True ((Test-Path -LiteralPath ([IO.Path]::ChangeExtension($beforeAuth,'.md'))) -and !(Test-Path -LiteralPath ([IO.Path]::ChangeExtension($unsubmitted,'.md')))) 'Authentication failure stops later submissions without removing successful outputs.'
    Assert-True ($partial.fatalError -and !$partial.fatalError.Contains('test-token')) 'Fatal reports must not contain the token.'

    $pollEarly = Join-Path $failureRoot 'poll-early.pdf'
    $pollAuth = Join-Path $failureRoot 'slow-pollauth.pdf'
    New-TestPdf $pollEarly 'early success'; New-TestPdf $pollAuth 'poll authentication failure'
    $parameters.PdfPath = @($pollEarly,$pollAuth); $parameters.BatchSize = 2
    $parameters.ReportPath = Join-Path $tempRoot 'poll-auth.json'
    $stopped = $false
    try { Invoke-Entry $parameters | Out-Null } catch { $stopped = $_.Exception.Message.Contains($parameters.ReportPath) }
    $partial = Get-Content -LiteralPath $parameters.ReportPath -Raw | ConvertFrom-Json
    Assert-True ($stopped -and $partial.summary.convertedCount -eq 1 -and $partial.summary.failedCount -eq 1) 'Authentication failure during polling preserves early publications within the same batch.'
    Assert-True (@(Get-ChildItem -LiteralPath $parameters.StateRoot -Filter '*.json').Count -eq 1) 'Polling authentication failure retains the recoverable batch.'

    # End-to-end credential onboarding against the HTTP mock; no real token or UI.
    foreach($onboarding in @('first','replacement')) {
        $onboardingPdf=Join-Path $papers ("onboarding-$onboarding.pdf")
        New-TestPdf $onboardingPdf 'credential onboarding'
        $env:MINERU_TOKEN=$null
        Clear-MinerUApiCredential
        if($onboarding -eq 'replacement'){Set-MinerUApiCredential (ConvertTo-SecureString 'old-invalid-token' -AsPlainText -Force)|Out-Null}
        $before=Invoke-RestMethod "http://127.0.0.1:$port/stats"
        $result=& (Get-Module MinerUApiBatch.Core) {
            param($pdfPath,$base,$state)
            $script:CredentialSetupUsed=$false; $script:ReplacementToken=$null; $script:promptCount=0
            function Read-MinerUToken { $script:promptCount++; ConvertTo-SecureString 'test-token' -AsPlainText -Force }
            $scan=New-MinerUScanReport -PdfPath @($pdfPath)
            $converted=@(Invoke-MinerUApiConversions -ScanReport $scan -ApiBase $base -StateRoot $state -StabilitySeconds 0 -IntervalSeconds 0)
            [pscustomobject]@{converted=@($converted|Where-Object status -eq 'Converted').Count; prompts=$script:promptCount}
        } $onboardingPdf $apiBase $stateRoot
        $after=Invoke-RestMethod "http://127.0.0.1:$port/stats"
        Assert-True ($result.converted -eq 1 -and $result.prompts -eq 1) 'Credential setup must continue the actual requested conversion.'
        Assert-True ($after.batches -eq $before.batches+1) 'Credential setup/replacement must create exactly one batch.'
        $env:MINERU_TOKEN='test-token'
    }

    $unknown=Join-Path $papers 'submitunknown.pdf'
    New-TestPdf $unknown 'unknown POST outcome'
    $before=Invoke-RestMethod "http://127.0.0.1:$port/stats"
    $r=Invoke-Entry ($common + @{PdfPath=@($unknown)})
    Assert-True ($r.summary.failedCount -eq 1) 'Ambiguous submission must be recorded as incomplete.'
    $r=Invoke-Entry ($common + @{PdfPath=@($unknown)})
    $after=Invoke-RestMethod "http://127.0.0.1:$port/stats"
    Assert-True ($r.summary.failedCount -eq 1 -and $after.batches -eq $before.batches+1) 'Unknown POST outcome must block automatic duplicate submission.'

    $legacy=Join-Path $papers 'resumelegacy.pdf'
    New-TestPdf $legacy 'legacy v1 checkpoint'
    $p=$common.Clone(); $p.IntervalSeconds=1; $p.TimeoutSeconds=1; $p.PdfPath=@($legacy)
    $r=Invoke-Entry $p
    $checkpoint=@(Get-ChildItem -LiteralPath $stateRoot -Filter '*.json'|ForEach-Object {Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8|ConvertFrom-Json}|Where-Object {@($_.items|Where-Object pdfPath -eq $legacy).Count -gt 0})[0]
    $checkpoint.schemaVersion=1
    $checkpoint.PSObject.Properties.Remove('submissionConfirmed')
    foreach($item in $checkpoint.items){foreach($prop in @('uploaded','published','terminalFailure','uploadUrlProtected')){$item.PSObject.Properties.Remove($prop)}}
    [IO.File]::WriteAllText($checkpoint.statePath,($checkpoint|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    $r=Invoke-Entry ($common + @{PdfPath=@($legacy)})
    Assert-True ($r.summary.convertedCount -eq 1 -and $r.summary.resumedCount -eq 1) 'v1.0.x checkpoint files must remain resumable.'

    # Inject a new user note between artifact preparation and final publication.
    $racePdf=Join-Path $papers 'race.pdf'; New-TestPdf $racePdf 'race'
    $raceStage=Join-Path $tempRoot 'race-stage'; New-Item -ItemType Directory -Path $raceStage|Out-Null
    [IO.File]::WriteAllText((Join-Path $raceStage 'full.md'),'# Synthetic result')
    $raceMd=[IO.Path]::ChangeExtension($racePdf,'.md')
    $raceHash=(Get-FileHash -LiteralPath $racePdf -Algorithm SHA256).Hash
    $raceBlocked=& (Get-Module MinerUApiBatch.Core) {
        param($pdf,$stage,$md,$hash)
        $script:RaceMarkdown=$md
        function Get-FileHash {
            param([string]$LiteralPath,[string]$Algorithm)
            if($LiteralPath.EndsWith('.pdf')){[IO.File]::WriteAllText($script:RaceMarkdown,'# User note written during conversion')}
            Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm
        }
        try { Publish-MinerUApiOutput -PdfPath $pdf -StagePath $stage -Model vlm -Language en -BatchId race -SourceSha256 $hash|Out-Null; $false }
        catch { $true }
    } $racePdf $raceStage $raceMd $raceHash
    Assert-True ($raceBlocked -and [IO.File]::ReadAllText($raceMd) -eq '# User note written during conversion') 'Rollback must never delete a user note that appeared during publication.'

    $evilPdf = Join-Path $papers "evil.pdf"
    New-TestPdf -Path $evilPdf -Label "evil"
    $evil = Invoke-Entry @{
        Action = "Convert"; PdfPath = @($evilPdf); ReportPath = (Join-Path $tempRoot "evil.json")
        ApiBase = $apiBase; StateRoot = $stateRoot; IntervalSeconds = 0; TimeoutSeconds = 30; StabilitySeconds = 0
    }
    Assert-True ($evil.summary.failedCount -eq 1) "Unsafe ZIP should fail conversion."
    Assert-True (-not (Test-Path -LiteralPath ([System.IO.Path]::ChangeExtension($evilPdf, ".md")))) "Unsafe ZIP must not publish Markdown."

    if (!(Test-PathWithinForTests $stateRoot $tempRoot)) { throw 'Unsafe fixture cleanup.' }
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
        $authFailed = $_.Exception.Message -match 'authentication was not resolved'
    }
    Assert-True $authFailed "HTTP 401 should request credential replacement."
    $authReport = Get-Content -LiteralPath (Join-Path $tempRoot 'auth.json') -Raw | ConvertFrom-Json
    Assert-True ($authReport.summary.failedCount -eq 1 -and $authReport.fatalError) 'Even an immediate authentication failure writes its report.'

    [pscustomobject]@{
        passed = $true
        checks = $script:checks
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
    if ((Test-Path -LiteralPath $tempRoot) -and [IO.Path]::GetFullPath($tempRoot).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $tempRoot -Leaf) -like 'mineru-api-tests-*') { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
