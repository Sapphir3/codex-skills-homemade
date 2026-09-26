# Homemade Codex Skills

Public Codex skills developed and maintained across several work domains. Skills are grouped by category. This repository is where they are developed, tested, and released; CCSwitch installs them from the curated distribution repository described below.

## Available Skills

| Category | Skill | Purpose | Current release |
|---|---|---|---|
| `lab-workflow-skills` | `handwritten-labnote-to-markdown` | Convert handwritten scientific lab notes into auditable, template-driven Markdown with explicit uncertainty and traceability records | `v1.1.0` |
| `paper-library-skills` | `mineru-api-batch-convert` | Convert local or Zotero-resolved academic PDFs to same-directory Markdown through the official MinerU API | `v2.0.1` |
| `skill-development-tools` | `codex-skill-lifecycle` | Create, test, version, package, publish, and hand off homemade Codex skills | `v1.1.0` |

## CCSwitch Installation And Updates

MinerU v2 preserves stale tracked outputs by default. After reviewing the affected PDFs and obtaining explicit replacement consent, use `-AllowReplaceStale`. Invalid, untracked, or incomplete outputs still require manual review. See [v2.0.0 release notes](releases/mineru-api-batch-convert-v2.0.0.md). v2.0.1 accepts OneDrive/Cloud Files placeholder paths while still rejecting symbolic links, junctions, and other reparse points; see [v2.0.1 release notes](releases/mineru-api-batch-convert-v2.0.1.md).

CCSwitch does not install from this repository. After each release here, the skill is copied byte-for-byte into the curated distribution repository, which CCSwitch syncs:

```text
Repository: https://github.com/Sapphir3/research-skills-curated
Branch: cc-switch-compat
```

`cc-switch-compat` is a temporary copy of that repository's `main` without `ppt-master`, whose file count exceeds CCSwitch's current skill-file limit. Use the full URL; the tested CCSwitch build rejected the `owner/name` shorthand. The adoption procedure is in `codex-skill-lifecycle` ([distribution-repository.md](skill-development-tools/codex-skill-lifecycle/references/distribution-repository.md)). A release that is not adopted there never appears in CCSwitch **Check updates**.

Git tags and Release ZIPs in this repository provide semantic versions, immutable records, and offline installation.

## Repository Layout

```text
codex-skills-homemade/
|-- lab-workflow-skills/
|-- paper-library-skills/
|-- skill-development-tools/
|-- tools/
|-- .github/workflows/
|-- SKILLS_MANIFEST.md
|-- README.md
`-- LICENSE
```

Every production skill directory directly contains one `SKILL.md`. Tests remain beside their skill as `<skill-name>.tests` and are excluded from release ZIPs.

## Security

No API credentials are stored in this repository. Skills that need credentials keep them in device-local storage and document their configuration procedure in `SKILL.md`.

## License

MIT
