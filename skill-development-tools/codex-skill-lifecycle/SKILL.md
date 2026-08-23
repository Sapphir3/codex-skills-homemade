---
name: codex-skill-lifecycle
description: Create, revise, test, version, package, and publish homemade Codex skills while keeping a portable local source of truth, immutable release records, GitHub distribution, and a controlled CCSwitch installation or update handoff. Use when developing a new skill, releasing a skill update, reorganizing a multi-skill repository, or diagnosing this release workflow; do not use for merely installing an unrelated third-party skill.
---

# Codex Skill Lifecycle

Manage the whole release without confusing its three distinct artifacts:

- the synchronized local development source is authoritative for editing;
- the tested GitHub default branch is the CCSwitch update channel;
- immutable tags, releases, and single-skill ZIPs are version records and offline installers.

## Select The Mode

Determine the current mode from the request and existing artifacts:

- **Plan:** define purpose, triggers, boundaries, dependencies, permissions, category, repository, and acceptance checks.
- **Create:** use the available system `skill-creator` to initialize the smallest useful skill, then replace all scaffold placeholders.
- **Update:** inspect the current source and release record, preserve intended behavior, and choose a semantic version increment.
- **Validate:** run structural validation, behavior tests, release construction, repository validation, and source comparisons proportional to risk.
- **Publish:** publish only reviewed files, require CI success, and create an immutable tag, release, ZIP, and digest record.
- **CCSwitch handoff:** after a successful GitHub release, stop by default and give the user exact manual installation or update instructions.
- **CCSwitch verification:** operate CCSwitch only when the user explicitly requested at the start of the task that the complete workflow be autonomous.
- **Recover:** stop promotion after a failed check and use a normal corrective or revert commit rather than rewriting published history.

Do not treat a request to design or review a plan as permission to edit files or mutate GitHub.

## Establish Context

Before editing, identify the authoritative source directory, device-local Git checkout, repository URL and default branch, skill category, current semantic version, latest release, and requested scope. Inspect repository or project instructions before applying generic defaults.

Keep Git checkouts outside OneDrive or other synchronized source trees. Store no credentials, tokens, cookies, verification codes, caches, or machine-local application state in a skill or repository. Pause a dependent step when required authentication, software, or human verification is unavailable.

For repository organization and the nested-category compatibility gate, read [references/repository-layout.md](references/repository-layout.md).

## Create Or Update

Keep `SKILL.md` concise and route conditional detail to references. Add scripts only for deterministic repeated work, and test every new or changed script. Preserve existing user changes and avoid unrelated refactors.

Select the release increment using [references/versioning.md](references/versioning.md). A directory move or repository rename alone does not change a skill's runtime version. Do not overwrite an existing version, tag, release, or ZIP.

## Validate

Run the system `quick_validate.py` when available, then run behavior tests that exercise meaningful outcomes. On Windows, use the bundled scripts as applicable:

```powershell
& "<skill-directory>\scripts\Build-HomemadeSkillRelease.ps1" `
  -SkillPath "<source-skill>" -Version "1.2.3" -OutputDirectory "<dist>"

& "<skill-directory>\scripts\Test-HomemadeSkillRepository.ps1" `
  -RepositoryPath "<git-checkout>"

& "<skill-directory>\scripts\Compare-InstalledSkill.ps1" `
  -SourcePath "<source-skill>" -InstalledPath "<installed-skill>"
```

Require exactly one `SKILL.md` in each release ZIP. Prefer one top-level directory named after the skill with `SKILL.md` directly inside it. Require archive content to match the reviewed source and reject unsafe paths or likely credentials.

## Publish And Hand Off

Read [references/github-release.md](references/github-release.md) before GitHub publication. Confirm authentication, clean scope, exact staged files, tests, ZIP digest, and CI. GitHub publication does not authorize CCSwitch application control.

After publication, follow [references/ccswitch.md](references/ccswitch.md). Default to a manual handoff that reports the skill name, version, full repository URL, branch, category, tag, release, ZIP digest, CI result, and whether the user should add the repository or check for updates. Resume recordkeeping after the user reports the result.

Read [references/recovery.md](references/recovery.md) only for failed validation, bad branch state, incorrect releases, or installer/update problems.
