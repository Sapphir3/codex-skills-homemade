# Review files

## `final.md`

Base this file on the supplied template. Keep unsupported fields blank. Insert uncertainty markers immediately after the ambiguous item, for example:

```markdown
- 渗透率：$0.1\sim10\times10^{-15}\,\mathrm{m^2}$ ⟦U001⟧
```

Do not add a generic disclaimer in every blank field. One short provenance note is acceptable only if the template has an appropriate place for it.

## `uncertainties.md`

Use this structure:

```markdown
# Manual review queue

| ID | Source | Best literal reading | Alternatives | Why uncertain | Final location | Required check |
| --- | --- | --- | --- | --- | --- | --- |
| U001 | page 1, lower middle | `10^-15 m²` | `10^-13 m²` | exponent stroke is crowded | 2. 对象与实际条件 / material | compare against original at high zoom |
```

Use the same ID everywhere. Do not assign an uncertainty merely because a template field is blank.

When no uncertainties remain, write:

```markdown
# Manual review queue

No unresolved transcription uncertainties were identified. Human review is still required for scientific records.
```

## `traceability.md`

Start with a source manifest:

```markdown
# Traceability

- Source: `<exact filename>`
- Pages inspected: `<range/list>`
- Template: `<exact filename>`
- OCR draft: `<filename or none>`
```

Then include a page-level table:

```markdown
| Evidence ID | Source region | Status | Literal content or concise description | Final destination |
| --- | --- | --- | --- | --- |
| E001 | page 1, top right | confirmed | `2026.4.16` | experiment date |
| E002 | page 1, middle | crossed out | earlier Reynolds-number calculation | actual operations/observations |
| E003 | page 1, bottom | unmapped | question about flow velocity and Re | manual placement needed |
```

The literal-content column may use Markdown or LaTeX. Keep it faithful and concise; this is an audit map, not a rewritten narrative.

## Final response

Tell the user which files were produced, how many unresolved uncertainty items remain, and whether any legible evidence remains unmapped. Never state that the transcription is scientifically verified; the user has reserved final review and correction.
