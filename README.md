# Homemade Codex Skills

Public Codex skills developed and maintained across several work domains. Skills are grouped by category while remaining installable and updateable through CCSwitch from one repository.

## Available Skills

| Category | Skill | Purpose | Current release |
|---|---|---|---|
| `lab-workflow-skills` | `handwritten-labnote-to-markdown` | Convert handwritten scientific lab notes into auditable, template-driven Markdown with explicit uncertainty and traceability records | `v1.1.0` |
| `paper-library-skills` | `mineru-api-batch-convert` | Convert local or Zotero-resolved academic PDFs to same-directory Markdown through the official MinerU API | `v2.0.0` |
| `skill-development-tools` | `codex-skill-lifecycle` | Create, test, version, package, publish, and hand off homemade Codex skills | `v1.0.0` |

## CCSwitch Installation And Updates

MinerU v2 preserves stale tracked outputs by default. After reviewing the affected PDFs and obtaining explicit replacement consent, use `-AllowReplaceStale`. Invalid, untracked, or incomplete outputs still require manual review. See [v2.0.0 release notes](releases/mineru-api-batch-convert-v2.0.0.md).

Add this repository to the CCSwitch Skills repository manager:

```text
Repository: https://github.com/Sapphir3/codex-skills-homemade
Branch: main
```

Use the full URL. The tested CCSwitch build rejected the `owner/name` shorthand even though its input hint advertised that format.

CCSwitch has been verified to discover, install, and update skills stored under category directories. Install a skill from the repository listing. A skill previously installed from a local ZIP or another repository source must be removed and reinstalled from this repository once so CCSwitch records the new source. Later releases are detected from the configured branch through directory-content hashes when **Check updates** is run.

Git tags and Release ZIPs provide semantic versions, immutable records, and offline installation. CCSwitch follows the configured branch rather than GitHub Release assets.

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
