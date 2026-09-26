# Curated Distribution Repository

## When It Applies

CCSwitch reads the repository and branch configured in its skills repository manager, which may differ from the development repository where releases are built and tested. In the current workflow, homemade skills are released in `https://github.com/Sapphir3/codex-skills-homemade` and CCSwitch installs them from the curated distribution repository `https://github.com/Sapphir3/research-skills-curated`, branch `cc-switch-compat`. That branch is a temporary copy of `main` without `ppt-master`, whose file count exceeds CCSwitch's current skill-file limit; retire it only when the user confirms CCSwitch can sync `main`. Tags and Releases are recorded on `main` only. Update `main` first, then apply the same skill commit to `cc-switch-compat`, for example by cherry-picking it, and confirm the two branches have the same skill tree and that `ppt-master` is still excluded. A release that stops at the development repository or at `main` is invisible to CCSwitch update checks.

Confirm the distribution repository from project instructions, the distribution repository README, or the installed skill's `UPSTREAM_SOURCE.md`. Do not open or edit the CCSwitch database to find it. If a skill is not yet distributed there, adding it is a curation decision; ask the user first.

## Update After The Upstream Release

Start only after the upstream commit passed CI and its tag and Release exist.

1. Use a separate device-local checkout of the distribution repository. Confirm that the distributed skill matches the upstream commit recorded in its `UPSTREAM_SOURCE.md`, and inspect the repository's own conventions: README, recent commits, tags, and Releases.
2. Export the skill tree from the upstream release commit with line-ending conversion disabled, for example `git -c core.autocrlf=false archive`. Copy it byte-for-byte over the distributed runtime files, remove files deleted upstream, and verify every file against the upstream Git blob IDs. Keep distribution additions such as `LICENSE`, `UPSTREAM_SOURCE.md`, and `KNOWN_ISSUES.md`.
3. Update only the release-specific fields of `UPSTREAM_SOURCE.md`: selected reference, fixed commit, skill directory Git tree (`git rev-parse <commit>:<skill-path>`), query and acquisition timestamps, distribution version, latest stable release link and date, and the file count when it changed.
4. Run `quick_validate.py`, confirm the staged diff touches only that skill, then commit and push the distribution default branch and the CCSwitch branch when they differ.
5. Record the update immutably using the distribution repository's convention. For `research-skills-curated`, create an annotated incremental batch tag `retained-skills-vX.Y.Z` (PATCH for updated skills, MINOR for added skills) and a matching Release with the single-skill ZIP and `SHA256SUMS.txt`, stating which skills changed. Build that ZIP from the committed bytes, including distribution additions. The repository has no CI; do not describe local checks as CI.
6. Verify that both branches serve the new files, the tag target, and the Release asset digest. GitHub is the only copy of the distribution repository; do not maintain synchronized local mirrors of it.

## Handoff

Report both repositories: the upstream release (commit, tag, Release, ZIP digest, CI) and the distribution update (repository URL, CCSwitch branch, commits on each branch, tag, Release, ZIP digest). Tell the user to check updates on the distribution repository in CCSwitch. Distribution publication, like upstream publication, does not authorize CCSwitch application control.
