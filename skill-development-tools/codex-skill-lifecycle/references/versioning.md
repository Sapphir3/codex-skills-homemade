# Versioning

Use semantic versions `MAJOR.MINOR.PATCH`, with prerelease identifiers only while a workflow is explicitly under validation.

## Choose The Increment

- **MAJOR:** incompatible trigger, input, output, configuration, credential, or behavior contract changes.
- **MINOR:** backward-compatible capabilities, modes, supported inputs, or meaningful workflow additions.
- **PATCH:** backward-compatible corrections, safety improvements, documentation that changes execution decisions, or small observable refinements.
- **No runtime release:** repository renames, category moves, CI-only changes, tests, or project records that do not change the installed skill tree.

Distinguish the skill release version from API versions, output schema versions, conversion marker versions, and repository content hashes. CCSwitch hashes indicate content state, not semantic version.

## Immutable Records

Use `<skill-name>-vX.Y.Z` for tags and releases. Before building or publishing, verify that the version is absent from the local distribution directory, Git tags, and GitHub Releases. Never replace an existing ZIP, tag, or release asset silently.

Record at least the skill, version, category, source path, commit, tag, ZIP filename, SHA-256, test result, CI result, and CCSwitch status. Keep machine-specific paths and credentials out of public records.
