# Skills Manifest

> Release branch: `main`. CCSwitch channel: `https://github.com/Sapphir3/research-skills-curated`, branch `cc-switch-compat`.

|Skill|Category|Current release|Release ZIP SHA-256|Purpose|
|---|---|---|---|---|
|`handwritten-labnote-to-markdown`|`lab-workflow-skills`|`1.1.0`|`685F232A1E2E5433BC38B3CCB78655123BF47EEDEB0E346A4FCFD721B0E82982`|Convert handwritten scientific lab notes into auditable, template-driven Markdown|
|`mineru-api-batch-convert`|`paper-library-skills`|`2.0.1`|`62C394863DE07BAFBBEC9CC9AEFD247E9DF0B4A45BDCB1AF917750C112FCFA1C`|Batch-convert academic PDFs to same-directory Markdown through MinerU|
|`codex-skill-lifecycle`|`skill-development-tools`|`1.1.0`|`0DD600D9402BC49422CE9C6C88426DC6590DFD0E8D53D7F4FCD861E418D055AA`|Create, test, version, publish, and hand off homemade Codex skills|

## Release Rules

- A semantic release uses the tag `<skill-name>-vX.Y.Z` and an immutable single-skill ZIP.
- CCSwitch updates from the curated distribution branch, not from this repository or Release ZIP assets; every release is adopted there byte-for-byte.
- A release ZIP contains exactly one skill, preferably under one same-name wrapper directory.
- Published versions, tags, and ZIP assets are never overwritten.
- Credentials, caches, tests, and machine-local state are excluded from release ZIPs.
