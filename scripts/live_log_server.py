#!/usr/bin/env python3
"""Small authenticated HTTP server for streaming a GitHub Actions build log."""

from __future__ import annotations

import argparse
import base64
import hmac
import json
import os
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


MAX_CHUNK_BYTES = 512 * 1024

INDEX_HTML = r"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Armbian Kernel Build Live Log</title>
  <style>
    :root { color-scheme: dark; font-family: ui-monospace, SFMono-Regular, Consolas, monospace; }
    body { margin: 0; background: #0d1117; color: #c9d1d9; }
    header { position: sticky; top: 0; padding: 12px 16px; background: #161b22; border-bottom: 1px solid #30363d; }
    h1 { display: inline; margin: 0 18px 0 0; font-size: 16px; }
    #state { color: #58a6ff; }
    a { color: #58a6ff; }
    pre { margin: 0; padding: 16px; white-space: pre-wrap; overflow-wrap: anywhere; line-height: 1.35; }
    .muted { color: #8b949e; font-size: 12px; }
  </style>
</head>
<body>
  <header>
    <h1>Armbian Kernel Build</h1>
    <span id="state">connecting</span>
    <span class="muted"> · browser keeps the latest 5 MiB · </span>
    <a href="/download">download current log</a>
  </header>
  <pre id="log"></pre>
  <script>
    const output = document.getElementById('log');
    const state = document.getElementById('state');
    const maxChars = 5 * 1024 * 1024;
    let offset = 0;
    let busy = false;
    const ansi = /\x1B(?:[@-_]|\[[0-?]*[ -/]*[@-~])/g;

    async function poll() {
      if (busy) return;
      busy = true;
      try {
        const response = await fetch(`/api/log?offset=${offset}`, {cache: 'no-store'});
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const payload = await response.json();
        if (payload.reset) output.textContent = '';
        offset = payload.offset;
        if (payload.text) {
          output.textContent += payload.text.replace(ansi, '');
          if (output.textContent.length > maxChars) {
            output.textContent = output.textContent.slice(-maxChars);
          }
          window.scrollTo(0, document.body.scrollHeight);
        }
        state.textContent = payload.state || 'running';
      } catch (error) {
        state.textContent = `disconnected: ${error.message}`;
      } finally {
        busy = false;
      }
    }

    poll();
    setInterval(poll, 1500);
  </script>
</body>
</html>
"""


class LiveLogServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], root: Path, auth_spec: str):
        super().__init__(address, LiveLogHandler)
        self.root = root
        encoded = base64.b64encode(auth_spec.encode("utf-8")).decode("ascii")
        self.expected_authorization = f"Basic {encoded}"


class LiveLogHandler(BaseHTTPRequestHandler):
    server: LiveLogServer

    def log_message(self, format_string: str, *args: object) -> None:
        print(f"[live-log-http] {self.address_string()} {format_string % args}", flush=True)

    def _send_headers(self, status: HTTPStatus, content_type: str, length: int) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        if content_type.startswith("text/html"):
            self.send_header(
                "Content-Security-Policy",
                "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'",
            )
        self.end_headers()

    def _write(self, status: HTTPStatus, content_type: str, body: bytes) -> None:
        self._send_headers(status, content_type, len(body))
        self.wfile.write(body)

    def _authorized(self) -> bool:
        supplied = self.headers.get("Authorization", "")
        if hmac.compare_digest(supplied, self.server.expected_authorization):
            return True
        body = b"Authentication required\n"
        self.send_response(HTTPStatus.UNAUTHORIZED)
        self.send_header("WWW-Authenticate", 'Basic realm="Armbian build log"')
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)
        return False

    def _state(self) -> str:
        status_path = self.server.root / "status.json"
        try:
            payload = json.loads(status_path.read_text(encoding="utf-8"))
            value = payload.get("state", "running")
            return value if isinstance(value, str) else "running"
        except (OSError, json.JSONDecodeError):
            return "running"

    def _serve_increment(self, query: str) -> None:
        values = parse_qs(query)
        try:
            offset = int(values.get("offset", ["0"])[0])
        except ValueError:
            offset = 0
        offset = max(offset, 0)
        log_path = self.server.root / "build.log"
        reset = False
        text = ""
        next_offset = 0
        try:
            size = log_path.stat().st_size
            if offset > size:
                offset = 0
                reset = True
            with log_path.open("rb") as log_file:
                log_file.seek(offset)
                data = log_file.read(MAX_CHUNK_BYTES)
                next_offset = log_file.tell()
            text = data.decode("utf-8", errors="replace")
        except FileNotFoundError:
            next_offset = 0
        payload = json.dumps(
            {"offset": next_offset, "reset": reset, "state": self._state(), "text": text},
            ensure_ascii=False,
        ).encode("utf-8")
        self._write(HTTPStatus.OK, "application/json; charset=utf-8", payload)

    def _serve_download(self) -> None:
        log_path = self.server.root / "build.log"
        try:
            body = log_path.read_bytes()
        except FileNotFoundError:
            body = b""
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Disposition", 'attachment; filename="armbian-kernel-build.log"')
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        target = urlsplit(self.path)
        if target.path == "/healthz":
            self._write(HTTPStatus.OK, "text/plain; charset=utf-8", b"ok\n")
            return
        if not self._authorized():
            return
        if target.path == "/":
            self._write(HTTPStatus.OK, "text/html; charset=utf-8", INDEX_HTML.encode("utf-8"))
        elif target.path == "/api/log":
            self._serve_increment(target.query)
        elif target.path == "/download":
            self._serve_download()
        else:
            self._write(HTTPStatus.NOT_FOUND, "text/plain; charset=utf-8", b"Not found\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8080, type=int)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    auth_spec = os.environ.get("LIVE_LOG_AUTH", "")
    if not auth_spec or ":" not in auth_spec:
        raise SystemExit("LIVE_LOG_AUTH must be set to username:password")
    root = args.directory.resolve()
    root.mkdir(parents=True, exist_ok=True)
    server = LiveLogServer((args.host, args.port), root, auth_spec)
    print(f"[live-log-http] listening on http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
