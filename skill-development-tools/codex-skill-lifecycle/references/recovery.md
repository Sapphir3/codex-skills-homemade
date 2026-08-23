# Failure And Recovery

## Stop Promotion

Do not tag or create a Release when source validation, behavior tests, ZIP validation, repository validation, diff review, or CI fails. Preserve the failed evidence needed to diagnose the issue, but do not publish caches, credentials, or machine-local logs.

## Correct A Published Branch

If the update branch contains a bad change, publish a normal corrective or revert commit and rerun validation. Do not delete or move historical release tags to hide the state. Create a new semantic version when an immutable release artifact itself needs correction.

## Installation Recovery

A validated historical ZIP can restore runtime behavior locally, but it becomes a `local:` installation and loses repository update tracking. To restore updates, reinstall from the configured repository after the branch is corrected.

If nested repository discovery fails, keep the production repository in its last validated layout and use top-level skill directories until CCSwitch behavior changes. If the repository URL changes, verify redirects but register the new full URL explicitly rather than relying on them indefinitely.
