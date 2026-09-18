# handwritten-labnote-to-markdown v1.1.0

## Guided, semi-automatic lab-note conversion

Rigid field-by-field mapping can flatten parameter ownership, move completed tasks out of their original plan, and scatter the author's problem/hypothesis analysis. This release adds an explicit guided-template mode while retaining strict behavior for existing unmarked templates.

- Preserve fixed major headings; use guidance comments to suggest relevant content without generating empty subfields.
- Record the local conversion date as provenance, separately from the experimental date.
- Preserve indentation-based parameter ownership, original plans and their author-defined completion states, and complete problem/hypothesis/next-step blocks.
- Keep theoretical values, actual quantities and corrections distinct; use explicit author legends rather than universal color assumptions.
- Provide optional Chinese handwriting templates, keyword guidance and a guided conversion starter. User-supplied templates remain authoritative.
- Add color PDF preparation with content/settings-based caching and focused crops.
- Expand structural validation for prompts, table shape, uncertainty references, guided comments, dates, evidence relationships and required final anchors.

## Validation and limits

- 22 automated tests passed locally, including strict-template compatibility, guided organization contracts, date validation, evidence references and render-cache invalidation/corruption.
- Four private handwritten pages were reorganized and reviewed against author feedback, checking hierarchy, plan status and complete problem/hypothesis coverage; all four output bundles passed structural validation. The private corpus and transcripts are not included.
- Skill frontmatter, repository layout and the single-skill ZIP were validated locally. The repository CI run for the publishing commit is required before tagging.
- Automated tests verify their explicit structural contracts; they do not establish handwriting accuracy. Remaining ambiguous words and values still require author review. No end-to-end speedup or recognition accuracy percentage is claimed.

## Distribution

- Repository: https://github.com/Sapphir3/codex-skills-homemade
- Update branch: `main`
- Skill path: `lab-workflow-skills/handwritten-labnote-to-markdown`
- Tag: `handwritten-labnote-to-markdown-v1.1.0`
- ZIP: `handwritten-labnote-to-markdown-v1.1.0.zip`
- SHA-256: `685F232A1E2E5433BC38B3CCB78655123BF47EEDEB0E346A4FCFD721B0E82982`

The wrapped ZIP contains 13 runtime files, one SKILL.md, and no tests, caches, credentials or private lab records. Existing CCSwitch repository installations can use Check updates. CCSwitch application updates are a separate user-controlled step.
