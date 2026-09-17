---
name: handwritten-labnote-to-markdown
description: Convert handwritten scientific lab-note PDFs or images into an auditable Markdown document using a user-supplied Markdown template. Use when faithful transcription, template mapping, source traceability, and explicit uncertainty handling matter; do not use for summarizing papers or inventing missing experimental details.
---

# Handwritten Lab Note to Markdown

Create a faithful, reviewable transcription whose structure comes from the template supplied for the current run. Treat the source pages as evidence, the template as a runtime schema, and any OCR output only as a fallible aid.

## Required inputs

- One or more original note files: PDF or page images.
- One Markdown template for this run.
- An output directory.

An OCR draft (for example from MinerU, Mathpix, or another converter) is optional. Never require a particular OCR vendor or model.

Read [references/io-contract.md](references/io-contract.md) before starting. Read [references/conversion-policy.md](references/conversion-policy.md) while transcribing and mapping. Read [references/review-files.md](references/review-files.md) before writing the outputs.

## Non-negotiable rules

1. The original page image is authoritative. OCR is a candidate transcription, not evidence that can overrule the page.
2. Do not add facts, explanations, conclusions, procedures, identifiers, dates, units, values, or relationships that are not supported by the source or explicitly supplied by the user.
3. When a template item has no supporting source content, leave its value blank. Do not write `N/A`, `not provided`, `未记录`, or a guessed completion merely to fill the template.
4. Do not bind the workflow to the example template. Infer the current template's headings, prompts, tables, placeholders, and order at runtime.
5. Preserve scientific meaning exactly. Never silently normalize a value, unit, sign, exponent, variable, formula, sample ID, or arrow relationship using domain knowledge.
6. Separate absence from uncertainty. A source-absent item stays blank; a present but ambiguous item receives an uncertainty ID and is added to the review queue.
7. Keep every source page traceable. Do not discard legible source material simply because it does not fit a template field; record it as unmapped evidence in `traceability.md`.
8. If the source pages cannot be inspected visually and no adequate page images are available, stop and ask the user for accessible pages or a usable conversion. Do not proceed from guesses.

## Workflow

1. Validate that the original note and template are available and readable. Record their exact filenames. Do not derive experimental facts from filenames unless the user explicitly authorizes that source of evidence.
2. Render every PDF page to a legible image or inspect supplied page images directly. Correct rotation for inspection without altering the original.
3. If an OCR draft is supplied or an available converter can create one, use it to locate candidate text. Check all numbers, units, exponents, variables, formulas, arrows, deletion marks, and page order against the original page.
4. Build a page-level evidence ledger before populating the template. Classify each item as confirmed, uncertain, crossed-out/revised, or unmapped.
5. Copy the current template structure and map only supported evidence into it. Preserve heading order, prompt wording, and table columns unless the user requests template editing. Replace placeholders only with confirmed source content; remove unresolved placeholder tokens while leaving the corresponding position blank.
6. Preserve a visible distinction between observations, calculations, interpretations, plans, and crossed-out material when the source makes that distinction. Do not upgrade a note into a stronger claim.
7. Mark an ambiguous transcription at its exact location as `⟦U001⟧`, `⟦U002⟧`, and so on. Put the evidence, alternatives, and requested manual check in `uncertainties.md`.
8. Write all required outputs from [references/io-contract.md](references/io-contract.md), then run:

   ```bash
   python scripts/validate_outputs.py \
     --template <template.md> \
     --final <output-dir>/final.md \
     --uncertainties <output-dir>/uncertainties.md \
     --traceability <output-dir>/traceability.md
   ```

9. Resolve structural validation errors. Report remaining scientific uncertainties to the user; do not resolve them by guessing.

## Completion standard

Complete only when every source page has been inspected, the final document follows the supplied template, blank fields remain genuinely blank, uncertainty IDs are synchronized, and traceability covers confirmed, uncertain, crossed-out, and unmapped material.
