#!/usr/bin/env python3
"""Integration checks for the authenticated live-log HTTP server."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
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


def request(
    url: str,
    *,
    authenticated: bool = False,
    headers: dict[str, str] | None = None,
) -> tuple[int, bytes, dict[str, str]]:
    request_headers = dict(headers or {})
    if authenticated:
        request_headers["Authorization"] = AUTH_HEADER
    req = urllib.request.Request(url, headers=request_headers)
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
        log_root = Path(temp_directory) / "live"
        files_root = Path(temp_directory) / "artifacts"
        log_root.mkdir()
        (files_root / "debs").mkdir(parents=True)
        (files_root / "release-metadata").mkdir()
        package = b"\x00ar-test-package\xffpayload"
        summary = "# Build summary\n\nKernel: 6.18\n"
        (files_root / "debs" / "linux-image-test.deb").write_bytes(package)
        (files_root / "release-metadata" / "build-summary.md").write_bytes(
            summary.encode("utf-8")
        )
        (files_root / "release-metadata" / "large.log").write_bytes(
            b"x" * (512 * 1024 + 17)
        )
        evidence_root = files_root / "release-metadata" / "current"
        evidence_root.mkdir()
        kernel_config = (
            "CONFIG_TCP_CONG_BRUTAL=y\n"
            "CONFIG_AMNEZIAWG=y\n"
            "CONFIG_NETFILTER_DEAF=y\n"
            "# CONFIG_WIREGUARD is not set\n"
            "CONFIG_BPF=y\n"
            "CONFIG_DEBUG_INFO_BTF=y\n"
            "CONFIG_MPLS_ROUTING=y\n"
            "CONFIG_VXLAN=y\n"
            "CONFIG_NF_TABLES=y\n"
            "CONFIG_TCP_CONG_BBR=y\n"
            "CONFIG_USB_GADGET=y\n"
            "CONFIG_BT=m\n"
            "CONFIG_CFG80211=m\n"
            "CONFIG_MT7921E=m\n"
        ).encode("utf-8")
        config_path = evidence_root / "current-kernel.config"
        config_path.write_bytes(kernel_config)
        config_digest = hashlib.sha256(kernel_config).hexdigest()
        commits = {
            "tcp_brutal_commit": "1" * 40,
            "amneziawg_commit": "2" * 40,
            "nf_deaf_commit": "3" * 40,
        }
        manifest_lines = [
            "evidence_format=1",
            "branch=current",
            "kernel_release=6.18.53-current-rockchip64",
            f"config_sha256={config_digest}",
            "baseline_status=generated",
            "diff_count=2",
            *(f"{key}={value}" for key, value in commits.items()),
        ]
        (evidence_root / "current-source-manifest.env").write_bytes(
            ("\n".join(manifest_lines) + "\n").encode("utf-8")
        )
        (evidence_root / "current-config-vs-arm64-defconfig.txt").write_bytes(
            b"-CONFIG_OLD=y\n+CONFIG_BPF=y\n"
        )
        module_data = b"synthetic module"
        (evidence_root / "current-test.ko").write_bytes(module_data)
        (evidence_root / "current-loadable-modules-SHA256SUMS").write_bytes(
            f"{hashlib.sha256(module_data).hexdigest()}  current-test.ko\n".encode(
                "ascii"
            )
        )
        (files_root / ".secret").write_text("must not be listed", encoding="utf-8")
        symlink_path = files_root / "linked-summary.md"
        try:
            symlink_path.symlink_to(files_root / "release-metadata" / "build-summary.md")
            symlink_created = True
        except OSError:
            symlink_created = False
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
                "-B",
                str(SERVER_SCRIPT),
                "--directory",
                str(log_root),
                "--files-directory",
                str(files_root),
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

            status, body, root_headers = request(f"{base_url}/", authenticated=True)
            assert status == 200, status
            assert root_headers.get("X-Frame-Options") == "DENY", root_headers
            assert "frame-ancestors 'none'" in root_headers.get("Content-Security-Policy", ""), root_headers
            assert "object-src 'none'" in root_headers.get("Content-Security-Policy", ""), root_headers
            assert root_headers.get("Permissions-Policy"), root_headers
            assert b"Armbian Kernel Build" in body
            assert b"(?:\\[[0-?]*[ -/]*[@-~]|[@-_])" in body
            assert b"new EventSource(`/api/events?offset=${state.offset}`" in body
            assert b'id="search"' in body
            assert b'id="jump-line"' in body
            assert b'id="theme"' in body
            assert b'id="tab-files"' in body
            assert b'id="tab-dashboard"' in body
            assert b'id="tab-config"' in body
            assert b'id="tab-packages"' in body
            assert b'id="notifications"' in body
            assert b'id="file-filter"' in body
            assert b'id="file-preview"' in body
            assert b"/api/file-hash" in body
            assert b'value="ja"' in body
            assert b'value="fr"' in body
            assert b'value="de"' in body
            assert b'value="zh-CN"' not in body
            assert b"::group::" in body
            assert b"::endgroup::" in body
            assert b"log-group-row" in body
            assert b"collapsedGroups" in body
            assert b"expandGroupsForRow" in body
            for translation_key in (
                b"dashboardTab:",
                b"timelineTitle:",
                b"featuresTitle:",
                b"diagnosticsTitle:",
                b"sourcesTitle:",
                b"integrityTitle:",
                b"packagesTitle:",
                b"enableNotifications:",
            ):
                assert body.count(translation_key) == 4, translation_key

            status, _, _ = request(f"{base_url}/api/files")
            assert status == 401, status
            status, body, _ = request(f"{base_url}/api/files", authenticated=True)
            assert status == 200, status
            listing = json.loads(body)
            assert listing["enabled"] is True, listing
            assert listing["available"] is True, listing
            assert listing["path"] == "", listing
            assert [entry["name"] for entry in listing["entries"]] == [
                "debs",
                "release-metadata",
            ], listing

            nested_path = urllib.parse.quote("release-metadata", safe="")
            status, body, _ = request(
                f"{base_url}/api/files?path={nested_path}", authenticated=True
            )
            assert status == 200, status
            nested = json.loads(body)
            assert nested["path"] == "release-metadata", nested
            summary_entry = next(
                entry for entry in nested["entries"] if entry["name"] == "build-summary.md"
            )
            assert summary_entry["previewable"] is True, nested

            summary_path = urllib.parse.quote(
                "release-metadata/build-summary.md", safe=""
            )
            status, body, _ = request(
                f"{base_url}/api/file?path={summary_path}", authenticated=True
            )
            assert status == 200, status
            preview = json.loads(body)
            assert preview["text"] == summary, preview
            assert preview["truncated"] is False, preview

            large_path = urllib.parse.quote("release-metadata/large.log", safe="")
            status, body, _ = request(
                f"{base_url}/api/file?path={large_path}", authenticated=True
            )
            assert status == 200, status
            large_preview = json.loads(body)
            assert large_preview["truncated"] is True, large_preview
            assert len(large_preview["text"]) == 512 * 1024, len(
                large_preview["text"]
            )

            package_path = urllib.parse.quote("debs/linux-image-test.deb", safe="")
            status, body, _ = request(
                f"{base_url}/api/file?path={package_path}", authenticated=True
            )
            assert status == 415, (status, body)

            status, body, headers = request(
                f"{base_url}/files/download?path={package_path}", authenticated=True
            )
            assert status == 200, status
            assert body == package, body
            assert headers.get("Accept-Ranges") == "bytes", headers
            assert "linux-image-test.deb" in headers.get("Content-Disposition", "")

            status, body, headers = request(
                f"{base_url}/files/download?path={package_path}",
                authenticated=True,
                headers={"Range": "bytes=2-7"},
            )
            assert status == 206, status
            assert body == package[2:8], body
            assert headers.get("Content-Range") == f"bytes 2-7/{len(package)}", headers

            status, body, headers = request(
                f"{base_url}/files/download?path={package_path}",
                authenticated=True,
                headers={"Range": "bytes=999-1000"},
            )
            assert status == 416, status
            assert headers.get("Content-Range") == f"bytes */{len(package)}", headers

            status, body, _ = request(
                f"{base_url}/api/file-hash?path={package_path}", authenticated=True
            )
            assert status == 200, status
            checksum = json.loads(body)
            assert checksum["digest"] == hashlib.sha256(package).hexdigest(), checksum

            status, body, _ = request(
                f"{base_url}/api/files?path=..%2Flive", authenticated=True
            )
            assert status == 400, (status, body)
            assert b"first line" not in body
            status, body, _ = request(
                f"{base_url}/api/file?path=.secret", authenticated=True
            )
            assert status == 400, (status, body)
            assert b"must not be listed" not in body
            if symlink_created:
                status, body, _ = request(
                    f"{base_url}/api/file?path=linked-summary.md", authenticated=True
                )
                assert status == 400, (status, body)
                assert b"Build summary" not in body

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

            with (log_root / "build.log").open("ab") as log_file:
                log_file.write(
                    b"[INFO] Build wrapper Arguments: target=kernel BRANCH=current BOARD=test\n"
                )
            status, body, _ = request(f"{base_url}/api/metrics", authenticated=True)
            assert status == 200, status
            metrics = json.loads(body)
            assert metrics["target"]["branch"] == "current", metrics

            with (log_root / "build.log").open("ab") as log_file:
                log_file.write(b"x" * (300 * 1024))
            status, body, _ = request(f"{base_url}/api/metrics", authenticated=True)
            assert status == 200, status
            metrics = json.loads(body)
            assert metrics["target"]["branch"] == "current", metrics
            (log_root / "build.log").write_bytes(b"first line\n")

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

            status, _, _ = request(f"{base_url}/api/dashboard")
            assert status == 401, status
            with (log_root / "build.log").open("ab") as log_file:
                log_file.write(
                    "\x1b[32m[INFO]\x1b[0m \x1b[2m2026-09-24T03:30:00Z\x1b[0m ──── 1. Environment initialization ────\n"
                    "[INFO] ──── Armbian internal banner ────\n"
                    "──── another internal separator ────\n"
                    "[WARN] synthetic warning\n"
                    "[🐳|🔨] test.dtb: Warning (spi_bus_reg): Failed prerequisite 'reg_format'\n"
                    "[🐳|🔨] patch title: keep reset deasserted on failed resume\n"
                    "[ERROR] synthetic failure evidence\n"
                    "\x1b[32m[INFO]\x1b[0m \x1b[2m2026-09-24T03:30:03Z\x1b[0m ──── 1. Environment initialization completed (elapsed 3s) ────\n".encode(
                        "utf-8"
                    )
                )
            status, body, _ = request(
                f"{base_url}/api/dashboard", authenticated=True
            )
            assert status == 200, status
            dashboard = json.loads(body)
            assert dashboard["timeline"][0]["label"] == "1. Environment initialization", dashboard
            assert dashboard["timeline"][0]["status"] == "success", dashboard
            assert dashboard["timeline"][0]["duration_seconds"] == 3, dashboard
            assert len(dashboard["timeline"]) == 1, dashboard
            diagnostics = dashboard["diagnostics"]
            assert {item["severity"] for item in diagnostics} == {
                "warning",
                "error",
            }, dashboard
            assert len(diagnostics) == 3, diagnostics
            dtc_warning = next(
                item for item in diagnostics if "Failed prerequisite" in item["message"]
            )
            assert dtc_warning["severity"] == "warning", dtc_warning
            assert not any(
                "failed resume" in item["message"] for item in diagnostics
            ), diagnostics
            assert dashboard["features"][0]["branch"] == "current", dashboard
            custom_group = next(
                group
                for group in dashboard["features"][0]["groups"]
                if group["id"] == "custom"
            )
            assert custom_group["items"][0] == {
                "symbol": "TCP_CONG_BRUTAL",
                "value": "y",
            }, custom_group
            assert len(dashboard["sources"]) == 3, dashboard
            assert dashboard["config_diffs"][0]["added"] == 1, dashboard
            assert dashboard["config_diffs"][0]["removed"] == 1, dashboard
            assert {
                (item["kind"], item["status"])
                for item in dashboard["integrity"]
            } >= {
                ("config", "verified"),
                ("sources", "verified"),
                ("modules", "verified"),
            }, dashboard
            assert dashboard["resources"], dashboard

            status, _, _ = request(f"{base_url}/api/packages")
            assert status == 401, status
            status, body, _ = request(
                f"{base_url}/api/packages", authenticated=True
            )
            assert status == 200, status
            packages = json.loads(body)
            assert packages["packages"][0]["path"] == "debs/linux-image-test.deb", packages
            status, body, _ = request(
                f"{base_url}/api/package?path={package_path}", authenticated=True
            )
            assert status == 200, status
            package_inspection = json.loads(body)
            assert package_inspection["inspection"] in {
                "ready",
                "invalid",
                "unavailable",
            }, package_inspection

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
