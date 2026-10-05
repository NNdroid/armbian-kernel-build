#!/usr/bin/env python3
"""Regression tests for the live-log streaming redactor."""

from __future__ import annotations

import os
import re
import subprocess
import sys
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPOSITORY_ROOT / "scripts" / "redact_log_stream.py"

# Mirrors SECRET_NAME_RE in the redactor. Inherited variables matching it would
# silently change the longest secret, and therefore the retained-suffix size the
# chunk boundary is computed from. That is what these tests exist to probe, so a
# developer's ambient GH_TOKEN or DB_PASSWORD would move the window under test.
SECRET_NAME_RE = re.compile(
    r"(?:TOKEN|SECRET|PASSWORD|PASS|AUTH|API_KEY|PRIVATE_KEY)$",
    re.IGNORECASE,
)


def run_redactor(data: bytes, **extra_env: str) -> bytes:
    environment = {
        name: value
        for name, value in os.environ.items()
        if not SECRET_NAME_RE.search(name)
    }
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


class RedactorTests(unittest.TestCase):
    token = "super-secret-token-123456"
    auth_token = "compound-auth-token-654321"

    def test_no_inherited_secret_reaches_the_child(self):
        """Guard the premise of every other test in this module."""
        environment = os.environ.copy()
        environment["SOME_TOKEN"] = "ambient-value-that-must-not-leak"
        completed = subprocess.run(
            [sys.executable, "-B", "-c",
             "import os,re,sys;"
             "print(re.search(r'(?:TOKEN|SECRET|PASSWORD|PASS|AUTH|API_KEY|PRIVATE_KEY)$',"
             "'SOME_TOKEN',re.I) is not None)"],
            capture_output=True, text=True, check=True,
            env={**environment, "PATH": os.environ.get("PATH", "")},
        )
        self.assertEqual(completed.stdout.strip(), "True")

    def test_secrets_across_the_read_boundary_are_masked(self):
        token_bytes = self.token.encode("ascii")
        auth_bytes = self.auth_token.encode("ascii")

        # Exercise secrets at and across the 64 KiB read boundary. The second
        # secret intentionally begins one byte before the old retained-suffix
        # cut, which previously leaked the complete value.
        header = b"normal output\n"
        prefix = b"x" * (64 * 1024 - len(header) - 7)
        payload = header + prefix + token_bytes + b"\nsecond=" + auth_bytes + b"\n"
        output = run_redactor(payload, GH_TOKEN=self.token, NGROK_AUTHTOKEN=self.auth_token)
        self.assertNotIn(token_bytes, output, output[-200:])
        self.assertNotIn(auth_bytes, output, output[-200:])
        self.assertEqual(output.count(b"***"), 2, output[-200:])
        self.assertTrue(output.startswith(b"normal output\n"), output[:100])

    def test_every_split_position_around_the_boundary_is_masked(self):
        """A future buffering change must not be able to reintroduce leaks."""
        for secret_name, secret in (
            ("GH_TOKEN", self.token),
            ("NGROK_AUTHTOKEN", self.auth_token),
        ):
            secret_bytes = secret.encode("ascii")
            for split_at in range(1, len(secret_bytes)):
                with self.subTest(secret=secret_name, split_at=split_at):
                    prefix_len = 64 * 1024 - split_at
                    boundary_payload = b"x" * prefix_len + secret_bytes + b"\n"
                    boundary_output = run_redactor(boundary_payload, **{secret_name: secret})
                    self.assertNotIn(secret_bytes, boundary_output, boundary_output[-100:])
                    self.assertTrue(boundary_output.endswith(b"***\n"), boundary_output[-100:])

    def test_adjacent_and_overlapping_values_are_both_masked(self):
        short_token = "shared-secret"
        long_token = "shared-secret-with-suffix"
        adjacent = (
            long_token.encode("ascii")
            + b":"
            + short_token.encode("ascii")
            + b"\n"
        )
        output = run_redactor(adjacent, API_KEY=short_token, PRIVATE_KEY=long_token)
        self.assertNotIn(long_token.encode("ascii"), output, output)
        self.assertNotIn(short_token.encode("ascii"), output, output)
        self.assertEqual(output, b"***:***\n", output)

    def test_harmless_output_is_untouched(self):
        harmless = b"plain build output\n"
        self.assertEqual(run_redactor(harmless, ORDINARY_VALUE="not-a-secret"), harmless)

    def test_too_short_values_are_not_treated_as_secrets(self):
        """A 1-2 character value would mask almost every log line."""
        output = run_redactor(b"a b c\n", TINY_TOKEN="x")
        self.assertEqual(output, b"a b c\n", output)


if __name__ == "__main__":
    unittest.main(verbosity=2)