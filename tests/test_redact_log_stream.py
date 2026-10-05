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
    token_bytes = token.encode("ascii")
    auth_bytes = auth_token.encode("ascii")

    # Exercise secrets at and across the 64 KiB read boundary. The second
    # secret intentionally begins one byte before the old retained-suffix cut,
    # which previously leaked the complete value.
    header = b"normal output\n"
    prefix = b"x" * (64 * 1024 - len(header) - 7)
    payload = header + prefix + token_bytes + b"\nsecond=" + auth_bytes + b"\n"
    output = run_redactor(
        payload,
        GH_TOKEN=token,
        NGROK_AUTHTOKEN=auth_token,
    )
    assert token_bytes not in output, output[-200:]
    assert auth_bytes not in output, output[-200:]
    assert output.count(b"***") == 2, output[-200:]
    assert output.startswith(b"normal output\n"), output[:100]

    # Check every possible split position for both values around an artificial
    # 64 KiB boundary so future buffering changes cannot reintroduce leaks.
    for secret_name, secret in (
        ("GH_TOKEN", token),
        ("NGROK_AUTHTOKEN", auth_token),
    ):
        secret_bytes = secret.encode("ascii")
        for split_at in range(1, len(secret_bytes)):
            prefix_len = 64 * 1024 - split_at
            boundary_payload = b"x" * prefix_len + secret_bytes + b"\n"
            boundary_output = run_redactor(
                boundary_payload,
                **{secret_name: secret},
            )
            assert secret_bytes not in boundary_output, (
                secret_name,
                split_at,
                boundary_output[-100:],
            )
            assert boundary_output.endswith(b"***\n"), (
                secret_name,
                split_at,
                boundary_output[-100:],
            )

    # Adjacent and overlapping-prefix values must both be masked.
    short_token = "shared-secret"
    long_token = "shared-secret-with-suffix"
    adjacent = (
        long_token.encode("ascii")
        + b":"
        + short_token.encode("ascii")
        + b"\n"
    )
    adjacent_output = run_redactor(
        adjacent,
        API_KEY=short_token,
        PRIVATE_KEY=long_token,
    )
    assert long_token.encode("ascii") not in adjacent_output, adjacent_output
    assert short_token.encode("ascii") not in adjacent_output, adjacent_output
    assert adjacent_output == b"***:***\n", adjacent_output

    harmless = b"plain build output\n"
    assert run_redactor(harmless, ORDINARY_VALUE="not-a-secret") == harmless

    print("[PASS] live-log redactor masks secret-like environment values")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
