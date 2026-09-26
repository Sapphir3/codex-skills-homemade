# mineru-api-batch-convert v2.0.1

## Fix: OneDrive Paths Were Treated As Links

v2.0.0 rejected every path component or asset entry that carried `FILE_ATTRIBUTE_REPARSE_POINT`. Windows Cloud Files placeholders, used by OneDrive and other sync engines, carry such a reparse point on every synced file and folder (for example tag `0x9000601A`). Consequently `Scan` reported `InvalidMarker` for every converted paper stored in OneDrive, and `Convert` failed at publication with `Linked paths require manual review.` after the PDF had already been uploaded.

## Changes

- Classify reparse points by tag. The Cloud Files family (`IO_REPARSE_TAG_CLOUD` and `CLOUD_1` to `CLOUD_F`, i.e. `(tag -band 0xFFFF0FFF) -eq 0x9000001A`, per MS-FSCC) is accepted because it does not redirect the path.
- Symbolic links, junctions/mount points, unreadable tags, and every other reparse tag are still rejected with the unchanged messages `Linked paths require manual review.` and `Linked assets require manual review.`
- Read the tag from the directory entry (`FindFirstFileW`) without opening, following, or hydrating the item. If the native reader cannot be loaded, every reparse point remains rejected as in v2.0.0.
- No change to markers, checkpoints, output layout, credentials, or API behavior.

## Validation And Limits

Local validation on Windows PowerShell 5.1 passed 130 conversion assertions (110 existing plus 20 new) and 35 credential assertions, both in local temporary storage and with all fixtures inside a OneDrive folder, where the v2.0.0 suite failed its first mock conversion. PowerShell 7 was not available locally; CI runs both runtimes on the release commit before tagging.

New coverage: simulated Cloud Files tags (`CLOUD`, `CLOUD_6`, `CLOUD_E`, `CLOUD_F`) pass scanning and publication; simulated ProjFS, WOF, symbolic-link, mount-point, and unreadable tags are rejected; real junctions and real directory/file symbolic links in the parent chain or inside assets are rejected. A read-only scan of a real OneDrive-synced literature folder reported 20 PDFs, 0 Missing, 19 Current, 1 ExistingUntracked, and 0 InvalidMarker (v2.0.0: 19 InvalidMarker on the same folder). Tests use synthetic PDFs, a loopback mock, and isolated dummy credentials; no real MinerU upload was performed.

Unchanged limit: for a PDF without existing output, a genuinely linked path is still detected at publication, after upload.

## Distribution

- Repository: https://github.com/Sapphir3/codex-skills-homemade
- Update branch: `main`
- Skill path: `paper-library-skills/mineru-api-batch-convert`
- Tag: `mineru-api-batch-convert-v2.0.1`
- ZIP: `mineru-api-batch-convert-v2.0.1.zip`
- SHA-256: `62C394863DE07BAFBBEC9CC9AEFD247E9DF0B4A45BDCB1AF917750C112FCFA1C`

The wrapped ZIP contains nine runtime files, one SKILL.md, and no tests, credentials, or local state. Existing CCSwitch repository installations can use **Check updates**. Installation remains a manual step; this release does not alter existing local credentials or installed copies.
