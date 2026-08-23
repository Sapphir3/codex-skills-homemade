[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$InstalledPath,
    [string[]]$IgnoreRelativePath = @()
)

$ErrorActionPreference = 'Stop'

function Get-ComparableFiles {
    param([Parameter(Mandatory)][string]$Root, [string[]]$Ignored)

    $result = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File)) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
        $segments = $relative.Split('/')
        if (@($segments | Where-Object { $_ -in @('.git', '__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache') }).Count -gt 0) { continue }
        if ($segments[-1] -in @('.DS_Store', 'Thumbs.db') -or $segments[-1] -match '(?i)\.(pyc|pyo|tmp)$') { continue }
        if ($relative -in $Ignored) { continue }
        $result[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $result
}

$sourceRoot = [System.IO.Path]::GetFullPath($SourcePath).TrimEnd('\', '/')
$installedRoot = [System.IO.Path]::GetFullPath($InstalledPath).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw "Source skill directory not found: $sourceRoot" }
if (-not (Test-Path -LiteralPath $installedRoot -PathType Container)) { throw "Installed skill directory not found: $installedRoot" }

$normalizedIgnored = @($IgnoreRelativePath | ForEach-Object { $_.Replace('\', '/') })
$sourceFiles = Get-ComparableFiles -Root $sourceRoot -Ignored $normalizedIgnored
$installedFiles = Get-ComparableFiles -Root $installedRoot -Ignored $normalizedIgnored
$errors = New-Object System.Collections.Generic.List[string]

foreach ($relative in $sourceFiles.Keys) {
    if (-not $installedFiles.ContainsKey($relative)) { $errors.Add("Installed copy is missing: $relative") }
    elseif ($sourceFiles[$relative] -ne $installedFiles[$relative]) { $errors.Add("Installed content differs: $relative") }
}
foreach ($relative in $installedFiles.Keys) {
    if (-not $sourceFiles.ContainsKey($relative)) { $errors.Add("Installed copy contains an extra file: $relative") }
}

if ($errors.Count -gt 0) { throw ("Installed skill comparison failed:`n- " + ($errors -join "`n- ")) }

[pscustomobject]@{
    matches = $true
    sourcePath = $sourceRoot
    installedPath = $installedRoot
    fileCount = $sourceFiles.Count
}
