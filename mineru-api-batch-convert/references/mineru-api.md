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

Poll until every result is `done` or `failed`. Preserve a local state record after all uploads complete so an interrupted run can query the existing `batch_id` without uploading again.

Do not resubmit a PDF while a recorded batch remains recoverable. Before publishing a resumed result, verify that the source path still exists, its hash is unchanged, and no untracked Markdown appeared.

## Authentication

Treat HTTP 401 or 403, or an API message explicitly indicating an invalid/expired token, as an authentication failure. Prompt for credential replacement.

Do not treat these as authentication failures:

- DNS or connection errors
- HTTP 408, 429, or 5xx
- parsing quota or daily task limits
- a failed individual document

Keep the existing credential for transient and quota failures.

## Output Processing

Extract ZIP files into a temporary directory after validating that every entry remains under that directory. Select `full.md` when present; otherwise select the largest Markdown file. Copy only referenced image assets to `Paper.assets/`, rewrite links, prepend the ownership marker, and publish through same-directory temporary names.

Never publish MinerU's copied source PDF, raw model JSON, batch state, signed URLs, or ZIP archive beside the user's paper.
