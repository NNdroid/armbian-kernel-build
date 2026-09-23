#!/usr/bin/env python3
"""Small authenticated HTTP server for streaming a GitHub Actions build log."""

from __future__ import annotations

import argparse
import base64
import hmac
import json
import os
import platform
import re
import shutil
import socket
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


MAX_CHUNK_BYTES = 512 * 1024
TERMINAL_STATES = frozenset({"success", "failure", "disabled"})
INDEX_HTML_PATH = Path(__file__).with_name("live_log_page.html")

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
        metrics_interval: float,
    ):
        super().__init__(address, LiveLogHandler)
        self.root = root
        self.sse_poll_interval = sse_poll_interval
        self.sse_heartbeat_interval = sse_heartbeat_interval
        self.metrics_interval = metrics_interval
        self.started_at = time.monotonic()
        self.index_html = INDEX_HTML_PATH.read_bytes()
        self.target = {
            "board": os.environ.get("LIVE_LOG_BOARD", "nanopi-r5s"),
            "arch": os.environ.get("LIVE_LOG_ARCH", "arm64"),
            "family": os.environ.get("LIVE_LOG_FAMILY", "rockchip64"),
            "release": os.environ.get("LIVE_LOG_RELEASE", "trixie"),
        }
        self.run = {
            "repository": os.environ.get("GITHUB_REPOSITORY", ""),
            "run_id": os.environ.get("GITHUB_RUN_ID", ""),
            "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""),
            "runner_name": os.environ.get("RUNNER_NAME", ""),
        }
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

    @staticmethod
    def _memory_usage() -> tuple[int, int]:
        values: dict[str, int] = {}
        try:
            with Path("/proc/meminfo").open(encoding="utf-8") as meminfo:
                for line in meminfo:
                    key, separator, value = line.partition(":")
                    if separator:
                        values[key] = int(value.strip().split()[0]) * 1024
        except (FileNotFoundError, OSError, ValueError, IndexError):
            return 0, 0
        total = values.get("MemTotal", 0)
        available = values.get("MemAvailable", values.get("MemFree", 0))
        return max(total - available, 0), total

    @staticmethod
    def _cpu_model() -> str:
        try:
            for line in Path("/proc/cpuinfo").read_text(encoding="utf-8").splitlines():
                key, separator, value = line.partition(":")
                if separator and key.strip() in {"model name", "Hardware", "Model"}:
                    return value.strip()[:120]
        except OSError:
            pass
        return platform.processor()[:120] or "unknown"

    def _build_details(self) -> dict[str, str]:
        log_path = self.server.root / "build.log"
        try:
            size = log_path.stat().st_size
            with log_path.open("rb") as log_file:
                log_file.seek(max(0, size - 256 * 1024))
                tail = log_file.read().decode("utf-8", errors="replace")
        except OSError:
            return {"branch": "", "kernel": ""}

        branches = re.findall(r"\bBRANCH=([A-Za-z0-9._-]+)", tail)
        kernels = re.findall(r"__([0-9]+\.[0-9]+(?:\.[0-9]+)?)-[A-Za-z0-9]", tail)
        if not kernels:
            kernels = re.findall(r"实际构建内核大版本:\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?)", tail)
        return {
            "branch": branches[-1] if branches else "",
            "kernel": kernels[-1] if kernels else "",
        }

    def _metrics(self) -> dict[str, object]:
        cpu_count = os.cpu_count() or 1
        try:
            load1, load5, load15 = os.getloadavg()
        except (AttributeError, OSError):
            load1 = load5 = load15 = 0.0
        memory_used, memory_total = self._memory_usage()
        try:
            disk = shutil.disk_usage(self.server.root)
            disk_used, disk_total = disk.used, disk.total
        except OSError:
            disk_used = disk_total = 0
        try:
            log_bytes = (self.server.root / "build.log").stat().st_size
        except OSError:
            log_bytes = 0
        build = self._build_details()
        return {
            "generated_at": int(time.time()),
            "elapsed_seconds": max(int(time.monotonic() - self.server.started_at), 0),
            "state": self._status()["state"],
            "target": {**self.server.target, **build},
            "host": {
                "hostname": socket.gethostname(),
                "os": f"{platform.system()} {platform.release()}",
                "cpu_count": cpu_count,
                "cpu_model": self._cpu_model(),
            },
            "usage": {
                "load1": round(load1, 2),
                "load5": round(load5, 2),
                "load15": round(load15, 2),
                "load_percent": round(min(max(load1 / cpu_count * 100, 0), 100), 1),
                "memory_used": memory_used,
                "memory_total": memory_total,
                "memory_percent": round(memory_used / memory_total * 100, 1)
                if memory_total
                else 0,
                "disk_used": disk_used,
                "disk_total": disk_total,
                "disk_percent": round(disk_used / disk_total * 100, 1) if disk_total else 0,
            },
            "run": self.server.run,
            "log_bytes": log_bytes,
        }

    def _serve_metrics(self) -> None:
        payload = json.dumps(self._metrics(), ensure_ascii=False).encode("utf-8")
        self._write(HTTPStatus.OK, "application/json; charset=utf-8", payload)

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
        next_metrics = 0.0
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

                now = time.monotonic()
                if now >= next_metrics:
                    self._write_sse_event("metrics", self._metrics())
                    next_metrics = now + self.server.metrics_interval

                state = str(status["state"])
                if not text and state in TERMINAL_STATES:
                    self._write_sse_event(
                        "complete", {**status, "offset": offset}, event_id=offset
                    )
                    self.close_connection = True
                    return

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
            self._write(HTTPStatus.OK, "text/html; charset=utf-8", self.server.index_html)
        elif target.path == "/api/events":
            self._serve_events(target.query)
        elif target.path == "/api/log":
            self._serve_increment(target.query)
        elif target.path == "/api/metrics":
            self._serve_metrics()
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
    parser.add_argument("--metrics-interval", default=2.0, type=float)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    auth_spec = os.environ.get("LIVE_LOG_AUTH", "")
    if not auth_spec or ":" not in auth_spec:
        raise SystemExit("LIVE_LOG_AUTH must be set to username:password")
    if (
        args.sse_poll_interval <= 0
        or args.sse_heartbeat_interval <= 0
        or args.metrics_interval <= 0
    ):
        raise SystemExit("SSE and metrics intervals must be greater than zero")
    root = args.directory.resolve()
    root.mkdir(parents=True, exist_ok=True)
    server = LiveLogServer(
        (args.host, args.port),
        root,
        auth_spec,
        sse_poll_interval=args.sse_poll_interval,
        sse_heartbeat_interval=args.sse_heartbeat_interval,
        metrics_interval=args.metrics_interval,
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
