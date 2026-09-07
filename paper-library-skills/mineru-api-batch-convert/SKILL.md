---
name: mineru-api-batch-convert
description: Convert authorized local or Zotero-resolved PDFs to same-directory Markdown and image assets through the MinerU API on Windows. Use for missing conversions, scoped batch recovery, conversion audits, local API credential setup, or explicitly confirmed orphan cleanup. Preserve PDFs and existing outputs; replacing stale generated outputs requires separate consent.
---

# MinerU API Batch Convert

Release: **2.0.0**. Use the bundled scripts with Windows PowerShell 5.1 or PowerShell 7. No local MinerU installation is required.

## Resolve Scope And Permission

- Resolve selected Zotero attachments to absolute PDF paths through an available connector. If the user already supplied paths, use them directly; otherwise ask for paths when no connector is available.
- Use `-PdfPath` for explicit files, or `-RootPath` for directories; add `-Recurse` only for authorized nested folders. Never scan the whole library by default.
- Conversion requires permission to upload those PDFs to MinerU. This does **not** authorize replacing existing Markdown/assets or recycling orphans.
- In v2, stale outputs are preserved by default. Show the affected files and obtain explicit replacement consent before using `-AllowReplaceStale` with the reviewed PDF list. The switch never permits overwriting untracked, malformed, or incomplete outputs. A marker proves origin, not absence of human edits.

## Convert

Run `Convert` directly for an authorized scope; it scans once, resumes eligible checkpoints, and verifies the original PDF list. No separate preflight scan is required.

```powershell
& "<skill-directory>\scripts\Invoke-MinerUApiBatch.ps1" `
  -Action Convert -PdfPath @("D:\Papers\Paper.pdf") -Language en
```

The output is `Paper.pdf` (unchanged), `Paper.md`, and optional `Paper.assets/`. Defaults: `vlm`, 20 files per batch, 3 concurrent transfers. Retain the PDF hash and image-integrity checks. Use `ch` for Chinese text and `-Ocr` for scanned/image-only PDFs; change model or transfer settings only for a concrete need.

On first API use, the script opens a masked local token dialog, saves the credential with Windows DPAPI, and continues. **Never ask for a token in chat.** Each computer/user configures its own credential. Use `-CredentialPrompt Never` for unattended jobs; missing credentials or unresolved authentication stop API work. No-work conversions need no token.

Do not switch to MCP/Flash or resubmit through another route after an uncertain failure. Local checkpoints prevent duplicate submissions; resume with the same authorized scope. Read [references/mineru-api.md](references/mineru-api.md) for credential replacement, API errors, recovery, limits, and advanced settings.

## Preview Or Audit

Use `Scan` only when a preview, audit, or orphan review is requested:

```powershell
& "<skill-directory>\scripts\Invoke-MinerUApiBatch.ps1" `
  -Action Scan -RootPath "D:\Papers" -Recurse
```

| Status | Action |
|---|---|
| `Missing` | Eligible for authorized conversion. |
| `Current`, `CurrentMetadataChanged` | Skip; referenced images and asset count are checked. |
| `Stale` | Preserve unless replacement was explicitly approved. |
| `ExistingUntracked`, `IncompleteAssets`, `InvalidMarker` | Report for review; do not upload or overwrite. |

Ownership checks require matching sibling filenames and reject linked paths. Legacy schema-1 markers and schema-1/2 checkpoints remain readable when safe. To identify the copy actually executing, run `-Action Environment` and report `skillVersion` and `skillPath`; do not infer a release from an installer hash.

## Recycle Confirmed Orphans

Only directory scans find orphan candidates. Show `orphans`, exclude `renameCandidates`, and obtain explicit confirmation of the exact list. Reuse that report:

```powershell
& "<skill-directory>\scripts\Invoke-MinerUApiBatch.ps1" `
  -Action Recycle -ReportPath "<reviewed-report.json>" -ConfirmRecycle
```

Recycling rechecks ownership, scope, signature, assets, source absence, and late renames. It uses the Windows Recycle Bin. Never replace this workflow with direct deletion.

## Report

Return the absolute JSON report path, scan summary (including stale/orphan/rename counts), converted/failed/review-required counts, warnings, and failed or blocked filenames with concise reasons. Include `timing.totalSeconds`; polling/wait is not a measurement of server-only parsing time.

Fatal conversion errors write partial results before throwing; read the report named in the error instead of assuming all files failed or rerunning completed work. Preserve checkpoints for uncertain outcomes. Never expose tokens, signed URLs, or raw API response bodies. No additional library-wide scan is needed after a successful report.
