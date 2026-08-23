# GitHub Publication

## Preconditions

- The user requested publication, not only a plan or local implementation.
- `git` and GitHub CLI are available, and `gh auth status` succeeds for the intended account.
- The device-local checkout points to the intended public repository and branch.
- The authoritative source, checkout copy, manifest, release record, and ZIP version agree.
- Behavior tests, skill validation, release validation, repository validation, and `git diff --check` pass.
- The staged diff contains only the reviewed release files and contains no credentials or local state.

## Publish

1. Copy reviewed runtime files and public tests from the authoritative source into the device-local checkout.
2. Update the repository manifest, release record, and README only where the release changes them.
3. Run local validation and inspect `git status`, the exact diff, and staged file list.
4. Commit and push the configured default/update branch.
5. Require the validation workflow for that commit to pass before tagging.
6. Create and push the immutable annotated tag `<skill-name>-vX.Y.Z`.
7. Create the matching GitHub Release, attach the already validated ZIP, and include material changes and SHA-256.
8. Verify repository visibility, default branch, tag target, Release asset, and digest.

Do not store `gh` credentials in project files. Use device-local authentication. Do not force-push shared release history.

## Completion Boundary

Successful GitHub publication is the default stopping boundary. Report the exact CCSwitch handoff fields defined in `ccswitch.md` and wait for the user. GitHub publication alone does not grant permission to open CCSwitch, remove an existing installation, or run an update.
