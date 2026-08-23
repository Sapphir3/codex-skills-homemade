#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import io
import json
import threading
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


class State:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.counter = 0
        self.batches: dict[str, list[dict]] = {}
        self.uploads: dict[str, bytes] = {}
        self.polls: dict[str, int] = {}


STATE = State()


def json_bytes(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "MockMinerU/1.0"

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def send_json(self, status: int, value: object) -> None:
        payload = json_bytes(value)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def authenticated(self) -> bool:
        if self.headers.get("Authorization") == "Bearer test-token":
            return True
        self.send_json(401, {"code": 401, "msg": "invalid token"})
        return False

    def do_POST(self) -> None:
        if self.path != "/api/v4/file-urls/batch":
            self.send_error(404)
            return
        if not self.authenticated():
            return
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length).decode("utf-8"))
        with STATE.lock:
            STATE.counter += 1
            batch_id = f"batch-{STATE.counter}"
            STATE.batches[batch_id] = request["files"]
        host = f"http://127.0.0.1:{self.server.server_address[1]}"
        urls = [f"{host}/upload/{batch_id}/{item['data_id']}" for item in request["files"]]
        self.send_json(200, {"code": 0, "msg": "ok", "data": {"batch_id": batch_id, "file_urls": urls}})

    def do_PUT(self) -> None:
        parts = self.path.strip("/").split("/")
        if len(parts) != 3 or parts[0] != "upload":
            self.send_error(404)
            return
        if self.headers.get("Content-Type"):
            self.send_json(403, {"code": 403, "msg": "signed upload must not include Content-Type"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        STATE.uploads[f"{parts[1]}/{parts[2]}"] = self.rfile.read(length)
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path.startswith("/api/v4/extract-results/batch/"):
            if not self.authenticated():
                return
            batch_id = parsed.path.rsplit("/", 1)[-1]
            items = STATE.batches.get(batch_id)
            if items is None:
                self.send_error(404)
                return
            with STATE.lock:
                STATE.polls[batch_id] = STATE.polls.get(batch_id, 0) + 1
                poll_count = STATE.polls[batch_id]
            host = f"http://127.0.0.1:{self.server.server_address[1]}"
            results = [
                {
                    "data_id": item["data_id"],
                    "file_name": item["name"],
                    "state": "running" if "resume" in item["name"].lower() and poll_count == 1 else "done",
                    "full_zip_url": f"{host}/result/{batch_id}/{item['data_id']}.zip",
                }
                for item in items
            ]
            self.send_json(200, {"code": 0, "msg": "ok", "data": {"extract_result": results}})
            return
        if parsed.path.startswith("/result/") and parsed.path.endswith(".zip"):
            data_id = parsed.path.rsplit("/", 1)[-1][:-4]
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("full.md", "# Mock paper\n\n![Figure](images/figure.png)\n\nFormula: $E=mc^2$\n")
                archive.writestr("images/figure.png", PNG)
                if "evil" in data_id:
                    archive.writestr("../escape.txt", "unsafe")
            payload = stream.getvalue()
            self.send_response(200)
            self.send_header("Content-Type", "application/zip")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_error(404)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready-file", required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    Path(args.ready_file).write_text(str(server.server_address[1]), encoding="ascii")
    server.serve_forever()


if __name__ == "__main__":
    main()
