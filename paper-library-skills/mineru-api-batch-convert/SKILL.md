---
name: mineru-api-batch-convert
description: Batch-convert Zotero or local academic PDF attachments to same-directory Markdown through the official MinerU API while preserving source PDFs, extracting image assets, skipping current outputs, resuming interrupted batches, and safely reporting or recycling generated Markdown whose source PDF was removed. Use when Codex needs to scan paper folders or Zotero-resolved attachment paths, create missing Markdown, audit conversion state, update a MinerU API credential, or clean up orphaned MinerU outputs on Windows.
---

# MinerU API Batch Convert

Use the bundled PowerShell scripts on Windows. Treat every source PDF as read-only.

## Resolve Inputs

1. Use an available Zotero connector or plugin to resolve selected items to absolute local PDF attachment paths.
2. Pass resolved files with `-PdfPath`. Do not assume a Zotero storage layout.
3. If no Zotero connector is available, ask for explicit PDF or directory paths.
4. Pass directories with `-RootPath`; add `-Recurse` when nested folders are in scope.

## Inspect Before Converting

Run a scan first:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "<skill-directory>\scripts\Invoke-MinerUApiBatch.ps1" `
  -Action Scan -RootPath "D:\Papers" -Recurse
```

Interpret statuses as follows:

- `Missing`: safe conversion candidate.
- `Current` or `CurrentMetadataChanged`: skip.
- `Stale`: source content changed; conversion may replace only a tracked MinerU output.
- `ExistingUntracked`: never overwrite; report the collision.
- `IncompleteAssets` or `MismatchedMarker`: report and require review.

The output contract is `Paper.pdf`, `Paper.md`, and optionally `Paper.assets/` in the same directory. Generated Markdown contains a hidden ownership marker compatible with the local `mineru-batch-convert` skill.

## Configure Credentials

When no credential exists, or MinerU explicitly rejects it, tell the user to run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "<skill-directory>\scripts\Set-MinerUApiCredential.ps1"
```

The prompt is masked and the token is encrypted for the current Windows user with DPAPI under `%LOCALAPPDATA%`. Never request that the token be committed, written beside papers, included in a report, or printed. `MINERU_TOKEN` is an ephemeral override for controlled tests only.

To replace or remove the saved credential, use `-Action Configure` or `-Action ClearCredential`.

## Convert

Run conversion only when the user's request authorizes uploading the selected PDFs to MinerU:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "<skill-directory>\scripts\Invoke-MinerUApiBatch.ps1" `
  -Action Convert -PdfPath "D:\Papers\Paper.pdf" -Model vlm -Language en
```

Use `vlm` by default. Use `pipeline` only when the user prioritizes speed over formula and layout fidelity. Use `ch` for Chinese papers and `-Ocr` only for scanned/image-only PDFs.

The script automatically resumes locally recorded unfinished batches before submitting new work. It verifies the PDF SHA-256 before publishing and refuses to overwrite untracked Markdown or assets.

Read [references/mineru-api.md](references/mineru-api.md) when troubleshooting API errors, limits, recovery, or output structure.

## Handle Orphans

Only directory scans produce orphan cleanup candidates. Explicit Zotero file selections do not scan unrelated sibling Markdown.

1. Show every item in `orphans` from the scan report.
2. Exclude `renameCandidates`; they may represent a renamed PDF.
3. Ask for explicit confirmation.
4. Reuse the exact report path and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "<skill-directory>\scripts\Invoke-MinerUApiBatch.ps1" `
  -Action Recycle -ReportPath "<report.json>" -ConfirmRecycle
```

Recycling revalidates scope, file signature, ownership marker, source absence, and asset count. It sends the Markdown and owned assets directory to the Windows Recycle Bin. Never substitute `Remove-Item` for this workflow.

## Report Results

Report counts for current, converted, failed, untracked, stale, orphaned, and rename-candidate items. Include failed filenames and concise errors. Do not expose tokens, signed upload URLs, or full API response bodies.

When a scan writes a JSON report, include its absolute path so the same report can be reused for recovery or an explicitly confirmed orphan-recycling action.
