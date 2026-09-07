#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import io
import json
import threading
import time
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
        self.delay = 0.0
        self.active = 0
        self.max_active = 0
        self.attempts = {}
        self.downloads = []
        self.poll_events = []
        self.rejections = {}


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
        for document in request['files']:
            name = document['name']
            for scenario, status, code, message in (
                ('rejectquota', 429, 429, 'rate limit'),
                ('rejectvalidation', 422, 422, 'invalid parameter'),
                ('rejectlogical', 200, 'REQUEST_INVALID', 'invalid request'),
            ):
                if scenario in name and STATE.rejections.get(name, 0) == 0:
                    STATE.rejections[name] = 1
                    self.send_json(status, {'code': code, 'msg': message})
                    return
            if 'authstop' in name:
                self.send_json(401, {'code': 401, 'msg': 'invalid token'})
                return
        with STATE.lock:
            STATE.counter += 1
            batch_id = f"batch-{STATE.counter}"
            STATE.batches[batch_id] = request["files"]
        host = f"http://127.0.0.1:{self.server.server_address[1]}"
        urls = [f"{host}/upload/{batch_id}/{item['data_id']}" for item in request["files"]]
        if any('submitunknown' in item['name'] for item in request['files']):
            self.send_json(503, {'msg': 'response lost after batch allocation'})
            return
        self.send_json(200, {"code": 0, "msg": "ok", "data": {"batch_id": batch_id, "file_urls": urls}})

    def do_PUT(self) -> None:
        parts = self.path.strip("/").split("/")
        if len(parts) != 3 or parts[0] != "upload":
            self.send_error(404)
            return
        if self.headers.get("Content-Type") or self.headers.get("Authorization"):
            self.send_json(403, {"code": 403, "msg": "signed upload must not include Content-Type"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        key = f"{parts[1]}/{parts[2]}"
        body = self.rfile.read(length)
        with STATE.lock:
            STATE.attempts[key] = STATE.attempts.get(key, 0) + 1
            attempt = STATE.attempts[key]
        if 'uploadfail' in key and attempt == 1:
            self.send_json(503, {"msg": "injected upload interruption"})
            return
        self.transfer_delay()
        STATE.uploads[key] = body
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path.startswith('/api/v4/authprobe/'):
            case = parsed.path.rsplit('/', 1)[-1]
            status, body = {
                'quota403': (403, {'code': 403, 'msg': 'token quota exceeded'}),
                'rate429': (429, {'code': 429, 'msg': 'rate limit'}),
                'server503': (503, {'code': 503, 'msg': 'server unavailable'}),
                'quota200': (200, {'code': 1001, 'msg': 'token quota exceeded'}),
                'invalid200': (200, {'code': 1002, 'msg': 'token is expired'}),
                'ambiguous200': (200, {'code': 'INTERNAL', 'msg': 'internal service failure'}),
            }[case]
            self.send_json(status, body)
            return
        if parsed.path == '/stats':
            self.send_json(200, {'batches': STATE.counter, 'attempts': STATE.attempts,
                                'max_active': STATE.max_active, 'downloads': STATE.downloads,
                                'polls': STATE.poll_events})
            return
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
            if any('pollauth' in document['name'] for document in items) and STATE.polls[batch_id] > 1:
                self.send_json(401, {'code': 401, 'msg': 'token is expired'})
                return
            host = f"http://127.0.0.1:{self.server.server_address[1]}"
            STATE.poll_events.append([batch_id, poll_count, time.monotonic()])
            if any('pollerror' in item['name'] for item in items) and poll_count == 2:
                self.send_json(503, {'msg': 'synthetic transient polling failure'})
                return
            results = [
                {
                    "data_id": item["data_id"],
                    "file_name": item["name"],
                    "state": ("waiting-file" if f"{batch_id}/{item['data_id']}" not in STATE.uploads else
                              "failed" if 'parsefail' in item['name'].lower() else
                              "running" if ("resume" in item["name"].lower() and poll_count == 1) or
                              ("slow" in item['name'].lower() and poll_count < 3) else "done"),
                    "err_msg": "synthetic parsing failure",
                    "full_zip_url": f"{host}/result/{batch_id}/{item['data_id']}.zip",
                }
                for item in items
                if not ('omitted' in item['name'].lower() and poll_count == 1)
            ]
            self.send_json(200, {"code": 0, "msg": "ok", "data": {"extract_result": results}})
            return
        if parsed.path.startswith("/result/") and parsed.path.endswith(".zip"):
            if self.headers.get('Authorization'):
                self.send_error(403)
                return
            data_id = parsed.path.rsplit("/", 1)[-1][:-4]
            self.transfer_delay()
            STATE.downloads.append([data_id, time.monotonic()])
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED) as archive:
                markdown = "# Mock paper\n\n![Figure](images/figure.png)\n\nFormula: $E=mc^2$\n"
                if 'noimages' in data_id:
                    markdown = '# Text only\n\nNo images in this document.\n'
                if 'richimages' in data_id:
                    markdown = '# Figures\n\n![A](<images/a (1).png>)\n<img src="images/b%23.png">\n![B][figure]\n[figure]: images/figure.png\n\nProse: images/figure.png\n'
                    archive.writestr('images/a (1).png', PNG)
                    archive.writestr('images/b#.png', PNG)
                archive.writestr("full.md", markdown)
                if 'missingimage' not in data_id and 'noimages' not in data_id:
                    archive.writestr("images/figure.png", PNG)
                    archive.writestr("images/unused.png", PNG)
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

    def transfer_delay(self):
        with STATE.lock:
            STATE.active += 1
            STATE.max_active = max(STATE.max_active, STATE.active)
        time.sleep(STATE.delay)
        with STATE.lock:
            STATE.active -= 1


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--delay", type=float, default=0.0)
    args = parser.parse_args()
    STATE.delay = args.delay
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    Path(args.ready_file).write_text(str(server.server_address[1]), encoding="ascii")
    server.serve_forever()


if __name__ == "__main__":
    main()
