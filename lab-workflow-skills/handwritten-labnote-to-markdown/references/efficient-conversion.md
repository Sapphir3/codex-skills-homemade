# Efficient, bounded conversion

## Route once, inspect every page

1. Resolve explicit input files and order; never glob nearby private files into a batch. Preserve one source file per output subdirectory by default, retaining visible date sub-blocks. A file name determines provenance, not experimental dates. If temporal order cannot be resolved, preserve the supplied order and flag chronology only when needed.
2. Record source hash and page count. Inspect a color overview for every page, including corners, page margins, deletion marks, handwritten date headers and sketches. Color can carry distinctions; do not binarize or erase ruled lines by default.
3. For a small legible batch, direct visual reading is a valid first route. For longer batches or when useful OCR already exists, use one OCR draft as navigation. Use a second OCR system only on unresolved regions where it may add value. External OCR follows the executing environment's ordinary data and tool permissions.
4. Inspect native-resolution or higher-resolution detail regions for all high-risk tokens. Keep enough overlap/context to see a full formula, its labels, table header and neighboring rows. A magnified low-resolution bitmap adds no information. Stop repeated model guesses after a bounded detail check and request targeted human review.
5. Build one evidence ledger and reuse it to produce the final note and audit sidecars. Avoid re-transcribing whole pages during template mapping or later formatting edits. Keep page provenance and uncertainty IDs stable.

## Optional local helper

Requires Python 3.10+ and `pypdfium2`; the tested package version is recorded in the run manifest. Use an available environment rather than installing a new environment per file. If this dependency is unavailable, use any equivalent page renderer; do not block a visually accessible task solely on this helper.

```text
python scripts/prepare_pages.py --source note-a.pdf note-b.pdf --output-dir work/pages --manifest work/cold.json
python scripts/prepare_pages.py --source note-a.pdf --output-dir work/details --page 1 --crop 0.10,0.35,0.95,0.65 --dpi 288
```

Coordinates are fractions of the displayed page, top-left origin. Default overview DPI is 144; increase when the page is dense. The helper respects PDF display rotation, retains color, writes PNG images and records page numbers, dimensions, hashes, settings, renderer version, elapsed seconds and cache hits. It never sets an inspected flag. Source PDFs are not modified.

Reuse is keyed by the SHA-256 of source bytes plus renderer version and rendering settings. A cached image's own hash is checked before reuse. Changing the source, DPI or crop invalidates that result. A template change does not require rerendering an unchanged PDF, but it does require remapping/revalidating the final note. Run separate invocations to distinct manifest paths if timing cold and warm runs. Do not run simultaneous writers to the same cache path.

Embedded-image extraction may be faster but is not the default: a page may contain rotation, transforms, overlays, annotations or multiple image tiles. Use it only after establishing equivalence with the rendered page.

## Timing boundaries

Report preparation, OCR, visual transcription, targeted review, template mapping, validation and human review separately when measured. A cache timing is not end-to-end conversion throughput. For benchmarks compare the same inputs/settings, record cache state and repetitions, and keep actual run manifests. Use medians for repeated comparisons. Do not claim improved recognition accuracy without author-adjudicated evidence.
