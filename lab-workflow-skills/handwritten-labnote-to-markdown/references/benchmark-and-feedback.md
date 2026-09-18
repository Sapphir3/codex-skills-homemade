# Benchmark and author feedback

## Keep evidence independent

Save the untouched input, runtime template, first-pass output, route/model identification as available, render settings and timing records. Capture author corrections verbatim with source, date, exact region, previous reading, accepted replacement, and which claims are resolved. Do not ask the author to retype the whole notebook. Prioritize a few high-impact ambiguities at a time while continuing independent work.

Produce a new revision instead of overwriting a human-edited note. Apply corrections narrowly: confirmation of an exponent resolves that exponent, and confirmation that blue ink denotes actual amounts resolves the relationship, not necessarily every digit or omitted unit. Preserve visible source mistakes unless the author explicitly corrects them; retain both the original and attributed correction if scientific content changes.

## Accuracy measures

- Evaluate exact number+unit+exponent combinations, formula structure, table-cell association, date association, plan/observation distinction, omission and unsupported additions separately.
- Record an explicit adjudicated denominator. Author-confirmed correctness, incorrectness and unresolved items are different states. Do not present a count of uncertainties as an error rate.
- Track critical errors such as an exponent changed by two orders of magnitude or theoretical amounts reported as actual additions. Report unsupported additions separately from transcription typos.
- Evaluate changed rules on held-out notes/templates when available. Repeated revision of four development pages is not a generalization benchmark.
- Without a reviewed reference transcript, report coverage and known corrections, not a fabricated character accuracy percentage or a model ranking.

## Portable regression cases

Use synthetic fixtures for automated structural tests; keep real lab notes and their inferred values out of a public skill package. Test dropped/moved prompts, malformed tables, orphan/missing/duplicate uncertainty IDs, HTML versus template placeholders, missing page evidence, changed source bytes and stale/corrupt render caches. Automated success certifies only these explicit checks.

For behavior evaluation, include an unfamiliar template, more than one date per page, an undated block, differently colored theoretical and actual values, a questionable but legible physical parameter, a crossed-out formula, and unrelated margin notes. Review the generated meaning against the source; a structural validator cannot judge these cases for you.
