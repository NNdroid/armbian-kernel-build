#!/usr/bin/env python3
"""Regression tests for the live-log streaming redactor."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPOSITORY_ROOT / "scripts" / "redact_log_stream.py"


def run_redactor(data: bytes, **extra_env: str) -> bytes:
    environment = os.environ.copy()
    environment.update(extra_env)
    completed = subprocess.run(
        [sys.executable, "-B", str(SCRIPT)],
        input=data,
        capture_output=True,
        check=True,
        env=environment,
    )
    assert completed.stderr == b"", completed.stderr
    return completed.stdout


def main() -> int:
    token = "super-secret-token-123456"
    auth_token = "compound-auth-token-654321"
    header = b"normal output\n"
    prefix = b"x" * (64 * 1024 - len(header) - 7)
    payload = (
        header
        + prefix
        + token.encode("ascii")
        + b"\nsecond="
        + auth_token.encode("ascii")
        + b"\n"
    )
    output = run_redactor(
        payload,
        GH_TOKEN=token,
        NGROK_AUTHTOKEN=auth_token,
    )
    assert token.encode("ascii") not in output, output[-200:]
    assert auth_token.encode("ascii") not in output, output[-200:]
    assert output.count(b"***") == 2, output[-200:]
    assert output.startswith(b"normal output\n"), output[:100]

    harmless = b"plain build output\n"
    assert run_redactor(harmless, ORDINARY_VALUE="not-a-secret") == harmless

    print("[PASS] live-log redactor masks secret-like environment values")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
