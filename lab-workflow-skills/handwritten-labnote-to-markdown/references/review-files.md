# Review files

## `final.md`

Base this file on the supplied template. Strict mode retains unsupported fields blank; guided mode omits unsupported optional subfields while preserving fixed headings and metadata. Insert uncertainty markers immediately after the ambiguous item, for example:

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

IDs in the active queue must appear in either `final.md` or `traceability.md`. A doubt concerning only deleted or unmapped material belongs in the latter; do not insert it artificially into the final experiment record. Use stable IDs across revisions; remove resolved IDs from the active queue and retain their resolution history separately. Author-confirmed relationships do not automatically confirm every numeric character in the same region.

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

## Optional machine-readable page ledger

`evidence.json` can be supplied to `validate_outputs.py --evidence evidence.json`:

```json
{
  "source": "note.pdf",
  "page_count": 1,
  "inspected_pages": [1],
  "evidence": [
    {"id":"E001", "page":1, "region":"top right", "status":"confirmed", "text":"4.16", "destination":"date"}
  ]
}
```

Supported statuses: `confirmed`, `uncertain`, `crossed out`, `revised`, `unmapped`, `user-confirmed`, `blank`. Include an explicit blank-page item after inspecting an empty page. For multiple PDFs, use one ledger per source to prevent page-number collisions. Keep this ledger synchronized with the Markdown map. Preparation manifests record render completion, not inspection.

Optional role, parent, related-ID and required-final-anchor fields are documented in [guided-template.md](guided-template.md). Guidance-only prompts and illustrative tables are excluded from validation in guided mode; literal fixed structure outside those comments is still checked. Conversion date can be validated against `--run-date`. An optional `--template-mode strict|guided` override is available for explicitly authorized mode selection; unmarked templates default to strict.

The validator checks headings, colon-terminated bullet prompt labels and their section/order, table headers and row widths, template-derived angle-bracket placeholders, bidirectional uncertainty references, required provenance fields and optional ledger page coverage. It does not prove handwriting accuracy, semantic mapping, actual visual inspection or exhaustive transcription. Other prompt styles still require manual structural review.

## Final response

Tell the user which files were produced, how many unresolved uncertainty items remain, and whether any legible evidence remains unmapped. Never state that the transcription is scientifically verified; the user has reserved final review and correction.
