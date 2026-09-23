#!/usr/bin/env python3
"""Small authenticated HTTP server for streaming a GitHub Actions build log."""

from __future__ import annotations

import argparse
import base64
import hmac
import json
import os
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


MAX_CHUNK_BYTES = 512 * 1024
TERMINAL_STATES = frozenset({"success", "failure", "disabled"})

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
    let eventSource = null;
    let pollingTimer = null;
    let sseFailures = 0;
    // CSI sequences must be matched before the shorter two-byte ESC form.
    // Otherwise ESC[ is consumed alone and fragments such as "0m" remain.
    const ansi = /\x1B(?:\[[0-?]*[ -/]*[@-~]|[@-_])/g;

    function appendLog(text) {
      if (!text) return;
      output.textContent += text.replace(ansi, '');
      if (output.textContent.length > maxChars) {
        output.textContent = output.textContent.slice(-maxChars);
      }
      window.scrollTo(0, document.body.scrollHeight);
    }

    async function poll() {
      if (busy) return;
      busy = true;
      try {
        const response = await fetch(`/api/log?offset=${offset}`, {cache: 'no-store'});
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const payload = await response.json();
        if (payload.reset) output.textContent = '';
        offset = payload.offset;
        appendLog(payload.text);
        state.textContent = payload.state || 'running';
        if (['success', 'failure', 'disabled'].includes(payload.state) && pollingTimer) {
          clearInterval(pollingTimer);
          pollingTimer = null;
        }
      } catch (error) {
        state.textContent = `disconnected: ${error.message}`;
      } finally {
        busy = false;
      }
    }

    function startPolling(reason) {
      if (pollingTimer) return;
      if (eventSource) {
        eventSource.close();
        eventSource = null;
      }
      state.textContent = `polling fallback: ${reason}`;
      pollingTimer = setInterval(poll, 1500);
      poll();
    }

    function startEventStream() {
      if (!window.EventSource) {
        startPolling('SSE unsupported');
        return;
      }

      eventSource = new EventSource(`/api/events?offset=${offset}`, {withCredentials: true});
      eventSource.onopen = () => {
        state.textContent = 'connected (SSE)';
      };
      eventSource.addEventListener('log', (event) => {
        sseFailures = 0;
        const payload = JSON.parse(event.data);
        offset = payload.offset;
        appendLog(payload.text);
      });
      eventSource.addEventListener('reset', (event) => {
        const payload = JSON.parse(event.data);
        output.textContent = '';
        offset = payload.offset || 0;
      });
      eventSource.addEventListener('state', (event) => {
        sseFailures = 0;
        const payload = JSON.parse(event.data);
        state.textContent = payload.state || 'running';
      });
      eventSource.addEventListener('complete', (event) => {
        const payload = JSON.parse(event.data);
        state.textContent = payload.state || 'complete';
        offset = payload.offset ?? offset;
        eventSource.close();
        eventSource = null;
      });
      eventSource.onerror = () => {
        sseFailures += 1;
        state.textContent = 'SSE reconnecting';
        if (sseFailures >= 3) startPolling('repeated SSE errors');
      };
    }

    startEventStream();
  </script>
</body>
</html>
"""


class LiveLogServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        address: tuple[str, int],
        root: Path,
        auth_spec: str,
        *,
        sse_poll_interval: float,
        sse_heartbeat_interval: float,
    ):
        super().__init__(address, LiveLogHandler)
        self.root = root
        self.sse_poll_interval = sse_poll_interval
        self.sse_heartbeat_interval = sse_heartbeat_interval
        encoded = base64.b64encode(auth_spec.encode("utf-8")).decode("ascii")
        self.expected_authorization = f"Basic {encoded}"


class LiveLogHandler(BaseHTTPRequestHandler):
    server: LiveLogServer
    protocol_version = "HTTP/1.1"

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

    def _status(self) -> dict[str, object]:
        status_path = self.server.root / "status.json"
        try:
            payload = json.loads(status_path.read_text(encoding="utf-8"))
            if not isinstance(payload, dict):
                return {"state": "running"}
            value = payload.get("state", "running")
            state = value if isinstance(value, str) else "running"
            result: dict[str, object] = {"state": state}
            exit_code = payload.get("exit_code")
            if isinstance(exit_code, int):
                result["exit_code"] = exit_code
            return result
        except (OSError, json.JSONDecodeError):
            return {"state": "running"}

    def _read_log_chunk(self, offset: int) -> tuple[int, bool, str]:
        log_path = self.server.root / "build.log"
        reset = False
        try:
            size = log_path.stat().st_size
            if offset > size:
                offset = 0
                reset = True
            with log_path.open("rb") as log_file:
                log_file.seek(offset)
                data = log_file.read(MAX_CHUNK_BYTES)
                reached_eof = log_file.tell() >= size

            if data and not reached_eof:
                last_newline = data.rfind(b"\n")
                if last_newline >= 0:
                    data = data[: last_newline + 1]

            next_offset = offset + len(data)
            while data:
                try:
                    text = data.decode("utf-8")
                    break
                except UnicodeDecodeError as error:
                    if error.reason == "unexpected end of data" and error.end == len(data):
                        data = data[: error.start]
                        next_offset = offset + len(data)
                        continue
                    text = data.decode("utf-8", errors="replace")
                    break
            else:
                text = ""
            return next_offset, reset, text
        except FileNotFoundError:
            return 0, reset, ""

    def _serve_increment(self, query: str) -> None:
        values = parse_qs(query)
        try:
            offset = int(values.get("offset", ["0"])[0])
        except ValueError:
            offset = 0
        offset = max(offset, 0)
        next_offset, reset, text = self._read_log_chunk(offset)
        status = self._status()
        payload = json.dumps(
            {
                "offset": next_offset,
                "reset": reset,
                "state": status["state"],
                "text": text,
            },
            ensure_ascii=False,
        ).encode("utf-8")
        self._write(HTTPStatus.OK, "application/json; charset=utf-8", payload)

    def _requested_sse_offset(self, query: str) -> int:
        candidates = [self.headers.get("Last-Event-ID", "")]
        candidates.extend(parse_qs(query).get("offset", []))
        for candidate in candidates:
            try:
                return max(int(candidate), 0)
            except (TypeError, ValueError):
                continue
        return 0

    def _write_sse_event(
        self, event: str, payload: dict[str, object], *, event_id: int | None = None
    ) -> None:
        lines: list[str] = []
        if event_id is not None:
            lines.append(f"id: {event_id}")
        lines.append(f"event: {event}")
        lines.append(f"data: {json.dumps(payload, ensure_ascii=False, separators=(',', ':'))}")
        self.wfile.write(("\n".join(lines) + "\n\n").encode("utf-8"))
        self.wfile.flush()

    def _serve_events(self, query: str) -> None:
        offset = self._requested_sse_offset(query)
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache, no-transform")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()

        last_status: dict[str, object] | None = None
        next_heartbeat = time.monotonic() + self.server.sse_heartbeat_interval
        try:
            self.wfile.write(b"retry: 1500\n\n")
            self.wfile.flush()
            while True:
                next_offset, reset, text = self._read_log_chunk(offset)
                if reset:
                    offset = 0
                    self._write_sse_event("reset", {"offset": 0}, event_id=0)
                if text:
                    offset = next_offset
                    self._write_sse_event(
                        "log", {"offset": offset, "text": text}, event_id=offset
                    )

                status = self._status()
                if status != last_status:
                    self._write_sse_event("state", status)
                    last_status = status

                state = str(status["state"])
                if not text and state in TERMINAL_STATES:
                    self._write_sse_event(
                        "complete", {**status, "offset": offset}, event_id=offset
                    )
                    self.close_connection = True
                    return

                now = time.monotonic()
                if now >= next_heartbeat:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    next_heartbeat = now + self.server.sse_heartbeat_interval
                if text:
                    continue
                time.sleep(self.server.sse_poll_interval)
        except (BrokenPipeError, ConnectionAbortedError, ConnectionResetError):
            return

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
        elif target.path == "/api/events":
            self._serve_events(target.query)
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
    parser.add_argument("--sse-poll-interval", default=0.25, type=float)
    parser.add_argument("--sse-heartbeat-interval", default=15.0, type=float)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    auth_spec = os.environ.get("LIVE_LOG_AUTH", "")
    if not auth_spec or ":" not in auth_spec:
        raise SystemExit("LIVE_LOG_AUTH must be set to username:password")
    if args.sse_poll_interval <= 0 or args.sse_heartbeat_interval <= 0:
        raise SystemExit("SSE intervals must be greater than zero")
    root = args.directory.resolve()
    root.mkdir(parents=True, exist_ok=True)
    server = LiveLogServer(
        (args.host, args.port),
        root,
        auth_spec,
        sse_poll_interval=args.sse_poll_interval,
        sse_heartbeat_interval=args.sse_heartbeat_interval,
    )
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
