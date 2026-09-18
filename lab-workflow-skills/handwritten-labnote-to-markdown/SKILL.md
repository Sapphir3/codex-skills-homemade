---
name: handwritten-labnote-to-markdown
description: Convert handwritten scientific lab-note PDFs or images into an auditable Markdown document using a user-supplied Markdown template. Use when faithful transcription, template mapping, source traceability, and explicit uncertainty handling matter; do not use for summarizing papers or inventing missing experimental details.
metadata:
  version: "1.1.0"
---

# Handwritten Lab Note to Markdown

Create a faithful, reviewable transcription whose structure comes from the template supplied for the current run. Support strict templates and explicitly guided templates with flexible section bodies. The workflow is semi-automatic: the model transcribes and organizes evidence; the author adjudicates unclear readings and relationships. Treat source pages as evidence and OCR only as a fallible aid.

## Required inputs

- One or more original note files: PDF or page images.
- One Markdown template for this run.
- An output directory.

An OCR draft (for example from MinerU, Mathpix, or another converter) is optional. Never require a particular OCR vendor or model.

Read [references/io-contract.md](references/io-contract.md) before starting. Read [references/conversion-policy.md](references/conversion-policy.md) while transcribing and mapping. Read [references/review-files.md](references/review-files.md) before writing the outputs.

For PDF preparation, caching, OCR routing and timing, read [references/efficient-conversion.md](references/efficient-conversion.md). Read [references/benchmark-and-feedback.md](references/benchmark-and-feedback.md) when testing accuracy or incorporating author corrections. Scripts are optional helpers; core conversion requires visual page access, not a particular Python or OCR vendor.

Read [references/guided-template.md](references/guided-template.md) for template modes, run metadata and semantic completeness. When the user requests writing advice, provide [the handwriting guide](references/handwriting-guide.zh-CN.md) and [handwriting starter](assets/HANDWRITING_TEMPLATE.zh-CN.md). An optional [guided starter template](assets/TEMPLATE.guided.zh-CN.md) is included; the user's runtime template always takes precedence.

## Non-negotiable rules

1. The original page image is authoritative. OCR is a candidate transcription, not evidence that can overrule the page.
2. Do not add facts, explanations, conclusions, procedures, identifiers, dates, units, values, or relationships that are not supported by the source or explicitly supplied by the user.
3. Never invent content to fill a template. In strict mode, keep unsupported fields blank. In guided mode, omit unsupported optional subfields; keep required headings and fixed fields. Runtime conversion date is provenance, not an experimental fact; derive it from the recorded run context.
4. Do not bind the workflow to the example template. Infer the current template's headings, prompts, tables, placeholders, and order at runtime.
5. Preserve scientific meaning exactly. Never silently normalize a value, unit, sign, exponent, variable, formula, sample ID, or arrow relationship using domain knowledge.
6. Separate absence from uncertainty. A source-absent item stays blank; a present but ambiguous item receives an uncertainty ID and is added to the review queue.
7. Keep every source page traceable. Do not discard legible source material simply because it does not fit a template field; record it as unmapped evidence in `traceability.md`.
8. If the source pages cannot be inspected visually and no adequate page images are available, stop and ask the user for accessible pages or a usable conversion. Do not proceed from guesses.

## Workflow

1. Validate that the original note and template are available and readable. Record their exact filenames. Do not derive experimental facts from filenames unless the user explicitly authorizes that source of evidence.
2. Inventory page count, source hashes and visible date blocks. Prepare cached color overview images once; visually inspect every page. Use focused detail crops for dense formulas, small superscripts, tables, arrows and ambiguous strokes. Correct rotation for inspection without altering the original. A rendered page is not an inspected page.
3. Choose direct visual transcription or optional OCR-assisted transcription based on available tools and the input. Do not run multiple OCR vendors by default. Check all numbers, units, exponents, variables, formulas, arrows, deletion marks, and page order against the original page; OCR agreement and earlier conversations are not verified ground truth.
4. Build a page-level evidence ledger before populating the template. Preserve indentation and parent-child ownership before classifying content. Track scientific role separately from reading status and task completion. A completed plan remains a plan. Capture whole problem/analysis/hypothesis blocks, including colored marginal continuations; do not flatten them into isolated observations. Apply explicit author legends; color and arrows alone do not determine roles.
5. Determine template mode. Unmarked templates remain strict. With `<!-- labnote:mode=guided -->`, remove `labnote:guide` comment blocks from the final note; retain fixed headings/fields and organize evidence into meaningful paragraphs, optional subheadings, lists or tables. Do not reproduce all suggested fields as empty form entries. Preserve literal numbers, units and original claim strength in either mode.
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

9. Resolve structural errors and perform a semantic completeness check: every source block accounted for, parent-child relationships retained, all plans and statuses included, every problem and hypothesis preserved, and only source-supported links between them. A passing script is not proof of semantic completeness. Report remaining uncertainties; do not resolve them by guessing.
10. For author feedback, preserve the first-pass output. Create a new revision, record the exact correction and source, update only supported claims and affected evidence, and revalidate. Do not count your own revised output as independently verified ground truth.

## Completion standard

Complete only when every source page has been inspected, the final document follows the supplied template, blank fields remain genuinely blank, uncertainty IDs are synchronized, and traceability covers confirmed, uncertain, crossed-out, and unmapped material.
