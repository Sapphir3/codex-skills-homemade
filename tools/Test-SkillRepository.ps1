[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$validator = Join-Path $repositoryRoot 'skill-development-tools\codex-skill-lifecycle\scripts\Test-HomemadeSkillRepository.ps1'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) { throw "Repository validator not found: $validator" }

& $validator `
    -RepositoryPath $repositoryRoot `
    -SkillRoot @('paper-library-skills', 'skill-development-tools')
