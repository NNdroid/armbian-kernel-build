#!/usr/bin/env python3
"""Stream stdin to stdout while masking secret-like environment values."""

from __future__ import annotations

import os
import re
import sys


SECRET_NAME_RE = re.compile(
    r"(?:TOKEN|SECRET|PASSWORD|PASS|AUTH|API_KEY|PRIVATE_KEY)$",
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


def redact_safe_prefix(
    data: bytes, values: list[bytes], keep_bytes: int
) -> tuple[bytes, bytes]:
    """
    Redact and emit only a prefix that cannot split a secret value.

    A plain `data[:-keep_bytes]` cut is not safe: a secret may start just
    before the cut and end inside the retained suffix. Scan the complete
    buffer for secret occurrences before the cut and consume any matching
    value atomically, even when that match crosses the nominal cut.
    """
    cutoff = max(len(data) - keep_bytes, 0)
    if cutoff == 0:
        return b"", data

    output: list[bytes] = []
    cursor = 0
    while cursor < cutoff:
        match_start: int | None = None
        match_value: bytes | None = None

        for value in values:
            start = data.find(value, cursor)
            if start < 0:
                continue
            if (
                match_start is None
                or start < match_start
                or (
                    start == match_start
                    and match_value is not None
                    and len(value) > len(match_value)
                )
            ):
                match_start = start
                match_value = value

        if match_start is None or match_start >= cutoff or match_value is None:
            output.append(data[cursor:cutoff])
            cursor = cutoff
            break

        output.append(data[cursor:match_start])
        output.append(REPLACEMENT)
        cursor = match_start + len(match_value)

    return b"".join(output), data[cursor:]


def main() -> int:
    values = secret_values()
    if not values:
        while chunk := sys.stdin.buffer.read(64 * 1024):
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
        return 0

    keep_bytes = max(len(value) for value in values) - 1
    pending = b""
    while chunk := sys.stdin.buffer.read(64 * 1024):
        pending += chunk
        emit, pending = redact_safe_prefix(pending, values, keep_bytes)
        if emit:
            sys.stdout.buffer.write(emit)
            sys.stdout.buffer.flush()

    if pending:
        sys.stdout.buffer.write(redact(pending, values))
        sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
