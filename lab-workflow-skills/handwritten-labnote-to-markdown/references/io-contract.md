# Input and output contract

## Inputs

Use explicit paths or attached-file identifiers. Never guess which nearby files are inputs.

| Name | Required | Accepted form | Meaning |
| --- | --- | --- | --- |
| `source` | yes | PDF, one image, or ordered image directory | Original handwritten note; highest authority |
| `template` | yes | Markdown file | Structure for this conversion run |
| `output_dir` | yes | Writable directory | Destination for generated files |
| `ocr_draft` | no | Markdown, text, MMD, or OCR JSON | Candidate transcription only |
| `user_context` | no | Explicit user-supplied facts or mapping rules | May supplement the note only when clearly attributed |

If multiple source files are supplied, preserve the user's order. If no order is supplied, a deterministic filename order is acceptable for a batch of separate outputs; explicitly record it. Ask only when a required combined chronology cannot be established. Do not derive experimental dates from that processing order.

## Required outputs

Always create these three UTF-8 files inside `output_dir`:

1. `final.md` - the supplied template populated only with supported content.
2. `uncertainties.md` - the manual-review queue; write an explicit empty-state line when there are no uncertainties.
3. `traceability.md` - source manifest and page-level evidence map, including unmapped and crossed-out material.

Create `raw.md` only when the run itself produced or received an OCR draft and preserving it helps auditability. Never overwrite an input OCR file.

For batches, create the three outputs per source or explicitly agreed grouping. Optional files include `evidence.json`, a preparation manifest, benchmark records and an attributed author-feedback log. These supplement rather than replace the three required Markdown files. Store original inputs separately, and preserve earlier output revisions when incorporating feedback. Do not overwrite user-edited notes during regeneration.

## Stable invocation shape

Natural-language invocation should identify the inputs and destination, for example:

```text
Use $handwritten-labnote-to-markdown.
source: ./notes/2026-04-16.pdf
template: ./templates/lab-note.md
ocr_draft: ./work/mineru_raw.md   # optional
output_dir: ./converted/2026-04-16
```

The skill must work when `ocr_draft` is omitted. It must also work when the named OCR product is unavailable, provided the executing model can inspect the rendered source pages.

## Filename and metadata boundary

Filenames, PDF metadata, timestamps, and folder names may be recorded as provenance in `traceability.md` and in a template field explicitly asking for source location. Do not use them to fill experiment date, operator, sample ID, experiment number, or scientific content unless:

- the same value is visible in the note; or
- the user explicitly says that metadata is authoritative for that field.

## Template handling

Treat the supplied template as runtime data, not a fixed schema. The optional bundled starter is only a starting point; never substitute it for a supplied template.

- Preserve non-placeholder headings, prompt labels, ordering, and table columns.
- Do not silently correct template wording or typos.
- Replace a placeholder only with confirmed content.
- If a heading contains multiple placeholders and only some are supported, render a natural heading from the supported parts without inventing the missing parts.
- Leave a prompt's value empty when unsupported.
- For an unsupported table, retain its header and separator and add no fabricated row.
- Omit text that is unmistakably a template-maintenance note rather than part of the intended record only when that distinction is explicit; otherwise preserve it.

These are the strict-mode defaults. An explicit `labnote:mode=guided` template uses the guided contract in [guided-template.md](guided-template.md): remove marked guidance comments, retain visible fixed structure, omit unsupported optional subfields, and organize supported content flexibly. Record the mode and a template snapshot/hash for each revision. A conversion-date field declared by the template is run metadata and may be filled from the local run date without handwritten support.

## Conflict handling

If the template asks for a derived value that the source does not state, leave it blank. If the source and user-supplied context conflict, preserve both in `uncertainties.md` and ask the user which is authoritative. Never silently reconcile them.
