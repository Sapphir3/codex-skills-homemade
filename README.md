# Paper Library Skills

Reusable Codex skills developed for a Zotero, Obsidian, and Codex literature-management workflow.

## Available Skills

| Skill | Purpose | Current release |
|---|---|---|
| `mineru-api-batch-convert` | Convert local or Zotero-resolved academic PDFs to same-directory Markdown through the official MinerU API | `v1.0.3` |

## CCSwitch Installation And Updates

Add this repository to the CCSwitch Skills repository manager:

```text
Repository: https://github.com/Sapphir3/paper-library-skills
Branch: main
```

Use the full URL. The tested CCSwitch build rejected the `owner/name` shorthand even though its input hint advertised that format.

Install a skill from the repository listing. A skill previously installed from a local ZIP must be uninstalled and reinstalled from this repository once so CCSwitch records its remote source. Later releases are detected by CCSwitch through directory-content hashes when **Check updates** is run.

Git tags and release ZIPs provide human-readable versions and offline installation. CCSwitch follows the contents of the configured branch rather than GitHub Release assets.

## Security

No API credentials are stored in this repository. Skills that need credentials keep them in device-local storage and document their configuration procedure in `SKILL.md`.

## License

MIT
