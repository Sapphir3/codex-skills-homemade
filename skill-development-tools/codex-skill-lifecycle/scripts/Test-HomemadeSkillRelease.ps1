[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ZipPath,
    [string]$SourcePath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Test-IgnoredSkillFile {
    param([Parameter(Mandatory)][string]$RelativePath)

    $normalized = $RelativePath.Replace('\', '/')
    $segments = $normalized.Split('/')
    if (@($segments | Where-Object { $_ -in @('.git', '.svn', '.hg', '__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache', 'node_modules') }).Count -gt 0) { return $true }
    $leaf = $segments[-1]
    return $leaf -in @('.DS_Store', 'Thumbs.db') -or $leaf -match '(?i)\.(pyc|pyo|tmp)$'
}

function Get-StreamSha256 {
    param([Parameter(Mandatory)][System.IO.Stream]$Stream)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '') }
    finally { $sha.Dispose() }
}

$zipFullPath = [System.IO.Path]::GetFullPath($ZipPath)
if (-not (Test-Path -LiteralPath $zipFullPath -PathType Leaf)) { throw "ZIP not found: $zipFullPath" }

$errors = New-Object System.Collections.Generic.List[string]
$archive = [System.IO.Compression.ZipFile]::OpenRead($zipFullPath)
try {
    $fileEntries = @($archive.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
    $normalizedNames = @($fileEntries | ForEach-Object { $_.FullName.Replace('\', '/') })
    $allSkillFiles = @($fileEntries | Where-Object { $_.FullName.Replace('\', '/') -match '(^|/)SKILL\.md$' })
    $layout = $null
    $archivePrefix = ''

    if ($allSkillFiles.Count -ne 1) {
        $errors.Add("ZIP must contain exactly one SKILL.md in total; found $($allSkillFiles.Count).")
    }
    else {
        $skillPath = $allSkillFiles[0].FullName.Replace('\', '/')
        if ($skillPath -ceq 'SKILL.md') {
            $layout = 'Flat'
        }
        elseif ($skillPath -match '^([^/]+)/SKILL\.md$') {
            $archivePrefix = "$($Matches[1])/"
            $outsideWrapper = @($normalizedNames | Where-Object { -not $_.StartsWith($archivePrefix, [System.StringComparison]::Ordinal) })
            if ($outsideWrapper.Count -eq 0) { $layout = 'Wrapped' }
            else { $errors.Add('Wrapped ZIP must contain all files under its single top-level skill directory.') }
        }
        else {
            $errors.Add('SKILL.md must be at ZIP root or directly inside one top-level skill directory.')
        }
    }

    foreach ($duplicate in @($normalizedNames | Group-Object | Where-Object Count -gt 1)) { $errors.Add("Duplicate ZIP entry: $($duplicate.Name)") }

    foreach ($name in $normalizedNames) {
        $segments = $name.Split('/')
        if ($name.StartsWith('/') -or $name -match '^[A-Za-z]:' -or @($segments | Where-Object { $_ -eq '..' }).Count -gt 0) {
            $errors.Add("Unsafe ZIP entry path: $name")
        }
        if ($name -match '(?i)(^|/)(\.env(?:\..+)?|credential\.clixml|id_rsa|id_ed25519)$' -or $name -match '(?i)\.(pem|pfx|p12|key)$') {
            $errors.Add("Sensitive file type is not allowed in a release: $name")
        }
    }

    if ($allSkillFiles.Count -eq 1) {
        $stream = $allSkillFiles[0].Open()
        try {
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
            try { $skillText = $reader.ReadToEnd() }
            finally { $reader.Dispose() }
        }
        finally { $stream.Dispose() }

        $frontmatter = [regex]::Match($skillText, '(?s)\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)')
        if (-not $frontmatter.Success) {
            $errors.Add('SKILL.md does not contain valid opening YAML frontmatter delimiters.')
        }
        else {
            $nameMatch = [regex]::Match($frontmatter.Groups[1].Value, '(?m)^name:\s*([a-z0-9-]+)\s*$')
            $descriptionMatch = [regex]::Match($frontmatter.Groups[1].Value, '(?m)^description:\s*(\S.*)\s*$')
            if (-not $nameMatch.Success) { $errors.Add('SKILL.md frontmatter is missing a valid hyphen-case name.') }
            if (-not $descriptionMatch.Success) { $errors.Add('SKILL.md frontmatter is missing a non-empty description.') }
            if ($layout -eq 'Wrapped' -and $nameMatch.Success) {
                $wrapperName = $archivePrefix.TrimEnd('/')
                if ($wrapperName -cne $nameMatch.Groups[1].Value) { $errors.Add("Top-level directory '$wrapperName' must match skill name '$($nameMatch.Groups[1].Value)'.") }
            }
        }
    }

    $textExtensions = @('.md', '.yaml', '.yml', '.json', '.ps1', '.psm1', '.py', '.js', '.ts', '.toml', '.ini', '.cfg', '.txt')
    foreach ($entry in $fileEntries) {
        if ([System.IO.Path]::GetExtension($entry.Name).ToLowerInvariant() -notin $textExtensions) { continue }
        $stream = $entry.Open()
        try {
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
            try { $text = $reader.ReadToEnd() }
            finally { $reader.Dispose() }
        }
        finally { $stream.Dispose() }
        if ($text -match '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----') { $errors.Add("Private key material found in: $($entry.FullName)") }
        if ($text -match '(?im)^\s*(?:api[_-]?key|access[_-]?token|token|password|secret)\s*[:=]\s*["''][A-Za-z0-9._~-]{16,}["'']\s*$') {
            $errors.Add("Possible hard-coded credential found in: $($entry.FullName)")
        }
    }

    if ($SourcePath) {
        $sourceRoot = [System.IO.Path]::GetFullPath($SourcePath).TrimEnd('\', '/')
        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw "Source directory not found: $sourceRoot" }
        $sourceFiles = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File | Where-Object {
            $relative = $_.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
            -not (Test-IgnoredSkillFile -RelativePath $relative)
        })
        $entryByName = @{}
        $archiveSourceNames = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $fileEntries) {
            $entryName = $entry.FullName.Replace('\', '/')
            if ($archivePrefix -and $entryName.StartsWith($archivePrefix, [System.StringComparison]::Ordinal)) { $entryName = $entryName.Substring($archivePrefix.Length) }
            $entryByName[$entryName] = $entry
            $archiveSourceNames.Add($entryName)
        }

        $sourceNames = New-Object System.Collections.Generic.List[string]
        foreach ($file in $sourceFiles) {
            $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\', '/').Replace('\', '/')
            $sourceNames.Add($relative)
            if (-not $entryByName.ContainsKey($relative)) {
                $errors.Add("Source file missing from ZIP: $relative")
                continue
            }
            $sourceHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            $stream = $entryByName[$relative].Open()
            try { $entryHash = Get-StreamSha256 -Stream $stream }
            finally { $stream.Dispose() }
            if ($sourceHash -ne $entryHash) { $errors.Add("ZIP content differs from source: $relative") }
        }
        foreach ($extra in @($archiveSourceNames | Where-Object { $_ -notin $sourceNames })) { $errors.Add("ZIP contains a file not present in source: $extra") }
    }
}
finally {
    $archive.Dispose()
}

if ($errors.Count -gt 0) { throw ("Skill release validation failed:`n- " + ($errors -join "`n- ")) }

[pscustomobject]@{
    valid = $true
    zipPath = $zipFullPath
    layout = $layout
    fileCount = $fileEntries.Count
    sha256 = (Get-FileHash -LiteralPath $zipFullPath -Algorithm SHA256).Hash
    sourceMatched = [bool]$SourcePath
}
