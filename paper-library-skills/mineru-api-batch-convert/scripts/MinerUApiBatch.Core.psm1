Set-StrictMode -Version Latest

$script:SkillVersion = "2.0.0"
$script:MarkerRegex = '<!--\s*mineru-batch-convert\s+(\{.*\})\s*-->'
$script:MaxFilesPerBatch = 50
$script:MaxFileBytes = 200MB
$script:ImageExtensions = @(
    ".bmp", ".gif", ".jpeg", ".jpg", ".png", ".svg", ".tif", ".tiff", ".webp"
)

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $fullPath = Get-NormalizedPath -Path $Path
    $fullRoot = Get-NormalizedPath -Path $Root
    if ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $prefix = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory)][string]$BaseDirectory,
        [Parameter(Mandatory)][string]$Path
    )

    $base = Get-NormalizedPath -Path $BaseDirectory
    $baseUri = [System.Uri]::new($base + [System.IO.Path]::DirectorySeparatorChar)
    $pathUri = [System.Uri]::new((Get-NormalizedPath -Path $Path))
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString())
}

function Get-MinerULocalDataRoot {
    if ($env:MINERU_API_LOCAL_DATA) {
        return [System.IO.Path]::GetFullPath($env:MINERU_API_LOCAL_DATA)
    }
    $root = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $root) { $root = $env:LOCALAPPDATA }
    if (-not $root) { throw "LOCALAPPDATA is unavailable." }
    return Join-Path $root "Codex\mineru-api-batch-convert"
}

function Get-MinerUApiCredentialPath {
    return Join-Path (Get-MinerULocalDataRoot) "credential.clixml"
}

function Get-MinerUStateRoot {
    param([string]$ExplicitPath)

    if ($ExplicitPath) { return [System.IO.Path]::GetFullPath($ExplicitPath) }
    return Join-Path (Get-MinerULocalDataRoot) "state"
}


function Clear-MinerUApiCredential {
    $path = Get-MinerUApiCredentialPath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
    }
}


function Get-MinerUApiEnvironment {
    $credentialPath = Get-MinerUApiCredentialPath
    $stateRoot = Get-MinerUStateRoot
    $stateCount = if (Test-Path -LiteralPath $stateRoot) {
        @(Get-ChildItem -LiteralPath $stateRoot -File -Filter "*.json" -ErrorAction SilentlyContinue).Count
    }
    else { 0 }

    return [pscustomobject]@{
        skillVersion = $script:SkillVersion
        skillPath = Split-Path -Parent $PSScriptRoot
        windows = $env:OS -eq "Windows_NT"
        powershellVersion = $PSVersionTable.PSVersion.ToString()
        credentialConfigured = (Test-Path -LiteralPath $credentialPath -PathType Leaf) -or (-not [string]::IsNullOrWhiteSpace([string]$env:MINERU_TOKEN))
        credentialPath = $credentialPath
        stateRoot = $stateRoot
        pendingStateCount = $stateCount
        ready = ($env:OS -eq "Windows_NT")
    }
}

function Get-FileSignature {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$IncludeHash
    )

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $signature = [ordered]@{
        length = [int64]$item.Length
        lastWriteUtc = $item.LastWriteTimeUtc.ToString("o")
    }
    if ($IncludeHash) {
        $signature.sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return [pscustomobject]$signature
}


function Read-MinerUMarker {
    param([Parameter(Mandatory)][string]$MarkdownPath)

    $reader = [System.IO.StreamReader]::new($MarkdownPath, $true)
    try {
        $head = New-Object System.Collections.Generic.List[string]
        for ($index = 0; $index -lt 12 -and -not $reader.EndOfStream; $index++) {
            $head.Add($reader.ReadLine())
        }
        $text = $head -join "`n"
    }
    finally {
        $reader.Dispose()
    }
    $match = [regex]::Match($text, $script:MarkerRegex)
    if (-not $match.Success) { return $null }
    try { return ($match.Groups[1].Value | ConvertFrom-Json -ErrorAction Stop) }
    catch { return $null }
}

function Assert-MinerUPlainPath {
    param([Parameter(Mandatory)][string]$Path)

    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Linked paths require manual review.'
        }
        $current = Split-Path -Parent $current
    }
}

function Get-MinerUOwnedPaths {
    param([Parameter(Mandatory)][string]$MarkdownPath, [Parameter(Mandatory)]$Marker)

    foreach ($property in @('schemaVersion','sourcePdf','sourceLength','sourceLastWriteUtc','assetsDirectory','assetCount')) {
        if (!$Marker.PSObject.Properties[$property]) { throw "Incomplete MinerU marker: $property." }
    }
    if ([string]$Marker.schemaVersion -ne '1' -or [string]$Marker.assetCount -notmatch '^\d+$' -or
        [string]$Marker.sourceLength -notmatch '^\d+$') { throw 'Invalid MinerU marker schema or counts.' }
    $null = [int]$Marker.assetCount
    $null = [int64]$Marker.sourceLength
    $null = [datetime]$Marker.sourceLastWriteUtc
    if ($Marker.PSObject.Properties['sourceSha256'] -and $Marker.sourceSha256 -and
        [string]$Marker.sourceSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid source hash in MinerU marker.' }
    $markdown = [IO.Path]::GetFullPath($MarkdownPath)
    $directory = Split-Path -Parent $markdown
    $stem = [IO.Path]::GetFileNameWithoutExtension($markdown)
    if ([IO.Path]::GetExtension($markdown) -ine '.md' -or [string]$Marker.sourcePdf -ine ($stem + '.pdf')) {
        throw 'MinerU marker does not name the matching sibling PDF.'
    }
    $assets = Join-Path $directory ($stem + '.assets')
    if (([int]$Marker.assetCount -gt 0 -and [string]$Marker.assetsDirectory -ine ($stem + '.assets')) -or
        ([int]$Marker.assetCount -eq 0 -and $Marker.assetsDirectory)) {
        throw 'MinerU marker does not name the matching sibling assets directory.'
    }
    $pdf = Join-Path $directory ([string]$Marker.sourcePdf)
    foreach ($path in @($markdown, $pdf, $assets)) { Assert-MinerUPlainPath -Path $path }
    return [pscustomobject]@{ markdownPath=$markdown; pdfPath=$pdf; assetsPath=$assets }
}

function Assert-MinerUOutputAssets {
    param([Parameter(Mandatory)]$Paths, [Parameter(Mandatory)]$Marker)

    $files = @()
    if (Test-Path -LiteralPath $Paths.assetsPath) {
        if (!(Test-Path -LiteralPath $Paths.assetsPath -PathType Container) -or [int]$Marker.assetCount -eq 0) {
            throw 'Unexpected assets path requires review.'
        }
        $entries = @(Get-ChildItem -LiteralPath $Paths.assetsPath -Recurse -Force -ErrorAction Stop)
        foreach ($entry in $entries) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked assets require manual review.' }
        }
        $files = @($entries | Where-Object { !$_.PSIsContainer })
    }
    if ($files.Count -ne [int]$Marker.assetCount) { throw 'Asset file count no longer matches the MinerU marker.' }
    $content = [IO.File]::ReadAllText($Paths.markdownPath)
    $images = Convert-MinerUImageLinks -Content $content -BaseDirectory (Split-Path -Parent $Paths.markdownPath) -AssetsName ([IO.Path]::GetFileName($Paths.assetsPath))
    foreach ($image in $images.images) {
        if (!(Test-PathWithin -Path $image.FullName -Root $Paths.assetsPath)) { throw 'Image is outside the owned assets directory.' }
        Assert-MinerUPlainPath -Path $image.FullName
    }
}

function New-ScanInputs {
    param(
        [string[]]$RootPath,
        [string[]]$PdfPath,
        [switch]$Recurse
    )

    $pdfs = @{}
    $scopes = @{}
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($root in @($RootPath)) {
        if (-not $root) { continue }
        if (-not (Test-Path -LiteralPath $root)) {
            $warnings.Add("Input path does not exist: $root")
            continue
        }
        $item = Get-Item -LiteralPath $root
        if ($item.PSIsContainer) {
            $normalRoot = Get-NormalizedPath -Path $item.FullName
            $scopes[$normalRoot.ToLowerInvariant()] = [pscustomobject]@{
                path = $normalRoot
                recursive = [bool]$Recurse
            }
            $found = Get-ChildItem -LiteralPath $normalRoot -File -Filter "*.pdf" -Recurse:$([bool]$Recurse) -ErrorAction SilentlyContinue
            foreach ($pdf in $found) { $pdfs[$pdf.FullName.ToLowerInvariant()] = $pdf.FullName }
        }
        elseif ($item.Extension -ieq ".pdf") {
            $pdfs[$item.FullName.ToLowerInvariant()] = $item.FullName
        }
        else {
            $warnings.Add("Input is not a directory or PDF: $($item.FullName)")
        }
    }

    foreach ($path in @($PdfPath)) {
        if (-not $path) { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $warnings.Add("PDF path does not exist: $path")
            continue
        }
        $item = Get-Item -LiteralPath $path
        if ($item.Extension -ine ".pdf") {
            $warnings.Add("Explicit input is not a PDF: $($item.FullName)")
            continue
        }
        $pdfs[$item.FullName.ToLowerInvariant()] = $item.FullName
    }

    return [pscustomobject]@{
        pdfs = @($pdfs.Values | Sort-Object)
        scopes = @($scopes.Values | Sort-Object path)
        warnings = $warnings.ToArray()
    }
}

function Get-PdfStatus {
    param([Parameter(Mandatory)][string]$PdfPath)

    $pdf = Get-Item -LiteralPath $PdfPath
    $markdownPath = [System.IO.Path]::ChangeExtension($pdf.FullName, ".md")
    $assetsPath = Join-Path $pdf.DirectoryName ($pdf.BaseName + ".assets")
    if (-not (Test-Path -LiteralPath $markdownPath -PathType Leaf)) {
        $status = if (Test-Path -LiteralPath $assetsPath -PathType Container) { "IncompleteAssets" } else { "Missing" }
        return [pscustomobject]@{
            title = $pdf.BaseName; pdfPath = $pdf.FullName; markdownPath = $markdownPath
            assetsPath = $assetsPath; status = $status; marker = $null
        }
    }

    $marker = Read-MinerUMarker -MarkdownPath $markdownPath
    if ($null -eq $marker) {
        return [pscustomobject]@{
            title = $pdf.BaseName; pdfPath = $pdf.FullName; markdownPath = $markdownPath
            assetsPath = $assetsPath; status = "ExistingUntracked"; marker = $null
        }
    }

    try { $owned = Get-MinerUOwnedPaths -MarkdownPath $markdownPath -Marker $marker }
    catch {
        return [pscustomobject]@{ title=$pdf.BaseName; pdfPath=$pdf.FullName; markdownPath=$markdownPath; assetsPath=$assetsPath; status='InvalidMarker'; marker=$marker; error=$_.Exception.Message }
    }
    try { Assert-MinerUOutputAssets -Paths $owned -Marker $marker }
    catch {
        return [pscustomobject]@{ title=$pdf.BaseName; pdfPath=$pdf.FullName; markdownPath=$markdownPath; assetsPath=$assetsPath; status='IncompleteAssets'; marker=$marker; error=$_.Exception.Message }
    }
    $status = "Current"
    $signature = Get-FileSignature -Path $pdf.FullName
    $sameLength = [int64]$marker.sourceLength -eq [int64]$signature.length
    $sameTime = ([datetime]$marker.sourceLastWriteUtc).ToUniversalTime().Ticks -eq ([datetime]$signature.lastWriteUtc).ToUniversalTime().Ticks
    if (-not ($sameLength -and $sameTime)) {
        if ($marker.PSObject.Properties['sourceSha256'] -and $marker.sourceSha256) {
            $hash = (Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $status = if ($hash -eq [string]$marker.sourceSha256) { "CurrentMetadataChanged" } else { "Stale" }
        }
        else { $status = "Stale" }
    }

    return [pscustomobject]@{
        title = $pdf.BaseName; pdfPath = $pdf.FullName; markdownPath = $markdownPath
        assetsPath = $assetsPath; status = $status; marker = $marker
    }
}

function Get-GeneratedMarkdownFiles {
    param([AllowEmptyCollection()][object[]]$Scopes = @())

    $markdown = @{}
    foreach ($scope in $Scopes) {
        $files = Get-ChildItem -LiteralPath $scope.path -File -Filter "*.md" -Recurse:$([bool]$scope.recursive) -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            if ($null -ne (Read-MinerUMarker -MarkdownPath $file.FullName)) {
                $markdown[$file.FullName.ToLowerInvariant()] = $file.FullName
            }
        }
    }
    return @($markdown.Values | Sort-Object)
}

function Find-RenameCandidate {
    param(
        [Parameter(Mandatory)][string]$MarkdownPath,
        [Parameter(Mandatory)]$Marker
    )

    if (!$Marker.PSObject.Properties['sourceSha256'] -or -not $Marker.sourceSha256 -or -not $Marker.sourceLength) { return $null }
    $directory = Split-Path -Parent $MarkdownPath
    $pdfs = Get-ChildItem -LiteralPath $directory -File -Filter "*.pdf" -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -eq [int64]$Marker.sourceLength }
    foreach ($pdf in $pdfs) {
        $hash = (Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -eq [string]$Marker.sourceSha256) { return $pdf.FullName }
    }
    return $null
}

function New-MinerUScanReport {
    param(
        [string[]]$RootPath,
        [string[]]$PdfPath,
        [switch]$Recurse
    )

    $inputs = New-ScanInputs -RootPath $RootPath -PdfPath $PdfPath -Recurse:$Recurse
    $items = foreach ($pdf in $inputs.pdfs) { Get-PdfStatus -PdfPath $pdf }
    $orphans = New-Object System.Collections.Generic.List[object]
    $renameCandidates = New-Object System.Collections.Generic.List[object]
    $warnings = @($inputs.warnings)
    foreach ($markdownPath in (Get-GeneratedMarkdownFiles -Scopes $inputs.scopes)) {
        $marker = Read-MinerUMarker -MarkdownPath $markdownPath
        try { $owned = Get-MinerUOwnedPaths -MarkdownPath $markdownPath -Marker $marker }
        catch { $warnings += "Review required for ${markdownPath}: $($_.Exception.Message)"; continue }
        $expectedPdf = $owned.pdfPath
        if (Test-Path -LiteralPath $expectedPdf -PathType Leaf) { continue }
        $renamedPdf = Find-RenameCandidate -MarkdownPath $markdownPath -Marker $marker
        $mdSignature = Get-FileSignature -Path $markdownPath
        $entry = [pscustomobject]@{
            title = [System.IO.Path]::GetFileNameWithoutExtension([string]$marker.sourcePdf)
            markdownPath = $markdownPath
            assetsPath = if ($marker.assetsDirectory) { $owned.assetsPath } else { $null }
            expectedPdfPath = $expectedPdf
            renamedPdfPath = $renamedPdf
            markdownLength = $mdSignature.length
            markdownLastWriteUtc = $mdSignature.lastWriteUtc
            marker = $marker
        }
        if ($renamedPdf) { $renameCandidates.Add($entry) } else { $orphans.Add($entry) }
    }

    $summary = [ordered]@{
        pdfCount = @($items).Count
        missingCount = @($items | Where-Object status -eq "Missing").Count
        currentCount = @($items | Where-Object { $_.status -like "Current*" }).Count
        untrackedCount = @($items | Where-Object status -eq "ExistingUntracked").Count
        staleCount = @($items | Where-Object status -eq "Stale").Count
        incompleteCount = @($items | Where-Object status -eq "IncompleteAssets").Count
        invalidMarkerCount = @($items | Where-Object status -eq "InvalidMarker").Count
        orphanCount = $orphans.Count
        renameCandidateCount = $renameCandidates.Count
    }
    return [pscustomobject]@{
        schemaVersion = 1
        skillVersion = $script:SkillVersion
        action = "Scan"
        reportId = [guid]::NewGuid().ToString("N")
        createdUtc = [DateTime]::UtcNow.ToString("o")
        scanScopes = @($inputs.scopes)
        warnings = @($warnings)
        summary = [pscustomobject]$summary
        items = @($items)
        orphans = $orphans.ToArray()
        renameCandidates = $renameCandidates.ToArray()
        conversions = @()
    }
}

function Write-MinerUReport {
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $json = $Report | ConvertTo-Json -Depth 15
    [System.IO.File]::WriteAllText($fullPath, $json, [System.Text.UTF8Encoding]::new($false))
    return $fullPath
}

function Send-ToRecycleBin {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet("File", "Directory")][string]$Kind
    )

    Add-Type -AssemblyName Microsoft.VisualBasic
    $ui = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs
    $recycle = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
    if ($Kind -eq "Directory") {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, $ui, $recycle)
    }
    else {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, $ui, $recycle)
    }
}

function Invoke-MinerURecycle {
    param(
        [Parameter(Mandatory)][string]$ReportPath,
        [Parameter(Mandatory)][switch]$ConfirmRecycle
    )

    if (-not $ConfirmRecycle) { throw "Recycling requires -ConfirmRecycle after the user reviews the orphan report." }
    if ($env:OS -ne "Windows_NT") { throw "Windows Recycle Bin cleanup is supported only on Windows." }
    $report = Get-Content -Raw -LiteralPath $ReportPath -Encoding UTF8 | ConvertFrom-Json
    if ([int]$report.schemaVersion -ne 1) { throw "Unsupported report schema." }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($orphan in @($report.orphans)) {
        try {
            if (-not (Test-Path -LiteralPath $orphan.markdownPath -PathType Leaf)) { throw "Markdown no longer exists." }
            $insideScope = $false
            foreach ($scope in @($report.scanScopes)) {
                if ((Test-PathWithin -Path $orphan.markdownPath -Root $scope.path) -and
                    ($scope.recursive -or (Get-NormalizedPath (Split-Path -Parent $orphan.markdownPath)) -eq (Get-NormalizedPath $scope.path))) { $insideScope = $true; break }
            }
            if (-not $insideScope) { throw "Markdown is outside the original scan scopes." }

            $signature = Get-FileSignature -Path $orphan.markdownPath
            $currentWriteTicks = ([datetime]$signature.lastWriteUtc).ToUniversalTime().Ticks
            $reportedWriteTicks = ([datetime]$orphan.markdownLastWriteUtc).ToUniversalTime().Ticks
            if ([int64]$signature.length -ne [int64]$orphan.markdownLength -or $currentWriteTicks -ne $reportedWriteTicks) {
                throw "Markdown changed after the report was created. Run Scan again."
            }
            $marker = Read-MinerUMarker -MarkdownPath $orphan.markdownPath
            if ($null -eq $marker -or [string]$marker.sourcePdf -ne [string]$orphan.marker.sourcePdf) {
                throw "MinerU ownership marker is missing or changed."
            }
            $owned = Get-MinerUOwnedPaths -MarkdownPath $orphan.markdownPath -Marker $marker
            if ((Get-NormalizedPath $orphan.expectedPdfPath) -ne (Get-NormalizedPath $owned.pdfPath)) { throw 'Reported source path does not match the owned sibling PDF.' }
            $expectedAssetsPath = if ($marker.assetsDirectory) { $owned.assetsPath } else { $null }
            if ([string]$orphan.assetsPath -ine [string]$expectedAssetsPath) { throw 'Reported assets path does not match the owned sibling directory.' }
            if (Test-Path -LiteralPath $owned.pdfPath) {
                throw "The source PDF exists again. Run Scan again."
            }
            if (!$marker.PSObject.Properties['sourceSha256'] -or !$marker.sourceSha256) { throw 'Legacy orphan lacks a source hash for rename verification; review manually.' }
            if (Find-RenameCandidate -MarkdownPath $orphan.markdownPath -Marker $marker) { throw 'A renamed source PDF now exists. Run Scan again.' }
            Assert-MinerUOutputAssets -Paths $owned -Marker $marker

            if ($orphan.assetsPath -and (Test-Path -LiteralPath $orphan.assetsPath -PathType Container)) {
                Send-ToRecycleBin -Path $orphan.assetsPath -Kind Directory
            }
            Send-ToRecycleBin -Path $orphan.markdownPath -Kind File
            $results.Add([pscustomobject]@{ status = "Recycled"; markdownPath = $orphan.markdownPath; assetsPath = $orphan.assetsPath })
        }
        catch {
            $results.Add([pscustomobject]@{ status = "Skipped"; markdownPath = $orphan.markdownPath; assetsPath = $orphan.assetsPath; error = $_.Exception.Message })
        }
    }
    return $results.ToArray()
}

function Get-PrimaryMarkdown {
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$ExpectedBaseName
    )

    $markdown = @(Get-ChildItem -LiteralPath $OutputPath -File -Filter "*.md" -Recurse -ErrorAction SilentlyContinue)
    if ($markdown.Count -eq 0) { return $null }
    $full = @($markdown | Where-Object Name -ieq "full.md")
    if ($full.Count -eq 1) { return $full[0] }
    $exact = @($markdown | Where-Object BaseName -ieq $ExpectedBaseName)
    if ($exact.Count -eq 1) { return $exact[0] }
    return $markdown | Sort-Object Length -Descending | Select-Object -First 1
}

function Expand-MinerUSafeZip {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $root = Get-NormalizedPath -Path $Destination
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrEmpty($entry.FullName)) { continue }
            $target = [System.IO.Path]::GetFullPath((Join-Path $root $entry.FullName))
            if (-not ($target.Equals($root, [System.StringComparison]::OrdinalIgnoreCase) -or $target.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))) {
                throw "Result ZIP contains an unsafe path: $($entry.FullName)"
            }
            if ([string]::IsNullOrEmpty($entry.Name)) {
                New-Item -ItemType Directory -Path $target -Force | Out-Null
                continue
            }
            $directory = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $directory)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
            $input = $entry.Open()
            $output = [System.IO.File]::Open($target, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $input.CopyTo($output) }
            finally { $output.Dispose(); $input.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}

function Convert-MinerUImageLinks {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content,
          [Parameter(Mandatory)][string]$BaseDirectory,
          [Parameter(Mandatory)][string]$AssetsName)

    # Capture just destinations, so filenames mentioned in prose are never rewritten.
    $direct = '!\[[^\]\r\n]*\]\(\s*(?:<(?<url>[^>\r\n]+)>|(?<url>(?:[^\s()]|\([^()\r\n]*\))+))(?:\s+["''][^\r\n]*?["''])?\s*\)'
    $html = '<img\b[^>]*?\bsrc\s*=\s*["''](?<url>[^"'']+)["'']'
    $refs = [Collections.Generic.List[object]]::new()
    foreach ($pattern in @($direct, $html)) {
        foreach ($match in [regex]::Matches($Content, $pattern, 'IgnoreCase')) { $refs.Add($match.Groups['url']) }
    }
    $ids=@{}
    foreach ($match in [regex]::Matches($Content, '!\[(?<alt>[^\]]+)\](?:\[(?<id>[^\]]*)\])?(?!\()', 'IgnoreCase')) {
        $id=if ($match.Groups['id'].Success -and $match.Groups['id'].Value) {$match.Groups['id'].Value} else {$match.Groups['alt'].Value}
        $ids[$id.Trim().ToLowerInvariant()]=$true
    }
    foreach ($match in [regex]::Matches($Content, '(?m)^\s{0,3}\[(?<id>[^\]]+)\]:\s*(?:<(?<url>[^>\r\n]+)>|(?<url>\S+))')) {
        if ($ids.ContainsKey($match.Groups['id'].Value.Trim().ToLowerInvariant())) { $refs.Add($match.Groups['url']) }
    }
    $images=@{}
    foreach ($ref in @($refs | Sort-Object Index -Descending -Unique)) {
        $raw=[Net.WebUtility]::HtmlDecode($ref.Value)
        if ($raw -match '^data:image/') { continue }
        if ($raw -match '^[a-zA-Z][a-zA-Z0-9+.-]*:' -or $raw.StartsWith('//')) { throw 'Result contains a non-local image; local assets are required.' }
        $relative=[Uri]::UnescapeDataString($raw).Replace('/',[IO.Path]::DirectorySeparatorChar)
        if ([IO.Path]::IsPathRooted($relative)) { throw 'Result contains an absolute image path.' }
        $path=[IO.Path]::GetFullPath((Join-Path $BaseDirectory $relative))
        if (!(Test-PathWithin -Path $path -Root $BaseDirectory) -or !(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Result image is missing or outside its artifact directory: $raw" }
        $file=Get-Item -LiteralPath $path
        if ($script:ImageExtensions -notcontains $file.Extension.ToLowerInvariant()) { throw 'Unsupported result image type.' }
        $images[$path]=$file
        $relative=(Get-RelativePath -BaseDirectory $BaseDirectory -Path $path).Replace('\','/')
        $target=(("$AssetsName/$relative" -split '/') | ForEach-Object {
            # .NET Framework uses older URI rules; enforce RFC 3986 for Markdown.
            [Uri]::EscapeDataString($_).Replace('(', '%28').Replace(')', '%29').Replace("'", '%27').Replace('!', '%21').Replace('*', '%2A')
        }) -join '/'
        $Content=$Content.Remove($ref.Index,$ref.Length).Insert($ref.Index,$target)
    }
    return [pscustomobject]@{ content=$Content; images=@($images.Values) }
}

function Publish-MinerUApiOutput {
    param(
        [Parameter(Mandatory)][string]$PdfPath,
        [Parameter(Mandatory)][string]$StagePath,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Language,
        [Parameter(Mandatory)][string]$BatchId,
        [Parameter(Mandatory)][string]$SourceSha256,
        [switch]$AllowReplaceStale
    )

    $pdf = Get-Item -LiteralPath $PdfPath -ErrorAction Stop
    $markdownPath = [System.IO.Path]::ChangeExtension($pdf.FullName, ".md")
    $assetsName = $pdf.BaseName + ".assets"
    $assetsPath = Join-Path $pdf.DirectoryName $assetsName
    foreach ($path in @($pdf.FullName, $markdownPath, $assetsPath)) { Assert-MinerUPlainPath -Path $path }
    $existingMarker = $null
    $existingMarkdownHash = $null
    if (Test-Path -LiteralPath $markdownPath -PathType Leaf) {
        $existingStatus = Get-PdfStatus -PdfPath $pdf.FullName
        if (!$AllowReplaceStale -or $existingStatus.status -ne 'Stale') {
            throw "Existing output ($($existingStatus.status)) requires review and explicit stale-replacement consent; output preserved."
        }
        $existingMarker = $existingStatus.marker
        $existingMarkdownHash = (Get-FileHash -LiteralPath $markdownPath -Algorithm SHA256).Hash
    }
    elseif (Test-Path -LiteralPath $assetsPath -PathType Container) {
        throw "Untracked assets directory exists; refusing to overwrite: $assetsPath"
    }

    $primary = Get-PrimaryMarkdown -OutputPath $StagePath -ExpectedBaseName $pdf.BaseName
    if ($null -eq $primary) { throw "MinerU produced no Markdown for: $($pdf.FullName)" }
    $content = [System.IO.File]::ReadAllText($primary.FullName)
    if ([string]::IsNullOrWhiteSpace($content)) { throw 'MinerU produced empty Markdown.' }
    $normalized = Convert-MinerUImageLinks -Content $content -BaseDirectory $primary.DirectoryName -AssetsName $assetsName
    $images = @($normalized.images)
    $content = $normalized.content

    $publishRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("mineru-api-publish-" + [guid]::NewGuid().ToString("N"))
    $publishAssets = Join-Path $publishRoot $assetsName
    $publishMarkdown = Join-Path $publishRoot ($pdf.BaseName + ".md")
    New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null
    try {
        if ($images.Count -gt 0) {
            New-Item -ItemType Directory -Path $publishAssets -Force | Out-Null
            foreach ($image in $images) {
                $relative = (Get-RelativePath -BaseDirectory $primary.DirectoryName -Path $image.FullName).Replace("/", [System.IO.Path]::DirectorySeparatorChar)
                $destination = Join-Path $publishAssets $relative
                $destinationDirectory = Split-Path -Parent $destination
                if (-not (Test-Path -LiteralPath $destinationDirectory)) {
                    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
                }
                Copy-Item -LiteralPath $image.FullName -Destination $destination
            }
        }

        $source = Get-FileSignature -Path $pdf.FullName
        $marker = [ordered]@{
            schemaVersion = 1
            skillVersion = $script:SkillVersion
            provider = "api"
            sourcePdf = $pdf.Name
            sourceLength = $source.length
            sourceLastWriteUtc = $source.lastWriteUtc
            sourceSha256 = $SourceSha256
            assetsDirectory = if ($images.Count -gt 0) { $assetsName } else { $null }
            assetCount = $images.Count
            backend = "api"
            effort = $Model
            apiModel = $Model
            language = $Language
            batchId = $BatchId
            convertedUtc = [DateTime]::UtcNow.ToString("o")
        }
        $markerLine = "<!-- mineru-batch-convert $($marker | ConvertTo-Json -Compress) -->"
        [System.IO.File]::WriteAllText($publishMarkdown, $markerLine + "`r`n" + $content, [System.Text.UTF8Encoding]::new($false))

        $currentHash = (Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($currentHash -ne $SourceSha256) { throw "PDF changed during conversion: $($pdf.FullName)" }

        $token = [guid]::NewGuid().ToString("N")
        $partialMarkdown = $markdownPath + ".mineru-partial-" + $token
        $partialAssets = $assetsPath + ".mineru-partial-" + $token
        $backupMarkdown = $markdownPath + ".mineru-backup-" + $token
        $backupAssets = $assetsPath + ".mineru-backup-" + $token
        Copy-Item -LiteralPath $publishMarkdown -Destination $partialMarkdown
        if ($images.Count -gt 0) { Copy-Item -LiteralPath $publishAssets -Destination $partialAssets -Recurse }

        $movedOldMarkdown = $false
        $movedOldAssets = $false
        $publishedMarkdown = $false
        $publishedAssets = $false
        try {
            if (Test-Path -LiteralPath $markdownPath -PathType Leaf) {
                $checkMarker = Read-MinerUMarker -MarkdownPath $markdownPath
                if ($null -eq $checkMarker -or !$existingMarkdownHash -or (Get-FileHash -LiteralPath $markdownPath -Algorithm SHA256).Hash -ne $existingMarkdownHash) { throw "Markdown changed during conversion: $markdownPath" }
                Move-Item -LiteralPath $markdownPath -Destination $backupMarkdown
                $movedOldMarkdown = $true
            }
            if (Test-Path -LiteralPath $assetsPath -PathType Container) {
                if (-not $movedOldMarkdown) { throw "Assets appeared without tracked Markdown: $assetsPath" }
                $null = Get-MinerUOwnedPaths -MarkdownPath $markdownPath -Marker $existingMarker
                Move-Item -LiteralPath $assetsPath -Destination $backupAssets
                $movedOldAssets = $true
            }
            if ($images.Count -gt 0) { Move-Item -LiteralPath $partialAssets -Destination $assetsPath; $publishedAssets=$true }
            Move-Item -LiteralPath $partialMarkdown -Destination $markdownPath
            $publishedMarkdown=$true
        }
        catch {
            if ($publishedMarkdown -and (Test-Path -LiteralPath $markdownPath)) { Remove-Item -LiteralPath $markdownPath -Force }
            if ($publishedAssets -and (Test-Path -LiteralPath $assetsPath)) {
                if ((Get-NormalizedPath (Split-Path -Parent $assetsPath)) -ne (Get-NormalizedPath $pdf.DirectoryName)) { throw 'Unsafe rollback assets path.' }
                Assert-MinerUPlainPath -Path $assetsPath
                Remove-Item -LiteralPath $assetsPath -Recurse -Force
            }
            if ($movedOldMarkdown -and (Test-Path -LiteralPath $backupMarkdown)) { Move-Item -LiteralPath $backupMarkdown -Destination $markdownPath }
            if ($movedOldAssets -and (Test-Path -LiteralPath $backupAssets)) { Move-Item -LiteralPath $backupAssets -Destination $assetsPath }
            throw
        }
        finally {
            if (Test-Path -LiteralPath $partialMarkdown) { Remove-Item -LiteralPath $partialMarkdown -Force }
            if (Test-Path -LiteralPath $partialAssets) {
                if ((Get-NormalizedPath (Split-Path -Parent $partialAssets)) -ne (Get-NormalizedPath $pdf.DirectoryName)) { throw 'Unsafe partial assets path.' }
                Assert-MinerUPlainPath -Path $partialAssets
                Remove-Item -LiteralPath $partialAssets -Recurse -Force
            }
        }

        if (Test-Path -LiteralPath $backupAssets) { Send-ToRecycleBin -Path $backupAssets -Kind Directory }
        if (Test-Path -LiteralPath $backupMarkdown) { Send-ToRecycleBin -Path $backupMarkdown -Kind File }

        return [pscustomobject]@{
            status = "Converted"
            pdfPath = $pdf.FullName
            markdownPath = $markdownPath
            assetsPath = if ($images.Count -gt 0) { $assetsPath } else { $null }
            assetCount = $images.Count
            batchId = $BatchId
        }
    }
    finally {
        if ((Test-Path -LiteralPath $publishRoot) -and (Test-PathWithin -Path $publishRoot -Root ([IO.Path]::GetTempPath())) -and
            (Split-Path -Leaf $publishRoot) -like 'mineru-api-publish-*') {
            Assert-MinerUPlainPath -Path $publishRoot
            Remove-Item -LiteralPath $publishRoot -Recurse -Force
        }
    }
}

function New-MinerUAuthException {
    param([Parameter(Mandatory)][string]$Message)

    $exception = [System.UnauthorizedAccessException]::new($Message)
    $exception.Data["MinerUAuthFailure"] = $true
    $exception.Data['MinerUSubmissionRejected'] = $true
    return $exception
}

function Invoke-MinerUApiRequestOnce {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Token,
        [ValidateSet("GET", "POST")][string]$Method = "GET",
        $Body
    )

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch { }
    $headers = @{ Authorization = "Bearer $Token"; Accept = "*/*" }
    try {
        if ($Method -eq "POST") {
            $json = $Body | ConvertTo-Json -Depth 10 -Compress
            $response = Invoke-RestMethod -Uri $Uri -Method Post -Headers $headers -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 60
        }
        else {
            $response = Invoke-RestMethod -Uri $Uri -Method Get -Headers $headers -TimeoutSec 60
        }
    }
    catch {
        $status = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        $quotaResponse = $_.ErrorDetails -and $_.ErrorDetails.Message -match '(?i)quota|rate.?limit|too many requests|daily.?limit|insufficient.?credits'
        if (($status -eq 401 -or $status -eq 403) -and !$quotaResponse) {
            throw (New-MinerUAuthException -Message "MinerU authentication failed with HTTP $status.")
        }
        $exception = [InvalidOperationException]::new("MinerU API request failed (HTTP $status). Check connectivity, quota, or service availability.")
        if ($status -in @(400, 402, 404, 413, 415, 422, 429) -or ($status -eq 403 -and $quotaResponse)) {
            $exception.Data['MinerUSubmissionRejected'] = $true
        }
        throw $exception
    }

    if ($null -ne $response.code -and [string]$response.code -ne '0') {
        $message = [string]$response.msg
        if ($message -match '(?i)((invalid|expired|revoked|missing)\s+(api\s+)?token|token\s+(is\s+)?(invalid|expired|revoked)|unauthori[sz]ed|authentication\s+failed)') {
            throw (New-MinerUAuthException -Message "MinerU rejected the API token (code $($response.code)).")
        }
        $exception = [InvalidOperationException]::new('MinerU API returned an unsuccessful response. Check request parameters, quota, or service availability.')
        if ($message -match '(?i)quota|rate.?limit|too many requests|daily.?limit|insufficient.?credits|invalid\s+(parameter|request|file)|validation\s+failed|file\s+too\s+large') {
            $exception.Data['MinerUSubmissionRejected'] = $true
        }
        throw $exception
    }
    return $response.data
}

function Send-MinerUUpload {
    param(
        [Parameter(Mandatory)][string]$SignedUrl,
        [Parameter(Mandatory)][string]$FilePath
    )

    Add-Type -AssemblyName System.Net.Http
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(10)
    $stream = [System.IO.File]::OpenRead($FilePath)
    $content = [System.Net.Http.StreamContent]::new($stream)
    $content.Headers.ContentLength = $stream.Length
    try {
        $response = $client.PutAsync($SignedUrl, $content).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) {
                throw "Upload failed with HTTP $([int]$response.StatusCode)."
            }
        }
        finally { $response.Dispose() }
    }
    finally {
        $content.Dispose()
        $stream.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

function Receive-MinerUBinary {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination
    )

    Add-Type -AssemblyName System.Net.Http
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(10)
    try {
        $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) { throw "Download failed with HTTP $([int]$response.StatusCode)." }
            $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $output = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $input.CopyTo($output) }
            finally { $output.Dispose(); $input.Dispose() }
        }
        finally { $response.Dispose() }
    }
    finally { $client.Dispose(); $handler.Dispose() }
}

function New-MinerUDataId {
    param([int]$Index, [string]$Stem)

    $cleaned = [regex]::Replace($Stem, '[^A-Za-z0-9_.-]', '-')
    $value = ("{0:D3}-{1}" -f $Index, $cleaned)
    if ($value.Length -gt 128) { $value = $value.Substring(0, 128) }
    return $value
}


function Get-MinerUPendingStates {
    param([string]$StateRoot)

    $root = Get-MinerUStateRoot -ExplicitPath $StateRoot
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $states = New-Object System.Collections.Generic.List[object]
    foreach ($file in (Get-ChildItem -LiteralPath $root -File -Filter "*.json" -ErrorAction SilentlyContinue)) {
        try {
            $state = Get-Content -Raw -LiteralPath $file.FullName -Encoding UTF8 | ConvertFrom-Json
            $state | Add-Member -NotePropertyName statePath -NotePropertyValue $file.FullName -Force
            $states.Add($state)
        }
        catch {
            throw "Unreadable MinerU state file; review it before submitting more work: $($file.FullName)"
        }
    }
    return $states.ToArray()
}

. (Join-Path $PSScriptRoot 'MinerUApiBatch.Credentials.ps1')
. (Join-Path $PSScriptRoot 'MinerUApiBatch.Workflow.ps1')

Export-ModuleMember -Function @(
    "Clear-MinerUApiCredential",
    "Get-MinerUApiCredentialPath",
    "Get-MinerUApiEnvironment",
    "Get-MinerUApiToken",
    "Get-MinerURunTiming",
    "Invoke-MinerUApiConversions",
    "Invoke-MinerURecycle",
    "New-MinerUScanReport",
    "Set-MinerUApiCredential",
    "Write-MinerUReport"
)
