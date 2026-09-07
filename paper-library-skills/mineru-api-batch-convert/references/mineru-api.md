# MinerU API Reference

## Endpoints

- API base: `https://mineru.net/api/v4`
- Request local-file upload URLs: `POST /file-urls/batch`
- Poll batch results: `GET /extract-results/batch/{batch_id}`
- Upload PDFs: `PUT` each returned signed URL without a `Content-Type` header
- Download results: use each completed item's `full_zip_url`

Send `Authorization: Bearer <token>` only to MinerU API endpoints. Never attach it to signed upload or result URLs.

## Batch Request

Use this logical payload:

```json
{
  "files": [
    {
      "name": "Paper.pdf",
      "data_id": "000-paper",
      "is_ocr": false
    }
  ],
  "model_version": "vlm",
  "language": "en",
  "enable_formula": true,
  "enable_table": true
}
```

Add `page_ranges` only when the user requests a range. Keep each request at or below 50 files, each file at or below 200 MB, and each PDF at or below the service's current page limit (historically 200 pages). Service quotas can change; treat API errors as authoritative.

## States

Persist a local submission intent before requesting a batch. Once the server returns a batch id, checkpoint it before uploads. Checkpoint each successful upload and publication. Signed upload URLs are DPAPI-encrypted for the current Windows user; API tokens and signed result URLs are never written to the checkpoint or report. Local checkpoints are machine-local and must not be synced with the project.

Poll by the expected `data_id` set, not just the number of returned records. Missing records remain pending. Publish ready documents as they arrive. Polling starts at at most two seconds and backs off to `IntervalSeconds` when there is no progress. `IntervalSeconds=0` is for tests. Downloads and uploads use a bounded pool (default 3); publication of different PDFs may also overlap.

Do not resubmit a PDF while a recorded batch remains recoverable. Resume only requested PDF paths, including for mixed-scope batches; retain untouched siblings for a future explicit request. Query the server before retrying an interrupted upload. Reuse its original upload URL only for `waiting-file`; successful files are never re-uploaded. Expired URLs, corrupt checkpoints, or an unknown POST outcome require review. Do not automatically retry POST or switch to MCP after a network error.

Since v2.0.0, a definite POST rejection removes only the unconfirmed intent for that request. Recognized HTTP client rejections and explicit quota/validation messages permit a later user-requested retry; they do not trigger automatic POST retries. Timeouts, connection failures, 5xx, and unrecognized service errors retain the intent because allocation may have occurred. Never delete such an intent merely to unblock a rerun.

Before publishing, verify that the source path still exists, its hash is unchanged, and no untracked Markdown appeared. Recognize an already published result using both source hash and batch id after a crash. Read older schema-1 uploaded-batch records; write schema-2 per-file records using atomic replacement. Output ownership markers remain schema 1.

Replacement permission is not persisted as an automatic grant: resuming work against stale existing output requires `-AllowReplaceStale` again. Incomplete/untracked/invalid outputs are excluded from recovery as well as new submissions. Existing results are not overwritten merely because a pending checkpoint references them.

## Authentication

Since v1.2.0, first API use configures a missing/unreadable credential through a masked local Windows dialog and resumes the operation. A stored token rejected by authentication can be replaced once, then only the rejected API request is retried. The replacement is reused by subsequent requests in that invocation. Newly supplied tokens rejected again terminate the run. Environment overrides and `-CredentialPrompt Never` never prompt. Signed upload/download requests do not invoke credential setup.

Credential writes use a temporary encrypted CLIXML file followed by atomic replacement. Cancelling setup or a failed write preserves the previous file. Existing CLIXML and DPAPI formats/locations are unchanged. Token values must never be written to command-line arguments, logs, reports, source, or releases. No startup ping is added: the next required API call verifies the token. GUI tests construct the real masked form but replace its modal display; manual desktop visibility is a separate user check.

Treat HTTP 401 or 403 (unless the response explicitly identifies quota/rate limits), or an API message explicitly indicating an invalid/expired token, as authentication failure. Do not infer authentication failure merely because a message contains the word `token` or `expired`.

Do not treat these as authentication failures:

- DNS or connection errors
- HTTP 408, 429, or 5xx
- parsing quota or daily task limits
- a failed individual document

Keep the existing credential for transient and quota failures.

### Local Setup

The saved credential is `%LOCALAPPDATA%\Codex\mineru-api-batch-convert\credential.clixml`, outside the skill and paper folders. DPAPI binds it to the current computer/user. Never sync this file, checkpoints, or credentials with OneDrive or include them in a release. Upgrading the skill leaves saved credentials intact.

- Manual setup/replacement: `& "<skill-directory>\scripts\Set-MinerUApiCredential.ps1"`, or the main script with `-Action Configure`.
- Remove the saved credential: main script with `-Action ClearCredential`.
- `-CredentialPrompt Auto` uses a masked Windows dialog; `Console` uses masked terminal input; `Never` disables prompting. Cancelled or unavailable interactive setup stops dependent API work promptly.
- Empty, quoted, or internally multiline/whitespace tokens are rejected. Surrounding whitespace and an accidental `Bearer ` prefix are normalized.
- `MINERU_TOKEN` and `MINERU_API_LOCAL_DATA` are controlled-test overrides; do not set them to real secrets or synchronized storage. An invalid environment token is never silently replaced with the saved credential.

## Output Processing

Extract ZIP files into a temporary directory after validating that every entry remains under that directory. Prefer a unique `full.md`, then a unique Markdown file matching the PDF stem, then the largest Markdown file. Copy only referenced image assets to `Paper.assets/`, rewrite destinations (Markdown inline/reference images and HTML img src), prepend the ownership marker, and publish through same-directory temporary names. URI-encode each path segment, including parentheses, percent signs, and hashes, consistently on Windows PowerShell 5.1 and PowerShell 7. Do not rewrite image filenames occurring only in prose.

Fail publication for missing, external, or out-of-directory image destinations. Inline data images remain inline. Image-free Markdown is valid and needs no assets directory. Empty Markdown is invalid. Rollback removes only outputs created by the current publication attempt; a newly appeared user note must survive.

Scanning, publication, and recycling share marker/path validation. Schema-1 markers must name the matching sibling PDF and assets directory; malformed fields and reparse-point paths require review. Asset count and every recognized local image destination are checked even for otherwise-current outputs. This validates existence and ownership, not semantic figure quality or whether a person has edited generated content. Stale output is replaced only with explicit consent, never because the marker alone implies permission.

Orphan recycling rechecks the original recursive/nonrecursive scope, canonical source/assets paths, Markdown signature, image files, and whether the source reappeared or was renamed in the same directory. Rename detection is limited to same-directory PDFs with the recorded length/hash; it is not a library-wide search. A legacy orphan without a recorded source hash is refused for manual review, although its marker remains readable for conversion scans.

## Reports And Settings

`Convert` includes `reviewRequiredCount` for protected outputs and `invalidMarkerCount` in the scan summary. On fatal conversion errors, the JSON report preserves completed results, failed/unattempted eligible files, and `fatalError` before the entry script throws with its absolute report path. A report-write failure itself cannot guarantee a report; preserve existing outputs and checkpoints for recovery.

Defaults are 20 files per batch, 3 transfer workers, a shared 2-second stability window, a 120-second file-readiness timeout, and a 1,800-second polling timeout per batch. `-TransferConcurrency` supports 1-8; use 1 for constrained connections. Batches stay sequential. `-TimeoutSeconds` bounds the polling loop, not the entire process or every individual transfer. Retain the existing hash checks and do not raise concurrency just to improve a benchmark.

## Timing And MCP

Reports include scan, preparation, upload, polling/wait, download/publication, verification, and total elapsed seconds. Phase values are wall-clock durations, not the sum of worker time. Polling/wait combines server queue, parsing, network, and client sleep; do not describe it as a measured server-only parsing duration.

The evaluated MCP tool returned inline Markdown with image references but no locally accessible image artifacts for a synthetic two-page PDF, even with output_dir specified. That does not satisfy this skill's output contract, so v1.1.0 keeps the direct API route. This observation is specific to that response, not a claim that every MCP configuration lacks images. Do not use MCP unless a future reviewed implementation verifies artifacts, recovery, and performance.

Never publish MinerU's copied source PDF, raw model JSON, batch state, signed URLs, or ZIP archive beside the user's paper.
