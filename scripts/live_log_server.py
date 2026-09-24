#!/usr/bin/env python3
"""Small authenticated HTTP server for streaming a GitHub Actions build log."""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import mimetypes
import os
import platform
import re
import shutil
import socket
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlsplit

from live_dashboard import DashboardAnalyzer, inspect_deb, list_deb_packages


MAX_CHUNK_BYTES = 512 * 1024
MAX_PREVIEW_BYTES = 512 * 1024
MAX_DIRECTORY_ENTRIES = 2000
STREAM_CHUNK_BYTES = 64 * 1024
TERMINAL_STATES = frozenset({"success", "failure", "disabled"})
INDEX_HTML_PATH = Path(__file__).with_name("live_log_page.html")
REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
PREVIEWABLE_SUFFIXES = frozenset(
    {
        ".conf",
        ".config",
        ".csv",
        ".env",
        ".ini",
        ".json",
        ".log",
        ".md",
        ".sha256",
        ".sha512",
        ".sums",
        ".toml",
        ".tsv",
        ".txt",
        ".xml",
        ".yaml",
        ".yml",
    }
)
PREVIEWABLE_NAMES = frozenset({"sha256sums", "sha512sums"})


class ArtifactPathError(ValueError):
    """A requested artifact path is invalid or outside the published root."""


class ArtifactNotFoundError(FileNotFoundError):
    """A requested artifact path does not exist."""


class LiveLogServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        address: tuple[str, int],
        root: Path,
        auth_spec: str,
        *,
        files_root: Path | None,
        sse_poll_interval: float,
        sse_heartbeat_interval: float,
        metrics_interval: float,
    ):
        super().__init__(address, LiveLogHandler)
        self.root = root
        self.files_root = files_root
        self.sse_poll_interval = sse_poll_interval
        self.sse_heartbeat_interval = sse_heartbeat_interval
        self.metrics_interval = metrics_interval
        self.started_at = time.monotonic()
        self.index_html = INDEX_HTML_PATH.read_bytes()
        self.dashboard = DashboardAnalyzer(
            root / "build.log", files_root, REPOSITORY_ROOT
        )
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

    def _write_json(self, status: HTTPStatus, payload: dict[str, object]) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode(
            "utf-8"
        )
        self._write(status, "application/json; charset=utf-8", body)

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
            kernels = re.findall(r"Built kernel major version:\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?)", tail)
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
        result = {
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
        self.server.dashboard.record_metrics(result)
        return result

    def _serve_metrics(self) -> None:
        payload = json.dumps(self._metrics(), ensure_ascii=False).encode("utf-8")
        self._write(HTTPStatus.OK, "application/json; charset=utf-8", payload)

    def _serve_dashboard(self) -> None:
        status = self._status()
        self._write_json(
            HTTPStatus.OK,
            self.server.dashboard.snapshot(str(status.get("state", "running"))),
        )

    def _serve_packages(self) -> None:
        self._write_json(HTTPStatus.OK, list_deb_packages(self.server.files_root))

    def _serve_package(self, query: str) -> None:
        path, relative = self._artifact_path(query)
        if not path.is_file() or path.suffix.casefold() != ".deb":
            raise ArtifactPathError("The requested path is not a Debian package")
        payload = inspect_deb(path)
        payload.update({"path": relative, "name": path.name})
        self._write_json(HTTPStatus.OK, payload)

    @staticmethod
    def _previewable(path: Path) -> bool:
        return (
            path.suffix.casefold() in PREVIEWABLE_SUFFIXES
            or path.name.casefold() in PREVIEWABLE_NAMES
        )

    def _artifact_path(
        self, query: str, *, require_exists: bool = True
    ) -> tuple[Path, str]:
        root = self.server.files_root
        if root is None:
            raise ArtifactNotFoundError("Artifact browsing is disabled")
        raw_path = parse_qs(query, keep_blank_values=True).get("path", [""])[0]
        if not isinstance(raw_path, str):
            raise ArtifactPathError("Invalid path")
        if "\x00" in raw_path or "\\" in raw_path or raw_path.startswith("/"):
            raise ArtifactPathError("Invalid path")
        parts = [] if raw_path == "" else raw_path.split("/")
        if any(
            not part or part in {".", ".."} or part.startswith(".") or ":" in part
            for part in parts
        ):
            raise ArtifactPathError("Invalid path")

        candidate = root.joinpath(*parts)
        current = root
        for part in parts:
            current = current / part
            if current.is_symlink():
                raise ArtifactPathError("Symbolic links are not published")
        try:
            resolved = candidate.resolve(strict=False)
            resolved.relative_to(root)
        except (OSError, RuntimeError, ValueError) as error:
            raise ArtifactPathError("Path escapes the published root") from error
        if require_exists and not resolved.exists():
            raise ArtifactNotFoundError("Artifact not found")
        return resolved, "/".join(parts)

    def _serve_files(self, query: str) -> None:
        if self.server.files_root is None:
            self._write_json(
                HTTPStatus.OK,
                {"enabled": False, "available": False, "path": "", "entries": []},
            )
            return
        directory, relative = self._artifact_path(query, require_exists=False)
        if not directory.exists():
            if relative:
                raise ArtifactNotFoundError("Directory not found")
            self._write_json(
                HTTPStatus.OK,
                {"enabled": True, "available": False, "path": "", "entries": []},
            )
            return
        if not directory.is_dir():
            raise ArtifactPathError("The requested path is not a directory")

        entries: list[dict[str, object]] = []
        try:
            children = [
                child
                for child in directory.iterdir()
                if not child.name.startswith(".") and not child.is_symlink()
            ]
            children.sort(key=lambda item: (not item.is_dir(), item.name.casefold()))
        except OSError as error:
            raise ArtifactNotFoundError("Directory is not readable") from error
        truncated = len(children) > MAX_DIRECTORY_ENTRIES
        for child in children[:MAX_DIRECTORY_ENTRIES]:
            try:
                stat_result = child.stat()
            except OSError:
                continue
            if child.is_dir():
                kind = "directory"
                size: int | None = None
            elif child.is_file():
                kind = "file"
                size = stat_result.st_size
            else:
                continue
            child_relative = child.relative_to(self.server.files_root).as_posix()
            entries.append(
                {
                    "name": child.name,
                    "path": child_relative,
                    "kind": kind,
                    "size": size,
                    "modified": int(stat_result.st_mtime),
                    "previewable": kind == "file" and self._previewable(child),
                }
            )
        self._write_json(
            HTTPStatus.OK,
            {
                "enabled": True,
                "available": True,
                "path": relative,
                "entries": entries,
                "truncated": truncated,
                "limit": MAX_DIRECTORY_ENTRIES,
            },
        )

    def _serve_file_preview(self, query: str) -> None:
        path, relative = self._artifact_path(query)
        if not path.is_file() or not self._previewable(path):
            self._write_json(
                HTTPStatus.UNSUPPORTED_MEDIA_TYPE,
                {"error": "preview_unavailable"},
            )
            return
        try:
            size = path.stat().st_size
            with path.open("rb") as artifact:
                data = artifact.read(MAX_PREVIEW_BYTES + 1)
        except OSError as error:
            raise ArtifactNotFoundError("Artifact is not readable") from error
        truncated = len(data) > MAX_PREVIEW_BYTES
        data = data[:MAX_PREVIEW_BYTES]
        if b"\x00" in data:
            self._write_json(
                HTTPStatus.UNSUPPORTED_MEDIA_TYPE,
                {"error": "preview_unavailable"},
            )
            return
        self._write_json(
            HTTPStatus.OK,
            {
                "path": relative,
                "name": path.name,
                "size": size,
                "modified": int(path.stat().st_mtime),
                "text": data.decode("utf-8", errors="replace"),
                "truncated": truncated,
                "limit": MAX_PREVIEW_BYTES,
            },
        )

    def _serve_file_hash(self, query: str) -> None:
        path, relative = self._artifact_path(query)
        if not path.is_file():
            raise ArtifactPathError("The requested path is not a file")
        digest = hashlib.sha256()
        try:
            with path.open("rb") as artifact:
                while chunk := artifact.read(STREAM_CHUNK_BYTES):
                    digest.update(chunk)
            size = path.stat().st_size
        except OSError as error:
            raise ArtifactNotFoundError("Artifact is not readable") from error
        self._write_json(
            HTTPStatus.OK,
            {
                "path": relative,
                "name": path.name,
                "size": size,
                "algorithm": "sha256",
                "digest": digest.hexdigest(),
            },
        )

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

    @staticmethod
    def _download_name(name: str) -> str:
        fallback = re.sub(r"[^A-Za-z0-9._-]", "_", name).strip(".") or "download"
        return f'attachment; filename="{fallback}"; filename*=UTF-8\'\'{quote(name, safe="")}'

    @staticmethod
    def _byte_range(value: str, size: int) -> tuple[int, int] | None:
        if not value:
            return None
        match = re.fullmatch(r"bytes=(\d*)-(\d*)", value.strip())
        if not match or not (match.group(1) or match.group(2)) or size <= 0:
            raise ValueError("Invalid byte range")
        start_text, end_text = match.groups()
        if start_text:
            start = int(start_text)
            end = int(end_text) if end_text else size - 1
            if start >= size or end < start:
                raise ValueError("Unsatisfiable byte range")
            return start, min(end, size - 1)
        suffix_length = int(end_text)
        if suffix_length <= 0:
            raise ValueError("Invalid byte range")
        return max(size - suffix_length, 0), size - 1

    def _stream_download(self, path: Path, download_name: str, content_type: str) -> None:
        try:
            size = path.stat().st_size
            byte_range = self._byte_range(self.headers.get("Range", ""), size)
        except FileNotFoundError:
            size = 0
            byte_range = None
        except ValueError:
            self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
            self.send_header("Content-Range", f"bytes */{size}")
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return

        start, end = byte_range if byte_range is not None else (0, max(size - 1, -1))
        length = max(end - start + 1, 0)
        self.send_response(
            HTTPStatus.PARTIAL_CONTENT if byte_range is not None else HTTPStatus.OK
        )
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Disposition", self._download_name(download_name))
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        if byte_range is not None:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if not length:
            return
        try:
            with path.open("rb") as artifact:
                artifact.seek(start)
                remaining = length
                while remaining:
                    chunk = artifact.read(min(STREAM_CHUNK_BYTES, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionAbortedError, ConnectionResetError):
            return

    def _serve_download(self) -> None:
        self._stream_download(
            self.server.root / "build.log",
            "armbian-kernel-build.log",
            "text/plain; charset=utf-8",
        )

    def _serve_artifact_download(self, query: str) -> None:
        path, _ = self._artifact_path(query)
        if not path.is_file():
            raise ArtifactPathError("The requested path is not a file")
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        self._stream_download(path, path.name, content_type)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        target = urlsplit(self.path)
        if target.path == "/healthz":
            self._write(HTTPStatus.OK, "text/plain; charset=utf-8", b"ok\n")
            return
        if not self._authorized():
            return
        try:
            if target.path == "/":
                self._write(
                    HTTPStatus.OK, "text/html; charset=utf-8", self.server.index_html
                )
            elif target.path == "/api/events":
                self._serve_events(target.query)
            elif target.path == "/api/log":
                self._serve_increment(target.query)
            elif target.path == "/api/metrics":
                self._serve_metrics()
            elif target.path == "/api/dashboard":
                self._serve_dashboard()
            elif target.path == "/api/packages":
                self._serve_packages()
            elif target.path == "/api/package":
                self._serve_package(target.query)
            elif target.path == "/api/files":
                self._serve_files(target.query)
            elif target.path == "/api/file":
                self._serve_file_preview(target.query)
            elif target.path == "/api/file-hash":
                self._serve_file_hash(target.query)
            elif target.path == "/files/download":
                self._serve_artifact_download(target.query)
            elif target.path == "/download":
                self._serve_download()
            else:
                self._write(HTTPStatus.NOT_FOUND, "text/plain; charset=utf-8", b"Not found\n")
        except ArtifactPathError as error:
            self._write_json(
                HTTPStatus.BAD_REQUEST,
                {"error": "invalid_path", "detail": str(error)},
            )
        except ArtifactNotFoundError as error:
            self._write_json(
                HTTPStatus.NOT_FOUND,
                {"error": "not_found", "detail": str(error)},
            )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument(
        "--files-directory",
        type=Path,
        help="optional read-only root exposed by the build artifact browser",
    )
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
    files_root = args.files_directory.resolve() if args.files_directory else None
    server = LiveLogServer(
        (args.host, args.port),
        root,
        auth_spec,
        files_root=files_root,
        sse_poll_interval=args.sse_poll_interval,
        sse_heartbeat_interval=args.sse_heartbeat_interval,
        metrics_interval=args.metrics_interval,
    )
    print(f"[live-log-http] listening on http://{args.host}:{args.port}", flush=True)
    if files_root is not None:
        print(f"[live-log-http] read-only files root: {files_root}", flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
