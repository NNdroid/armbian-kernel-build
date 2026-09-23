#!/usr/bin/env python3
"""Integration checks for the authenticated live-log HTTP server."""

from __future__ import annotations

import base64
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SERVER_SCRIPT = REPOSITORY_ROOT / "scripts" / "live_log_server.py"
AUTH_SPEC = "ci-user:a-long-test-password"
AUTH_HEADER = "Basic " + base64.b64encode(AUTH_SPEC.encode("utf-8")).decode("ascii")


def reserve_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def request(url: str, *, authenticated: bool = False) -> tuple[int, bytes, dict[str, str]]:
    headers = {"Authorization": AUTH_HEADER} if authenticated else {}
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=2) as response:
            return response.status, response.read(), dict(response.headers.items())
    except urllib.error.HTTPError as error:
        return error.code, error.read(), dict(error.headers.items())


def open_sse(
    url: str, *, last_event_id: int | None = None
) -> urllib.response.addinfourl:
    headers = {
        "Accept": "text/event-stream",
        "Authorization": AUTH_HEADER,
    }
    if last_event_id is not None:
        headers["Last-Event-ID"] = str(last_event_id)
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=3)


def read_sse_frame(response: urllib.response.addinfourl) -> dict[str, object]:
    event = "message"
    event_id: str | None = None
    data: list[str] = []
    comments: list[str] = []
    while True:
        raw_line = response.readline()
        if not raw_line:
            raise AssertionError("SSE stream closed before the expected frame")
        line = raw_line.decode("utf-8").rstrip("\r\n")
        if not line:
            if data or comments or event_id is not None or event != "message":
                return {
                    "event": event,
                    "id": event_id,
                    "data": "\n".join(data),
                    "comments": comments,
                }
            continue
        if line.startswith(":"):
            comments.append(line[1:].lstrip())
            continue
        field, separator, value = line.partition(":")
        if separator and value.startswith(" "):
            value = value[1:]
        if field == "event":
            event = value
        elif field == "id":
            event_id = value
        elif field == "data":
            data.append(value)


def read_until_event(
    response: urllib.response.addinfourl, event_name: str, *, limit: int = 20
) -> dict[str, object]:
    frames: list[dict[str, object]] = []
    for _ in range(limit):
        frame = read_sse_frame(response)
        frames.append(frame)
        if frame["event"] == event_name:
            return frame
    raise AssertionError(f"SSE event {event_name!r} not received: {frames!r}")


def read_until_heartbeat(
    response: urllib.response.addinfourl, *, limit: int = 20
) -> dict[str, object]:
    frames: list[dict[str, object]] = []
    for _ in range(limit):
        frame = read_sse_frame(response)
        frames.append(frame)
        if "keepalive" in frame["comments"]:
            return frame
    raise AssertionError(f"SSE heartbeat not received: {frames!r}")


def wait_until_ready(base_url: str, process: subprocess.Popen[bytes]) -> None:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            stdout, stderr = process.communicate()
            raise AssertionError(
                f"live-log server exited early ({process.returncode})\n"
                f"stdout: {stdout.decode(errors='replace')}\n"
                f"stderr: {stderr.decode(errors='replace')}"
            )
        try:
            status, body, _ = request(f"{base_url}/healthz")
            if status == 200 and body == b"ok\n":
                return
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(0.05)
    raise AssertionError("live-log server did not become ready")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="live-log-test-") as temp_directory:
        log_root = Path(temp_directory)
        (log_root / "build.log").write_bytes(b"first line\n")
        (log_root / "status.json").write_text(
            json.dumps({"state": "running"}), encoding="utf-8"
        )

        port = reserve_port()
        base_url = f"http://127.0.0.1:{port}"
        environment = os.environ.copy()
        environment["LIVE_LOG_AUTH"] = AUTH_SPEC
        environment["LIVE_LOG_BOARD"] = "test-board"
        environment["LIVE_LOG_ARCH"] = "test-arch"
        environment["LIVE_LOG_FAMILY"] = "test-family"
        environment["LIVE_LOG_RELEASE"] = "test-release"
        process = subprocess.Popen(
            [
                sys.executable,
                str(SERVER_SCRIPT),
                "--directory",
                str(log_root),
                "--port",
                str(port),
                "--sse-poll-interval",
                "0.02",
                "--sse-heartbeat-interval",
                "0.15",
                "--metrics-interval",
                "0.05",
            ],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        try:
            wait_until_ready(base_url, process)

            status, _, headers = request(f"{base_url}/")
            assert status == 401, status
            assert headers.get("WWW-Authenticate") == 'Basic realm="Armbian build log"'

            status, body, _ = request(f"{base_url}/", authenticated=True)
            assert status == 200, status
            assert b"Armbian Kernel Build" in body
            assert b"(?:\\[[0-?]*[ -/]*[@-~]|[@-_])" in body
            assert b"new EventSource(`/api/events?offset=${state.offset}`" in body
            assert b'id="search"' in body
            assert b'id="jump-line"' in body
            assert b'id="theme"' in body
            assert b'value="ja"' in body
            assert b'value="fr"' in body
            assert b'value="de"' in body

            status, _, _ = request(f"{base_url}/api/metrics")
            assert status == 401, status
            status, body, _ = request(f"{base_url}/api/metrics", authenticated=True)
            assert status == 200, status
            metrics = json.loads(body)
            assert metrics["target"] == {
                "board": "test-board",
                "arch": "test-arch",
                "family": "test-family",
                "release": "test-release",
                "branch": "",
                "kernel": "",
            }, metrics
            assert metrics["host"]["cpu_count"] >= 1, metrics
            assert metrics["log_bytes"] == len(b"first line\n"), metrics

            status, _, _ = request(f"{base_url}/api/events")
            assert status == 401, status

            with open_sse(f"{base_url}/api/events?offset=0") as stream:
                assert stream.status == 200
                assert stream.headers.get_content_type() == "text/event-stream"
                assert stream.headers.get("Cache-Control") == "no-cache, no-transform"
                assert stream.headers.get("X-Accel-Buffering") == "no"

                frame = read_until_event(stream, "log")
                payload = json.loads(str(frame["data"]))
                first_offset = len(b"first line\n")
                assert frame["id"] == str(first_offset), frame
                assert payload == {"offset": first_offset, "text": "first line\n"}, payload

                frame = read_until_event(stream, "state")
                assert json.loads(str(frame["data"])) == {"state": "running"}, frame
                frame = read_until_event(stream, "metrics")
                metrics = json.loads(str(frame["data"]))
                assert metrics["target"]["board"] == "test-board", frame
                assert metrics["log_bytes"] == first_offset, frame
                heartbeat = read_until_heartbeat(stream)
                assert heartbeat["comments"] == ["keepalive"], heartbeat

                with (log_root / "build.log").open("ab") as log_file:
                    log_file.write(b"second line\n")
                frame = read_until_event(stream, "log")
                payload = json.loads(str(frame["data"]))
                final_offset = len(b"first line\nsecond line\n")
                assert frame["id"] == str(final_offset), frame
                assert payload == {"offset": final_offset, "text": "second line\n"}, payload

                (log_root / "status.json").write_text(
                    json.dumps({"state": "success", "exit_code": 0}), encoding="utf-8"
                )
                frame = read_until_event(stream, "state")
                assert json.loads(str(frame["data"])) == {
                    "state": "success",
                    "exit_code": 0,
                }, frame
                frame = read_until_event(stream, "complete")
                assert json.loads(str(frame["data"])) == {
                    "state": "success",
                    "exit_code": 0,
                    "offset": final_offset,
                }, frame

            with open_sse(
                f"{base_url}/api/events?offset=0", last_event_id=first_offset
            ) as resumed_stream:
                frame = read_until_event(resumed_stream, "log")
                payload = json.loads(str(frame["data"]))
                assert payload == {"offset": final_offset, "text": "second line\n"}, payload
                frame = read_until_event(resumed_stream, "complete")
                assert json.loads(str(frame["data"]))["offset"] == final_offset

            status, body, _ = request(f"{base_url}/api/log?offset=0", authenticated=True)
            assert status == 200, status
            payload = json.loads(body)
            assert payload == {
                "offset": final_offset,
                "reset": False,
                "state": "success",
                "text": "first line\nsecond line\n",
            }, payload

            status, body, _ = request(
                f"{base_url}/api/log?offset={first_offset}", authenticated=True
            )
            assert status == 200, status
            payload = json.loads(body)
            assert payload["text"] == "second line\n", payload
            assert payload["state"] == "success", payload

            status, body, headers = request(f"{base_url}/download", authenticated=True)
            assert status == 200, status
            assert body == b"first line\nsecond line\n", body
            assert "attachment" in headers.get("Content-Disposition", "")

            status, _, _ = request(f"{base_url}/missing", authenticated=True)
            assert status == 404, status
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    print("live log server tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
