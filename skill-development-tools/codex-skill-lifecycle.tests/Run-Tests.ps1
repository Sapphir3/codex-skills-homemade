[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$skillRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\codex-skill-lifecycle'))
$scripts = Join-Path $skillRoot 'scripts'
$temporaryBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
$suiteRoot = Join-Path $temporaryBase ('codex-skill-lifecycle-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $suiteRoot | Out-Null
$script:passed = 0
$script:failed = 0

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Pattern)
    try { & $Action; throw 'Expected the action to fail.' }
    catch {
        if ($_.Exception.Message -eq 'Expected the action to fail.') { throw }
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected error: $($_.Exception.Message)" }
    }
}

function New-TestSkill {
    param([Parameter(Mandatory)][string]$Parent, [Parameter(Mandatory)][string]$Name, [string]$Description = 'A test skill used only in a temporary test directory.')
    $path = Join-Path $Parent $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $body = "---`nname: $Name`ndescription: $Description`n---`n`n# Test`n"
    Set-Content -LiteralPath (Join-Path $path 'SKILL.md') -Value $body -Encoding UTF8
    return $path
}

function Invoke-Test {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Action)
    try {
        & $Action
        $script:passed++
        Write-Host "PASS $Name"
    }
    catch {
        $script:failed++
        Write-Host "FAIL $Name`n  $($_.Exception.Message)"
    }
}

try {
    Invoke-Test 'Builds and validates a wrapped single-skill ZIP' {
        $case = Join-Path $suiteRoot 'build-valid'
        $source = New-TestSkill -Parent $case -Name 'sample-skill'
        New-Item -ItemType Directory -Path (Join-Path $source 'scripts') | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'scripts\Run.ps1') -Value "'ok'" -Encoding UTF8
        $dist = Join-Path $case 'dist'
        $result = & (Join-Path $scripts 'Build-HomemadeSkillRelease.ps1') -SkillPath $source -Version '1.2.3' -OutputDirectory $dist
        Assert-True -Condition ($result.layout -eq 'Wrapped') -Message 'Expected wrapped layout.'
        Assert-True -Condition ($result.fileCount -eq 2) -Message 'Expected two runtime files.'
        Assert-True -Condition (Test-Path -LiteralPath $result.zipPath -PathType Leaf) -Message 'Release ZIP was not created.'
        $validation = & (Join-Path $scripts 'Test-HomemadeSkillRelease.ps1') -ZipPath $result.zipPath -SourcePath $source
        Assert-True -Condition $validation.sourceMatched -Message 'Expected a source-matched release.'
    }

    Invoke-Test 'Refuses to overwrite an existing semantic release' {
        $case = Join-Path $suiteRoot 'immutable-release'
        $source = New-TestSkill -Parent $case -Name 'immutable-skill'
        $dist = Join-Path $case 'dist'
        & (Join-Path $scripts 'Build-HomemadeSkillRelease.ps1') -SkillPath $source -Version '1.0.0' -OutputDirectory $dist | Out-Null
        Assert-Throws -Pattern 'will not be overwritten' -Action {
            & (Join-Path $scripts 'Build-HomemadeSkillRelease.ps1') -SkillPath $source -Version '1.0.0' -OutputDirectory $dist | Out-Null
        }
    }

    Invoke-Test 'Rejects likely credentials from a release' {
        $case = Join-Path $suiteRoot 'credential-scan'
        $source = New-TestSkill -Parent $case -Name 'unsafe-skill'
        Set-Content -LiteralPath (Join-Path $source 'config.ps1') -Value 'token = "abcdefghijklmnop1234"' -Encoding UTF8
        Assert-Throws -Pattern 'hard-coded credential' -Action {
            & (Join-Path $scripts 'Build-HomemadeSkillRelease.ps1') -SkillPath $source -Version '1.0.0' -OutputDirectory (Join-Path $case 'dist') | Out-Null
        }
    }

    Invoke-Test 'Discovers unique skills under nested categories' {
        $repository = Join-Path $suiteRoot 'nested-repository'
        New-TestSkill -Parent (Join-Path $repository 'paper-library-skills') -Name 'paper-tool' | Out-Null
        New-TestSkill -Parent (Join-Path $repository 'skill-development-tools') -Name 'release-tool' | Out-Null
        $result = & (Join-Path $scripts 'Test-HomemadeSkillRepository.ps1') -RepositoryPath $repository
        Assert-True -Condition ($result.skillCount -eq 2) -Message 'Expected two nested skills.'
    }

    Invoke-Test 'Rejects duplicate skill names across categories' {
        $repository = Join-Path $suiteRoot 'duplicate-repository'
        New-TestSkill -Parent (Join-Path $repository 'category-a') -Name 'same-skill' | Out-Null
        New-TestSkill -Parent (Join-Path $repository 'category-b') -Name 'same-skill' | Out-Null
        Assert-Throws -Pattern 'Duplicate skill name' -Action {
            & (Join-Path $scripts 'Test-HomemadeSkillRepository.ps1') -RepositoryPath $repository | Out-Null
        }
    }

    Invoke-Test 'Rejects a discoverable skill fixture under tests' {
        $repository = Join-Path $suiteRoot 'test-fixture-repository'
        New-TestSkill -Parent (Join-Path $repository 'category') -Name 'real-skill' | Out-Null
        New-TestSkill -Parent (Join-Path $repository 'real-skill.tests') -Name 'fixture-skill' | Out-Null
        Assert-Throws -Pattern 'fixture directory contains' -Action {
            & (Join-Path $scripts 'Test-HomemadeSkillRepository.ps1') -RepositoryPath $repository | Out-Null
        }
    }

    Invoke-Test 'Rejects a skill directory name mismatch' {
        $repository = Join-Path $suiteRoot 'mismatch-repository'
        $path = New-TestSkill -Parent (Join-Path $repository 'category') -Name 'right-name'
        Move-Item -LiteralPath $path -Destination (Join-Path (Split-Path -Parent $path) 'wrong-name')
        Assert-Throws -Pattern 'Directory name must match' -Action {
            & (Join-Path $scripts 'Test-HomemadeSkillRepository.ps1') -RepositoryPath $repository | Out-Null
        }
    }

    Invoke-Test 'Compares identical installed content' {
        $case = Join-Path $suiteRoot 'compare-equal'
        $source = New-TestSkill -Parent $case -Name 'compare-skill'
        $installed = Join-Path $case 'installed'
        Copy-Item -LiteralPath $source -Destination $installed -Recurse
        $result = & (Join-Path $scripts 'Compare-InstalledSkill.ps1') -SourcePath $source -InstalledPath $installed
        Assert-True -Condition $result.matches -Message 'Expected identical content.'
    }

    Invoke-Test 'Detects changed installed content' {
        $case = Join-Path $suiteRoot 'compare-different'
        $source = New-TestSkill -Parent $case -Name 'compare-skill'
        $installed = Join-Path $case 'installed'
        Copy-Item -LiteralPath $source -Destination $installed -Recurse
        Add-Content -LiteralPath (Join-Path $installed 'SKILL.md') -Value 'changed'
        Assert-Throws -Pattern 'content differs' -Action {
            & (Join-Path $scripts 'Compare-InstalledSkill.ps1') -SourcePath $source -InstalledPath $installed | Out-Null
        }
    }
}
finally {
    $resolvedSuite = [System.IO.Path]::GetFullPath($suiteRoot)
    if (-not $resolvedSuite.StartsWith($temporaryBase + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove unexpected test path: $resolvedSuite"
    }
    if (Test-Path -LiteralPath $resolvedSuite -PathType Container) { Remove-Item -LiteralPath $resolvedSuite -Recurse -Force }
}

Write-Host "RESULT passed=$script:passed failed=$script:failed"
if ($script:failed -gt 0) { exit 1 }
