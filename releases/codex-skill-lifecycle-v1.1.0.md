# codex-skill-lifecycle v1.1.0

## Curated Distribution Step

CCSwitch no longer installs homemade skills from this repository. It syncs the curated distribution repository `https://github.com/Sapphir3/research-skills-curated`, branch `cc-switch-compat` (a temporary copy of `main` without `ppt-master`). v1.0.0 stopped at the development repository, so a release could be published here and still never appear as a CCSwitch update.

## Changes

- Add `references/distribution-repository.md`: after the upstream release passes CI and is tagged, copy the released skill tree byte-for-byte into the distribution repository, verify Git blob IDs, update only the release-specific `UPSTREAM_SOURCE.md` fields, push `main` and apply the same commit to `cc-switch-compat`, then record an annotated `retained-skills-vX.Y.Z` tag and Release with the single-skill ZIP and `SHA256SUMS.txt`.
- `SKILL.md`: the update channel is the repository and branch CCSwitch actually uses; publication now routes through the distribution step.
- `ccswitch.md` and `github-release.md`: the handoff reports both repositories, and the stopping boundary is publication to the repository CCSwitch uses.
- No script changes.

## Validation And Limits

System `quick_validate.py` and the lifecycle behavior suite (9 tests) passed locally on Windows PowerShell 5.1. The procedure was exercised for `mineru-api-batch-convert` v2.0.1 before being written down. No CCSwitch application control is added.

## Distribution

- Repository: https://github.com/Sapphir3/codex-skills-homemade
- Skill path: `skill-development-tools/codex-skill-lifecycle`
- Tag: `codex-skill-lifecycle-v1.1.0`
- ZIP: `codex-skill-lifecycle-v1.1.0.zip`
- SHA-256: `0DD600D9402BC49422CE9C6C88426DC6590DFD0E8D53D7F4FCD861E418D055AA`

The wrapped ZIP contains 12 runtime files and no tests or local state. Install or update through CCSwitch from the curated repository above.
