[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryPath,
    [string[]]$SkillRoot
)

$ErrorActionPreference = 'Stop'

function Get-RelativePath {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    return $Path.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
}

function Test-PathWithin {
    param([Parameter(Mandatory)][string]$Parent, [Parameter(Mandatory)][string]$Child)
    $prefix = $Parent.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return $Child.Equals($Parent, [System.StringComparison]::OrdinalIgnoreCase) -or $Child.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

$repositoryRoot = [System.IO.Path]::GetFullPath($RepositoryPath).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $repositoryRoot -PathType Container)) { throw "Repository directory not found: $repositoryRoot" }

$allowedRoots = @()
foreach ($root in @($SkillRoot)) {
    $resolved = if ([System.IO.Path]::IsPathRooted($root)) { [System.IO.Path]::GetFullPath($root) } else { [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $root)) }
    if (-not (Test-PathWithin -Parent $repositoryRoot -Child $resolved)) { throw "Skill root is outside the repository: $resolved" }
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { throw "Skill root not found: $resolved" }
    $allowedRoots += $resolved.TrimEnd('\', '/')
}

$errors = New-Object System.Collections.Generic.List[string]
$skillFiles = @(Get-ChildItem -LiteralPath $repositoryRoot -Recurse -Force -File -Filter 'SKILL.md' | Where-Object {
    $relative = Get-RelativePath -Root $repositoryRoot -Path $_.FullName
    $segments = $relative.Split('/')
    '.git' -notin $segments
})
if ($skillFiles.Count -eq 0) { $errors.Add('Repository contains no discoverable SKILL.md files.') }

$skills = New-Object System.Collections.Generic.List[object]
foreach ($skillFile in $skillFiles) {
    $skillDirectory = $skillFile.Directory.FullName.TrimEnd('\', '/')
    $relativeSkillFile = Get-RelativePath -Root $repositoryRoot -Path $skillFile.FullName
    $segments = $relativeSkillFile.Split('/')

    if (@($segments | Where-Object { $_ -eq 'tests' -or $_ -match '(?i)\.tests$' }).Count -gt 0) {
        $errors.Add("Test or fixture directory contains a discoverable SKILL.md: $relativeSkillFile")
    }
    if ($allowedRoots.Count -gt 0 -and -not @($allowedRoots | Where-Object { Test-PathWithin -Parent $_ -Child $skillDirectory }).Count) {
        $errors.Add("Skill is outside the declared skill roots: $relativeSkillFile")
    }

    $text = Get-Content -LiteralPath $skillFile.FullName -Raw
    $frontmatter = [regex]::Match($text, '(?s)\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)')
    if (-not $frontmatter.Success) {
        $errors.Add("Invalid YAML frontmatter delimiters: $relativeSkillFile")
        continue
    }
    $nameMatch = [regex]::Match($frontmatter.Groups[1].Value, '(?m)^name:\s*([a-z0-9-]+)\s*$')
    $descriptionMatch = [regex]::Match($frontmatter.Groups[1].Value, '(?m)^description:\s*(\S.*)\s*$')
    if (-not $nameMatch.Success) {
        $errors.Add("Missing valid hyphen-case name: $relativeSkillFile")
        continue
    }
    if (-not $descriptionMatch.Success) { $errors.Add("Missing non-empty description: $relativeSkillFile") }

    $skillName = $nameMatch.Groups[1].Value
    if ((Split-Path -Leaf $skillDirectory) -cne $skillName) { $errors.Add("Directory name must match skill name '$skillName': $relativeSkillFile") }
    $skills.Add([pscustomobject]@{
        name = $skillName
        path = Get-RelativePath -Root $repositoryRoot -Path $skillDirectory
    })
}

foreach ($duplicate in @($skills | Group-Object name | Where-Object Count -gt 1)) { $errors.Add("Duplicate skill name '$($duplicate.Name)' appears $($duplicate.Count) times.") }

$skillDirectories = @($skillFiles | ForEach-Object { $_.Directory.FullName.TrimEnd('\', '/') })
foreach ($directory in $skillDirectories) {
    foreach ($other in $skillDirectories) {
        if ($directory -ne $other -and (Test-PathWithin -Parent $directory -Child $other)) {
            $errors.Add("Nested skill directories are not allowed: $(Get-RelativePath -Root $repositoryRoot -Path $directory) contains $(Get-RelativePath -Root $repositoryRoot -Path $other)")
        }
    }
}

if ($errors.Count -gt 0) { throw ("Skill repository validation failed:`n- " + (@($errors | Select-Object -Unique) -join "`n- ")) }

[pscustomobject]@{
    valid = $true
    repositoryPath = $repositoryRoot
    skillCount = $skills.Count
    skills = @($skills | Sort-Object name)
}
