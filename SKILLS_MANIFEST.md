# Skills Manifest

> Update branch: `main`

|Skill|Category|Current release|Release ZIP SHA-256|Purpose|
|---|---|---|---|---|
|`handwritten-labnote-to-markdown`|`lab-workflow-skills`|`1.1.0`|`685F232A1E2E5433BC38B3CCB78655123BF47EEDEB0E346A4FCFD721B0E82982`|Convert handwritten scientific lab notes into auditable, template-driven Markdown|
|`mineru-api-batch-convert`|`paper-library-skills`|`2.0.1`|`62C394863DE07BAFBBEC9CC9AEFD247E9DF0B4A45BDCB1AF917750C112FCFA1C`|Batch-convert academic PDFs to same-directory Markdown through MinerU|
|`codex-skill-lifecycle`|`skill-development-tools`|`1.0.0`|`AED0034F06F4F7D9AAAE870463C85741C1DF82760A0158EA8E68F980C3AD58D3`|Create, test, version, publish, and hand off homemade Codex skills|

## Release Rules

- A semantic release uses the tag `<skill-name>-vX.Y.Z` and an immutable single-skill ZIP.
- CCSwitch updates from repository `main` content, not from Release ZIP assets.
- A release ZIP contains exactly one skill, preferably under one same-name wrapper directory.
- Published versions, tags, and ZIP assets are never overwritten.
- Credentials, caches, tests, and machine-local state are excluded from release ZIPs.
