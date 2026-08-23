[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$ignoredSegments = @(".git", ".github", "tools", "dist", "node_modules", "__pycache__")
$skillFiles = @(Get-ChildItem -LiteralPath $repositoryRoot -Filter "SKILL.md" -File -Recurse -Force | Where-Object {
    $relative = $_.FullName.Substring($repositoryRoot.Length).TrimStart("\", "/").Replace("\", "/")
    $segments = $relative.Split("/")
    -not (@($segments | Where-Object { $_ -in $ignoredSegments -or $_ -like "*.tests" }).Count)
})

if ($skillFiles.Count -eq 0) { throw "No SKILL.md files found." }

$names = New-Object System.Collections.Generic.List[string]
foreach ($skillFile in $skillFiles) {
    $text = Get-Content -LiteralPath $skillFile.FullName -Raw
    $frontmatter = [regex]::Match($text, '(?s)\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)')
    if (-not $frontmatter.Success) { throw "Invalid frontmatter: $($skillFile.FullName)" }

    $nameMatch = [regex]::Match($frontmatter.Groups[1].Value, '(?m)^name:\s*([a-z0-9-]+)\s*$')
    $descriptionMatch = [regex]::Match($frontmatter.Groups[1].Value, '(?m)^description:\s*(\S.*)\s*$')
    if (-not $nameMatch.Success) { throw "Missing valid name: $($skillFile.FullName)" }
    if (-not $descriptionMatch.Success) { throw "Missing description: $($skillFile.FullName)" }

    $name = $nameMatch.Groups[1].Value
    if ((Split-Path -Leaf $skillFile.DirectoryName) -cne $name) {
        throw "Skill directory must match frontmatter name '$name': $($skillFile.DirectoryName)"
    }
    $names.Add($name)
}

$duplicates = @($names | Group-Object | Where-Object Count -gt 1)
if ($duplicates.Count) { throw "Duplicate skill names: $($duplicates.Name -join ', ')" }

$sensitive = @(Get-ChildItem -LiteralPath $repositoryRoot -File -Recurse -Force | Where-Object {
    $_.Name -match '^(\.env(?:\..+)?|credential\.clixml|id_rsa|id_ed25519)$' -or
    $_.Extension -match '^\.(pem|pfx|p12|key)$'
})
if ($sensitive.Count) { throw "Sensitive file names found: $($sensitive.FullName -join ', ')" }

[pscustomobject]@{
    valid = $true
    skillCount = $skillFiles.Count
    skills = @($names)
}
