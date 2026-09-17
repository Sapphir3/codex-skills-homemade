# handwritten-labnote-to-markdown v1.0.0

## Initial Release

- Convert handwritten scientific lab-note PDFs or page images into Markdown using a template supplied for the current run.
- Treat original page images as the evidence source and OCR output as a fallible transcription aid.
- Preserve template structure, scientific meaning, blank source-absent fields, and page-level traceability.
- Track ambiguous text with synchronized uncertainty identifiers and separate review files.
- Validate the final Markdown, uncertainty log, and traceability record with the included Python script.
- Keep the core workflow portable across agent environments; `agents/openai.yaml` is optional interface metadata.

## Validation And Limits

The skill passed frontmatter and structure validation with the bundled skill validator. The included Python validator compiled successfully and its command-line interface was exercised. No real handwritten notebook, OCR service, or end-to-end transcription-quality benchmark was used for this publication check.

The single-skill ZIP contains six runtime files under one same-name wrapper directory and excludes credentials, caches, tests, and unrelated skills.

- Tag: `handwritten-labnote-to-markdown-v1.0.0`
- ZIP: `handwritten-labnote-to-markdown-v1.0.0.zip`
- SHA-256: `649D762B516B5E37FB5E324F61E8371847640CE9E949CC9542694B7E4528111D`

Install or update through the repository's `main` branch in CCSwitch. A copy installed from a local ZIP must be removed and reinstalled once from the repository listing before CCSwitch can track repository updates.
