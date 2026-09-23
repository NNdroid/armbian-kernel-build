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
        process = subprocess.Popen(
            [
                sys.executable,
                str(SERVER_SCRIPT),
                "--directory",
                str(log_root),
                "--port",
                str(port),
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

            status, body, _ = request(f"{base_url}/api/log?offset=0", authenticated=True)
            assert status == 200, status
            payload = json.loads(body)
            assert payload == {
                "offset": len(b"first line\n"),
                "reset": False,
                "state": "running",
                "text": "first line\n",
            }, payload

            with (log_root / "build.log").open("ab") as log_file:
                log_file.write(b"second line\n")
            (log_root / "status.json").write_text(
                json.dumps({"state": "success"}), encoding="utf-8"
            )

            status, body, _ = request(
                f"{base_url}/api/log?offset={payload['offset']}", authenticated=True
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
