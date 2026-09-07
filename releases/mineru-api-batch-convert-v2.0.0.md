# mineru-api-batch-convert v2.0.0

## Breaking Change And Migration

Stale tracked Markdown/assets are now preserved unless the current conversion invocation includes `-AllowReplaceStale` after explicit user consent for the reviewed PDF list. Without consent, conversion reports `ReviewRequired` without prompting for a token or uploading those files. Pending recovery does not bypass this requirement. Untracked, malformed, and incomplete outputs remain protected even with the switch.

## Changes

- Validate marker schema, sibling filenames, canonical paths, referenced images, and asset counts; reject linked paths and invalid markers conservatively.
- Recheck orphan ownership, source reappearance, and late renames before recycling. Hashless legacy orphans require manual review.
- Clear only unconfirmed intent after a definite API rejection. Preserve checkpoints on ambiguous responses, timeouts, and server failures; do not automatically retry uncertain submissions.
- Write partial successful results to JSON before fatal errors, including successes within the current batch.
- Simplify SKILL.md to 65 lines and expose the executing skill version and path in environment diagnostics.
- Include the previously local credential/workflow separation, masked DPAPI credential persistence, and bounded transfers; retain the direct MinerU API and existing output layout without new runtime dependencies.

## Validation And Limits

Local validation passed 110 conversion assertions and 35 credential assertions plus fresh-process credential reuse on each of PowerShell 7 and Windows PowerShell 5.1. Tests use synthetic PDFs, a loopback mock, and isolated dummy credentials. No real MinerU upload, extraction-quality benchmark, or live token-dialog visibility test was performed. CI must pass on the release commit before its annotated tag and GitHub Release are created.

The single-skill ZIP contains nine runtime files, excludes tests and credentials, and matches the reviewed source byte-for-byte.

- Tag: `mineru-api-batch-convert-v2.0.0`
- ZIP: `mineru-api-batch-convert-v2.0.0.zip`
- SHA-256: `F7072F040C4D08045462FC2FB56DE099E1AE39CB8A1FEF552D60B5481039C4A8`

Update through the repository's `main` branch in CCSwitch. Installation remains a manual step; this release does not alter existing local credentials or installed copies.
