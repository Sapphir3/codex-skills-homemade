# Skills Manifest

> Update branch: `main`

|Skill|Category|Current release|Release ZIP SHA-256|Purpose|
|---|---|---|---|---|
|`mineru-api-batch-convert`|`paper-library-skills`|`2.0.0`|`F7072F040C4D08045462FC2FB56DE099E1AE39CB8A1FEF552D60B5481039C4A8`|Batch-convert academic PDFs to same-directory Markdown through MinerU|
|`codex-skill-lifecycle`|`skill-development-tools`|`1.0.0`|`AED0034F06F4F7D9AAAE870463C85741C1DF82760A0158EA8E68F980C3AD58D3`|Create, test, version, publish, and hand off homemade Codex skills|

## Release Rules

- A semantic release uses the tag `<skill-name>-vX.Y.Z` and an immutable single-skill ZIP.
- CCSwitch updates from repository `main` content, not from Release ZIP assets.
- A release ZIP contains exactly one skill, preferably under one same-name wrapper directory.
- Published versions, tags, and ZIP assets are never overwritten.
- Credentials, caches, tests, and machine-local state are excluded from release ZIPs.
