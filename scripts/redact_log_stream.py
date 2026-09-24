#!/usr/bin/env python3
"""Stream stdin to stdout while masking secret-like environment values."""

from __future__ import annotations

import os
import re
import sys


SECRET_NAME_RE = re.compile(
    r"(?:^|_)(?:TOKEN|SECRET|PASSWORD|PASS|AUTH|API_KEY|PRIVATE_KEY)$",
    re.IGNORECASE,
)
REPLACEMENT = b"***"


def secret_values() -> list[bytes]:
    values: set[bytes] = set()
    for name, value in os.environ.items():
        if not SECRET_NAME_RE.search(name):
            continue
        if not value or len(value) < 6 or "\n" in value or "\r" in value:
            continue
        values.add(value.encode("utf-8", errors="ignore"))
    return sorted((value for value in values if value), key=len, reverse=True)


def redact(data: bytes, values: list[bytes]) -> bytes:
    for value in values:
        data = data.replace(value, REPLACEMENT)
    return data


def main() -> int:
    values = secret_values()
    if not values:
        while chunk := sys.stdin.buffer.read(64 * 1024):
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
        return 0

    overlap = max(len(value) for value in values) - 1
    pending = b""
    while chunk := sys.stdin.buffer.read(64 * 1024):
        pending += chunk
        if len(pending) <= overlap:
            continue
        emit = pending[:-overlap] if overlap else pending
        pending = pending[-overlap:] if overlap else b""
        sys.stdout.buffer.write(redact(emit, values))
        sys.stdout.buffer.flush()

    if pending:
        sys.stdout.buffer.write(redact(pending, values))
        sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
