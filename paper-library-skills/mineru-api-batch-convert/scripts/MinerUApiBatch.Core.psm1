Set-StrictMode -Version Latest

$script:SkillVersion = "1.0.2"
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

function Set-MinerUApiCredential {
    param([Security.SecureString]$Token)

    if ($env:OS -ne "Windows_NT") {
        throw "DPAPI credential storage is supported only on Windows."
    }
    if ($null -eq $Token) {
        $Token = Read-Host "Enter MinerU API token" -AsSecureString
    }
    $credential = [PSCredential]::new("mineru-api", $Token)
    $plain = $credential.GetNetworkCredential().Password
    if ([string]::IsNullOrWhiteSpace($plain)) { throw "The API token cannot be empty." }

    $path = Get-MinerUApiCredentialPath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $credential | Export-Clixml -LiteralPath $path -Force
    return $path
}

function Clear-MinerUApiCredential {
    $path = Get-MinerUApiCredentialPath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Get-MinerUApiToken {
    $environmentToken = [string]$env:MINERU_TOKEN
    if (-not [string]::IsNullOrWhiteSpace($environmentToken)) {
        return $environmentToken.Trim()
    }

    $path = Get-MinerUApiCredentialPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "No MinerU API token is configured. Run Invoke-MinerUApiBatch.ps1 -Action Configure."
    }
    try {
        $credential = Import-Clixml -LiteralPath $path
        $token = $credential.GetNetworkCredential().Password
    }
    catch {
        throw "The saved MinerU API credential cannot be decrypted for this Windows user. Run -Action Configure."
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "The saved MinerU API credential is empty. Run -Action Configure."
    }
    return $token
}

function Get-MinerUApiEnvironment {
    $credentialPath = Get-MinerUApiCredentialPath
    $stateRoot = Get-MinerUStateRoot
    $stateCount = if (Test-Path -LiteralPath $stateRoot) {
        @(Get-ChildItem -LiteralPath $stateRoot -File -Filter "*.json" -ErrorAction SilentlyContinue).Count
    }
    else { 0 }

    return [pscustomobject]@{
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

function Wait-ReadableStableFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutSeconds = 120,
        [int]$StabilitySeconds = 2
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $previous = $null
    $stableSince = $null
    $lastError = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $item = Get-Item -LiteralPath $Path -ErrorAction Stop
            $stream = [System.IO.File]::Open(
                $item.FullName,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite
            )
            $stream.Dispose()
            $current = "$($item.Length)|$($item.LastWriteTimeUtc.Ticks)"
            if ($current -eq $previous) {
                if ($null -eq $stableSince) { $stableSince = [DateTime]::UtcNow }
                if (([DateTime]::UtcNow - $stableSince).TotalSeconds -ge $StabilitySeconds) {
                    return $true
                }
            }
            else {
                $previous = $current
                $stableSince = [DateTime]::UtcNow
            }
            $lastError = $null
        }
        catch {
            $lastError = $_.Exception.Message
            $stableSince = $null
        }
        Start-Sleep -Milliseconds 500
    }
    $detail = if ($lastError) { " Last error: $lastError" } else { "" }
    throw "File did not become readable and stable within $TimeoutSeconds seconds: $Path.$detail"
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

    $status = "Current"
    if ([string]$marker.sourcePdf -ine $pdf.Name) {
        $status = "MismatchedMarker"
    }
    elseif ($marker.assetCount -gt 0 -and -not (Test-Path -LiteralPath $assetsPath -PathType Container)) {
        $status = "IncompleteAssets"
    }
    else {
        $signature = Get-FileSignature -Path $pdf.FullName
        $sameLength = [int64]$marker.sourceLength -eq [int64]$signature.length
        $sameTime = [string]$marker.sourceLastWriteUtc -eq [string]$signature.lastWriteUtc
        if (-not ($sameLength -and $sameTime)) {
            if ($marker.sourceSha256) {
                $hash = (Get-FileHash -LiteralPath $pdf.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                $status = if ($hash -eq [string]$marker.sourceSha256) { "CurrentMetadataChanged" } else { "Stale" }
            }
            else { $status = "Stale" }
        }
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

    if (-not $Marker.sourceSha256 -or -not $Marker.sourceLength) { return $null }
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
    foreach ($markdownPath in (Get-GeneratedMarkdownFiles -Scopes $inputs.scopes)) {
        $marker = Read-MinerUMarker -MarkdownPath $markdownPath
        $expectedPdf = Join-Path (Split-Path -Parent $markdownPath) ([string]$marker.sourcePdf)
        if (Test-Path -LiteralPath $expectedPdf -PathType Leaf) { continue }
        $renamedPdf = Find-RenameCandidate -MarkdownPath $markdownPath -Marker $marker
        $mdSignature = Get-FileSignature -Path $markdownPath
        $entry = [pscustomobject]@{
            title = [System.IO.Path]::GetFileNameWithoutExtension([string]$marker.sourcePdf)
            markdownPath = $markdownPath
            assetsPath = if ($marker.assetsDirectory) { Join-Path (Split-Path -Parent $markdownPath) ([string]$marker.assetsDirectory) } else { $null }
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
        warnings = @($inputs.warnings)
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
    $report = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
    if ([int]$report.schemaVersion -ne 1) { throw "Unsupported report schema." }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($orphan in @($report.orphans)) {
        try {
            if (-not (Test-Path -LiteralPath $orphan.markdownPath -PathType Leaf)) { throw "Markdown no longer exists." }
            $insideScope = $false
            foreach ($scope in @($report.scanScopes)) {
                if (Test-PathWithin -Path $orphan.markdownPath -Root $scope.path) { $insideScope = $true; break }
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
            if (Test-Path -LiteralPath $orphan.expectedPdfPath -PathType Leaf) {
                throw "The source PDF exists again. Run Scan again."
            }

            if ($orphan.assetsPath -and (Test-Path -LiteralPath $orphan.assetsPath -PathType Container)) {
                $expectedAssets = Join-Path (Split-Path -Parent $orphan.markdownPath) ([string]$marker.assetsDirectory)
                if ((Get-NormalizedPath -Path $expectedAssets) -ne (Get-NormalizedPath -Path $orphan.assetsPath)) {
                    throw "Assets path does not match the Markdown marker."
                }
                $actualAssetCount = @(Get-ChildItem -LiteralPath $orphan.assetsPath -File -Recurse -ErrorAction Stop).Count
                if ($actualAssetCount -ne [int]$marker.assetCount) {
                    throw "Assets changed after conversion; refusing to recycle them."
                }
            }

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
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][object[]]$Images,
        [Parameter(Mandatory)][string]$BaseDirectory,
        [Parameter(Mandatory)][string]$AssetsName
    )

    $replacements = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($image in $Images) {
        $relative = (Get-RelativePath -BaseDirectory $BaseDirectory -Path $image.FullName).Replace("\", "/")
        $target = [System.Uri]::EscapeUriString("$AssetsName/$relative")
        $encodedRelative = [System.Uri]::EscapeUriString($relative)
        $variants = @("./$relative", $relative, "./$encodedRelative", $encodedRelative) | Sort-Object Length -Descending -Unique
        foreach ($variant in $variants) {
            if ([string]::IsNullOrEmpty($variant) -or -not $Content.Contains($variant)) { continue }
            $placeholder = "__MINERU_ASSET_$($index)_$([guid]::NewGuid().ToString('N'))__"
            $Content = $Content.Replace($variant, $placeholder)
            $replacements.Add([pscustomobject]@{ placeholder = $placeholder; target = $target })
            $index++
        }
    }
    foreach ($replacement in $replacements) {
        $Content = $Content.Replace($replacement.placeholder, $replacement.target)
    }
    return $Content
}

function Publish-MinerUApiOutput {
    param(
        [Parameter(Mandatory)][string]$PdfPath,
        [Parameter(Mandatory)][string]$StagePath,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Language,
        [Parameter(Mandatory)][string]$BatchId,
        [Parameter(Mandatory)][string]$SourceSha256
    )

    $pdf = Get-Item -LiteralPath $PdfPath -ErrorAction Stop
    $markdownPath = [System.IO.Path]::ChangeExtension($pdf.FullName, ".md")
    $assetsName = $pdf.BaseName + ".assets"
    $assetsPath = Join-Path $pdf.DirectoryName $assetsName
    $existingMarker = $null
    if (Test-Path -LiteralPath $markdownPath -PathType Leaf) {
        $existingMarker = Read-MinerUMarker -MarkdownPath $markdownPath
        if ($null -eq $existingMarker) { throw "Untracked Markdown exists; refusing to overwrite: $markdownPath" }
    }
    elseif (Test-Path -LiteralPath $assetsPath -PathType Container) {
        throw "Untracked assets directory exists; refusing to overwrite: $assetsPath"
    }

    $primary = Get-PrimaryMarkdown -OutputPath $StagePath -ExpectedBaseName $pdf.BaseName
    if ($null -eq $primary) { throw "MinerU produced no Markdown for: $($pdf.FullName)" }
    $content = [System.IO.File]::ReadAllText($primary.FullName)
    $images = @(Get-ChildItem -LiteralPath $primary.DirectoryName -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $script:ImageExtensions -contains $_.Extension.ToLowerInvariant() })
    $content = Convert-MinerUImageLinks -Content $content -Images $images -BaseDirectory $primary.DirectoryName -AssetsName $assetsName

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
        try {
            if (Test-Path -LiteralPath $markdownPath -PathType Leaf) {
                $checkMarker = Read-MinerUMarker -MarkdownPath $markdownPath
                if ($null -eq $checkMarker) { throw "Markdown ownership changed during conversion: $markdownPath" }
                Move-Item -LiteralPath $markdownPath -Destination $backupMarkdown
                $movedOldMarkdown = $true
            }
            if (Test-Path -LiteralPath $assetsPath -PathType Container) {
                if (-not $movedOldMarkdown) { throw "Assets appeared without tracked Markdown: $assetsPath" }
                Move-Item -LiteralPath $assetsPath -Destination $backupAssets
                $movedOldAssets = $true
            }
            if ($images.Count -gt 0) { Move-Item -LiteralPath $partialAssets -Destination $assetsPath }
            Move-Item -LiteralPath $partialMarkdown -Destination $markdownPath
        }
        catch {
            if (Test-Path -LiteralPath $markdownPath) { Remove-Item -LiteralPath $markdownPath -Force }
            if (Test-Path -LiteralPath $assetsPath) { Remove-Item -LiteralPath $assetsPath -Recurse -Force }
            if ($movedOldMarkdown -and (Test-Path -LiteralPath $backupMarkdown)) { Move-Item -LiteralPath $backupMarkdown -Destination $markdownPath }
            if ($movedOldAssets -and (Test-Path -LiteralPath $backupAssets)) { Move-Item -LiteralPath $backupAssets -Destination $assetsPath }
            throw
        }
        finally {
            if (Test-Path -LiteralPath $partialMarkdown) { Remove-Item -LiteralPath $partialMarkdown -Force }
            if (Test-Path -LiteralPath $partialAssets) { Remove-Item -LiteralPath $partialAssets -Recurse -Force }
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
        if (Test-Path -LiteralPath $publishRoot) { Remove-Item -LiteralPath $publishRoot -Recurse -Force }
    }
}

function New-MinerUAuthException {
    param([Parameter(Mandatory)][string]$Message)

    $exception = [System.UnauthorizedAccessException]::new($Message)
    $exception.Data["MinerUAuthFailure"] = $true
    return $exception
}

function Invoke-MinerUApiRequest {
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
            $response = Invoke-RestMethod -Uri $Uri -Method Post -Headers $headers -ContentType "application/json" -Body $json -TimeoutSec 60
        }
        else {
            $response = Invoke-RestMethod -Uri $Uri -Method Get -Headers $headers -TimeoutSec 60
        }
    }
    catch {
        $status = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if ($status -eq 401 -or $status -eq 403) {
            throw (New-MinerUAuthException -Message "MinerU authentication failed with HTTP $status.")
        }
        $message = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $message = $_.ErrorDetails.Message }
        if ($message.Length -gt 500) { $message = $message.Substring(0, 500) }
        throw "MinerU request failed at $Uri. HTTP $status. $message"
    }

    if ($null -ne $response.code -and [int]$response.code -ne 0) {
        $message = [string]$response.msg
        if ($message -match '(?i)token|unauthori[sz]ed|forbidden|authenticat|expired') {
            throw (New-MinerUAuthException -Message "MinerU rejected the API token (code $($response.code)).")
        }
        throw "MinerU API error code=$($response.code) msg=$message"
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
                $detail = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) }
                throw "Upload failed with HTTP $([int]$response.StatusCode): $detail"
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
        $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
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

function Save-MinerUBatchState {
    param(
        [Parameter(Mandatory)]$State,
        [string]$StateRoot
    )

    $root = Get-MinerUStateRoot -ExplicitPath $StateRoot
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $path = Join-Path $root ($State.batchId + ".json")
    $json = $State | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Get-MinerUPendingStates {
    param([string]$StateRoot)

    $root = Get-MinerUStateRoot -ExplicitPath $StateRoot
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $states = New-Object System.Collections.Generic.List[object]
    foreach ($file in (Get-ChildItem -LiteralPath $root -File -Filter "*.json" -ErrorAction SilentlyContinue)) {
        try {
            $state = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
            $state | Add-Member -NotePropertyName statePath -NotePropertyValue $file.FullName -Force
            $states.Add($state)
        }
        catch {
            Write-Warning "Ignoring unreadable MinerU state file: $($file.FullName)"
        }
    }
    return $states.ToArray()
}

function Start-MinerUApiBatch {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$ApiBase,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Language,
        [switch]$Ocr,
        [string]$PageRanges,
        [int]$OneDriveTimeoutSeconds,
        [int]$StabilitySeconds,
        [string]$StateRoot
    )

    if ($Items.Count -gt $script:MaxFilesPerBatch) { throw "A MinerU batch cannot exceed $($script:MaxFilesPerBatch) files." }
    $fileEntries = New-Object System.Collections.Generic.List[object]
    $stateItems = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $Items.Count; $index++) {
        $item = $Items[$index]
        Wait-ReadableStableFile -Path $item.pdfPath -TimeoutSeconds $OneDriveTimeoutSeconds -StabilitySeconds $StabilitySeconds | Out-Null
        $pdf = Get-Item -LiteralPath $item.pdfPath
        if ($pdf.Length -gt $script:MaxFileBytes) { throw "PDF exceeds 200 MB: $($pdf.FullName)" }
        $signature = Get-FileSignature -Path $pdf.FullName -IncludeHash
        $dataId = New-MinerUDataId -Index $index -Stem $pdf.BaseName
        $entry = [ordered]@{ name = $pdf.Name; data_id = $dataId; is_ocr = [bool]$Ocr }
        if ($PageRanges) { $entry.page_ranges = $PageRanges }
        $fileEntries.Add([pscustomobject]$entry)
        $stateItems.Add([pscustomobject]@{
            dataId = $dataId
            pdfPath = $pdf.FullName
            sourceLength = $signature.length
            sourceLastWriteUtc = $signature.lastWriteUtc
            sourceSha256 = $signature.sha256
        })
    }

    $payload = [ordered]@{
        files = $fileEntries.ToArray()
        model_version = $Model
        language = $Language
        enable_formula = $true
        enable_table = $true
    }
    $base = $ApiBase.TrimEnd('/')
    $data = Invoke-MinerUApiRequest -Uri "$base/file-urls/batch" -Token $Token -Method POST -Body $payload
    $urls = @($data.file_urls)
    if ($urls.Count -ne $Items.Count) { throw "MinerU returned $($urls.Count) upload URLs for $($Items.Count) files." }
    for ($index = 0; $index -lt $Items.Count; $index++) {
        Send-MinerUUpload -SignedUrl $urls[$index] -FilePath $stateItems[$index].pdfPath
        $afterHash = (Get-FileHash -LiteralPath $stateItems[$index].pdfPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($afterHash -ne [string]$stateItems[$index].sourceSha256) {
            throw "PDF changed while it was being uploaded: $($stateItems[$index].pdfPath)"
        }
    }

    $state = [pscustomobject]@{
        schemaVersion = 1
        skillVersion = $script:SkillVersion
        batchId = [string]$data.batch_id
        apiBase = $base
        model = $Model
        language = $Language
        createdUtc = [DateTime]::UtcNow.ToString("o")
        items = $stateItems.ToArray()
    }
    $statePath = Save-MinerUBatchState -State $state -StateRoot $StateRoot
    $state | Add-Member -NotePropertyName statePath -NotePropertyValue $statePath -Force
    return $state
}

function Wait-MinerUApiBatch {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Token,
        [int]$IntervalSeconds,
        [int]$TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $uri = "$($State.apiBase)/extract-results/batch/$($State.batchId)"
        $data = Invoke-MinerUApiRequest -Uri $uri -Token $Token
        $results = @($data.extract_result)
        $states = @($results | ForEach-Object { [string]$_.state })
        $pending = @($states | Where-Object { $_ -notin @("done", "failed") })
        if ($results.Count -gt 0 -and $pending.Count -eq 0) { return $results }
        if ($IntervalSeconds -gt 0) { Start-Sleep -Seconds $IntervalSeconds }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "MinerU batch $($State.batchId) did not finish within $TimeoutSeconds seconds. It remains available for resume."
}

function Complete-MinerUApiBatch {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Token,
        [int]$IntervalSeconds,
        [int]$TimeoutSeconds,
        [switch]$Resumed
    )

    $results = Wait-MinerUApiBatch -State $State -Token $Token -IntervalSeconds $IntervalSeconds -TimeoutSeconds $TimeoutSeconds
    $byId = @{}
    foreach ($item in @($State.items)) { $byId[[string]$item.dataId] = $item }
    $conversions = New-Object System.Collections.Generic.List[object]
    $retryNeeded = $false
    foreach ($result in $results) {
        $dataId = [string]$result.data_id
        $source = $byId[$dataId]
        if ($null -eq $source) { continue }
        if ([string]$result.state -ne "done") {
            $conversions.Add([pscustomobject]@{
                status = "Failed"; pdfPath = $source.pdfPath; batchId = $State.batchId
                resumed = [bool]$Resumed; error = [string]$result.err_msg
            })
            continue
        }

        $stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("mineru-api-stage-" + [guid]::NewGuid().ToString("N"))
        $zipPath = Join-Path $stageRoot "result.zip"
        $extractPath = Join-Path $stageRoot "result"
        New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
        try {
            if (-not (Test-Path -LiteralPath $source.pdfPath -PathType Leaf)) { throw "Source PDF no longer exists." }
            $currentHash = (Get-FileHash -LiteralPath $source.pdfPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($currentHash -ne [string]$source.sourceSha256) { throw "Source PDF changed after upload." }
            Receive-MinerUBinary -Uri ([string]$result.full_zip_url) -Destination $zipPath
            Expand-MinerUSafeZip -ZipPath $zipPath -Destination $extractPath
            $published = Publish-MinerUApiOutput `
                -PdfPath $source.pdfPath `
                -StagePath $extractPath `
                -Model ([string]$State.model) `
                -Language ([string]$State.language) `
                -BatchId ([string]$State.batchId) `
                -SourceSha256 ([string]$source.sourceSha256)
            $published | Add-Member -NotePropertyName resumed -NotePropertyValue ([bool]$Resumed)
            $conversions.Add($published)
        }
        catch {
            $retryNeeded = $true
            $conversions.Add([pscustomobject]@{
                status = "Failed"; pdfPath = $source.pdfPath; batchId = $State.batchId
                resumed = [bool]$Resumed; error = $_.Exception.Message
            })
        }
        finally {
            if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
        }
    }
    if (-not $retryNeeded -and $State.statePath -and (Test-Path -LiteralPath $State.statePath)) {
        Remove-Item -LiteralPath $State.statePath -Force
    }
    return $conversions.ToArray()
}

function Invoke-MinerUApiConversions {
    param(
        [Parameter(Mandatory)]$ScanReport,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$ApiBase,
        [ValidateSet("vlm", "pipeline")][string]$Model = "vlm",
        [string]$Language = "en",
        [switch]$Ocr,
        [string]$PageRanges,
        [ValidateRange(1, 50)][int]$BatchSize = 20,
        [int]$IntervalSeconds = 10,
        [int]$TimeoutSeconds = 1800,
        [int]$OneDriveTimeoutSeconds = 120,
        [int]$StabilitySeconds = 2,
        [string]$StateRoot
    )

    $allResults = New-Object System.Collections.Generic.List[object]
    $pendingPaths = @{}
    foreach ($state in (Get-MinerUPendingStates -StateRoot $StateRoot)) {
        foreach ($stateItem in @($state.items)) { $pendingPaths[[string]$stateItem.pdfPath.ToLowerInvariant()] = $true }
        try {
            $completed = Complete-MinerUApiBatch -State $state -Token $Token -IntervalSeconds $IntervalSeconds -TimeoutSeconds $TimeoutSeconds -Resumed
            foreach ($result in $completed) { $allResults.Add($result) }
        }
        catch {
            if ($_.Exception.Data["MinerUAuthFailure"]) { throw }
            foreach ($stateItem in @($state.items)) {
                $allResults.Add([pscustomobject]@{
                    status = "Failed"; pdfPath = $stateItem.pdfPath; batchId = $state.batchId
                    resumed = $true; error = $_.Exception.Message
                })
            }
        }
    }

    $candidates = @($ScanReport.items | Where-Object { $_.status -in @("Missing", "Stale", "IncompleteAssets") })
    $candidates = @($candidates | Where-Object { -not $pendingPaths.ContainsKey([string]$_.pdfPath.ToLowerInvariant()) })
    for ($offset = 0; $offset -lt $candidates.Count; $offset += $BatchSize) {
        $last = [Math]::Min($offset + $BatchSize - 1, $candidates.Count - 1)
        $batchItems = @($candidates[$offset..$last])
        try {
            $state = Start-MinerUApiBatch `
                -Items $batchItems -Token $Token -ApiBase $ApiBase -Model $Model -Language $Language `
                -Ocr:$Ocr -PageRanges $PageRanges -OneDriveTimeoutSeconds $OneDriveTimeoutSeconds `
                -StabilitySeconds $StabilitySeconds -StateRoot $StateRoot
            $completed = Complete-MinerUApiBatch -State $state -Token $Token -IntervalSeconds $IntervalSeconds -TimeoutSeconds $TimeoutSeconds
            foreach ($result in $completed) { $allResults.Add($result) }
        }
        catch {
            if ($_.Exception.Data["MinerUAuthFailure"]) { throw }
            foreach ($item in $batchItems) {
                $allResults.Add([pscustomobject]@{
                    status = "Failed"; pdfPath = $item.pdfPath; batchId = $null
                    resumed = $false; error = $_.Exception.Message
                })
            }
        }
    }
    return $allResults.ToArray()
}

Export-ModuleMember -Function @(
    "Clear-MinerUApiCredential",
    "Get-MinerUApiCredentialPath",
    "Get-MinerUApiEnvironment",
    "Get-MinerUApiToken",
    "Invoke-MinerUApiConversions",
    "Invoke-MinerURecycle",
    "New-MinerUScanReport",
    "Set-MinerUApiCredential",
    "Write-MinerUReport"
)
