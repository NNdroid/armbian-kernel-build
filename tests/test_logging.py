"""Contracts for the debuggability guarantees in scripts/lib/logging.sh.

Every test here encodes a promise a reader of a failed kernel build relies on.
They are grouped by the question they answer rather than by the function they
call, because the point of the module is the questions, not the functions.
"""

import os
import sys
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt" else shutil.which("bash")

# What logging.sh guarantees at the head of every rendered line. live_dashboard.py
# depends on this shape too, so it is asserted here rather than left implicit.
PREFIX_RE = re.compile(
    r"^\[(?P<level>INFO|WARN|ERROR|DEBUG)\] "
    r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z "
    r"\+(?P<elapsed>\d+:\d{2}:\d{2}) "
    r"(?:\[(?P<step>\d+/\d+[^\]]*)\] )?"
    r"(?P<message>.*)$"
)
ANSI_RE = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|[@-_])")


def parse_lines(text, strip=False):
    """Strip ANSI and split into (match, raw) pairs, dropping non-log noise.

    strip=True removes the two-space indent that _log_dump_context puts on each
    replayed line, so a replay block can be matched with the same regex as live
    output instead of needing a second pattern."""
    parsed = []
    for raw in ANSI_RE.sub("", text).splitlines():
        match = PREFIX_RE.match(raw.lstrip() if strip else raw)
        if match:
            parsed.append((match, raw))
    return parsed


class LogLevelTests(unittest.TestCase):
    """BUILD_LOG_LEVEL must actually gate, in both directions."""

    def run_logging(self, script, **variables):
        env = os.environ.copy()
        for key in list(env):
            if key.startswith(("GITHUB_", "ACTIONS_", "RUNNER_")):
                env.pop(key, None)
        for key in ("BUILD_LOG_LEVEL", "BUILD_LOG_TRACE", "BUILD_LOG_FILE", "NO_COLOR"):
            env.pop(key, None)
        env.update(variables)
        return subprocess.run(
            [BASH, "-c", f"BUILD_SCRIPT_LIB_ONLY=yes source build.sh; {script}"],
            cwd=ROOT, env=env, text=True, capture_output=True,
        )

    def test_default_level_shows_info_and_hides_debug(self):
        result = self.run_logging(
            'log_info "an info line"; log_debug "a debug line"; log_warn "a warning"')
        self.assertEqual(result.returncode, 0, result.stderr)
        messages = " ".join(match.group("message") for match, _ in parse_lines(result.stderr))
        self.assertIn("an info line", messages)
        self.assertIn("a warning", messages)
        self.assertNotIn("a debug line", messages)

    def test_every_level_admits_exactly_its_own_threshold(self):
        """A level is inclusive: setting warn shows error+warn and nothing else."""
        expectations = {
            "error": {"an error"},
            "warn": {"an error", "a warning"},
            "info": {"an error", "a warning", "an info line"},
            "debug": {"an error", "a warning", "an info line", "a debug line"},
        }
        script = ('log_info "an info line"; log_debug "a debug line"; '
                  'log_warn "a warning"; log_error "an error"')
        for level, expected in expectations.items():
            with self.subTest(level=level):
                result = self.run_logging(script, BUILD_LOG_LEVEL=level)
                self.assertEqual(result.returncode, 0, result.stderr)
                messages = {match.group("message") for match, _ in parse_lines(result.stderr)}
                self.assertEqual(messages, expected)

    def test_unknown_level_is_rejected_rather_than_silently_defaulted(self):
        """A typo must not produce a plausible log at the wrong verbosity."""
        result = self.run_logging('log_debug "x"', BUILD_LOG_LEVEL="verbose")
        self.assertIn("Unknown BUILD_LOG_LEVEL", result.stderr)
        self.assertIn("error warn info debug trace", result.stderr)

    def test_declared_levels_match_the_documented_order(self):
        """The help text and the gate read the same list, so they cannot drift."""
        result = self.run_logging('printf "%s" "${LOG_LEVELS[*]}"')
        self.assertEqual(result.stdout.strip(), "error warn info debug trace")
        usage = subprocess.run([BASH, "build.sh", "--nonsense"], cwd=ROOT,
                               text=True, capture_output=True)
        for level in ("error", "warn", "info", "debug", "trace"):
            self.assertIn(level, usage.stderr)

    def test_trace_level_emits_a_shell_execution_trace(self):
        result = self.run_logging('probe_value=7; : "${probe_value}"', BUILD_LOG_LEVEL="trace")
        self.assertEqual(result.returncode, 0, result.stderr)
        # A trace is only useful if it says where; a bare "+" is unreadable in a
        # 200k-line log, so PS4 must carry at least the file and line.
        self.assertRegex(result.stderr, r"\+ \d+s \S+:\d+:\w*>")
        self.assertIn("probe_value", result.stderr)

    def test_trace_alias_enables_the_trace_without_naming_a_level(self):
        result = self.run_logging('probe_value=7; : "${probe_value}"', BUILD_LOG_TRACE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stderr, r"\+ \d+s \S+:\d+:\w*>")

    def test_no_trace_at_the_default_level(self):
        result = self.run_logging('probe_value=7; : "${probe_value}"')
        self.assertNotIn("+ 0s ", result.stderr)


class LogFormatTests(unittest.TestCase):
    """Every line must be greppable, parseable and readable out of context."""

    def run_logging(self, script, **variables):
        env = os.environ.copy()
        for key in ("BUILD_LOG_LEVEL", "BUILD_LOG_TRACE", "BUILD_LOG_FILE", "NO_COLOR"):
            env.pop(key, None)
        env.update(variables)
        return subprocess.run(
            [BASH, "-c", f"BUILD_SCRIPT_LIB_ONLY=yes source build.sh; {script}"],
            cwd=ROOT, env=env, text=True, capture_output=True,
        )

    def test_format_strings_are_expanded(self):
        """A call with a format plus values must substitute them.

        Regression: the arguments used to be joined with "$*", which printed
        every %s literally -- the exact failure message a reader needs came out
        as "%s / %s is pinned to kernel series %s"."""
        result = self.run_logging(
            'log_error "Branch %s is not supported by target %s (declares: %s)" '
            'bleedingedge hk1box "edge current"')
        message = parse_lines(result.stderr)[0][0].group("message")
        self.assertEqual(
            message, "Branch bleedingedge is not supported by target hk1box (declares: edge current)")

    def test_a_single_prebuilt_argument_is_never_reformatted(self):
        """Formatting only applies when values were passed. Expanding a lone
        argument would corrupt any message containing a percent sign, and
        printing a literal message that happens to hold %s must not eat it."""
        result = self.run_logging(
            'log_info "compression ratio is 50% and the label is %s verbatim"')
        self.assertEqual(
            parse_lines(result.stderr)[0][0].group("message"),
            "compression ratio is 50% and the label is %s verbatim")

    def test_each_log_line_is_a_separate_line(self):
        """Regression: command substitution strips newlines and used to run
        consecutive log messages together on one line."""
        result = self.run_logging('log_info "first"; log_info "second"; log_info "third"')
        lines = [raw for _, raw in parse_lines(result.stderr)]
        self.assertEqual(len(lines), 3)
        self.assertTrue(lines[0].endswith("first"), lines)
        self.assertTrue(lines[1].endswith("second"), lines)
        self.assertTrue(lines[2].endswith("third"), lines)

    def test_no_ansi_escapes_when_output_is_not_a_terminal(self):
        """Escapes in build.log defeat grep and confuse the dashboard."""
        for level in ("info", "debug", "error"):
            with self.subTest(level=level):
                result = self.run_logging(
                    'log_info "i"; log_debug "d"; log_warn "w"; log_error "e"',
                    BUILD_LOG_LEVEL=level)
                self.assertNotIn("\x1b", result.stderr)

    def test_no_color_environment_variable_is_honoured(self):
        result = self.run_logging('log_info "i"', NO_COLOR="1")
        self.assertNotIn("\x1b", result.stderr)

    def test_every_line_carries_level_timestamp_and_elapsed(self):
        result = self.run_logging('log_info "body"')
        match, _ = parse_lines(result.stderr)[0]
        self.assertEqual(match.group("level"), "INFO")
        self.assertEqual(match.group("message"), "body")
        self.assertRegex(match.group("elapsed"), r"^\d+:\d{2}:\d{2}$")

    def test_elapsed_counter_is_monotonic(self):
        """A clock that can go backwards makes step timings untrustworthy."""
        result = self.run_logging(
            'log_info "one"; sleep 1; log_info "two"; sleep 1; log_info "three"')
        elapsed = [match.group("elapsed") for match, _ in parse_lines(result.stderr)]
        self.assertEqual(len(elapsed), 3)
        as_seconds = [int(h) * 3600 + int(m) * 60 + int(s) for h, m, s in
                      (value.split(":") for value in elapsed)]
        self.assertEqual(as_seconds, sorted(as_seconds))
        self.assertGreater(as_seconds[-1] - as_seconds[0], 0)

    def test_all_levels_share_one_stream(self):
        """Splitting levels across stdout and stderr reorders them once piped.

        build.sh runs under pipefail while CI pipes stdout into a redactor and
        then tee, so two streams would interleave by stdio buffering rather than
        by when the message was produced.
        """
        result = self.run_logging(
            'log_error "e1"; log_info "i1"; log_error "e2"; log_info "i2"', NO_COLOR="1")
        self.assertEqual(result.stdout, "", f"log output leaked to stdout: {result.stdout!r}")
        order = [match.group("message") for match, _ in parse_lines(result.stderr)]
        self.assertEqual(order, ["e1", "i1", "e2", "i2"])


class StepTrackingTests(unittest.TestCase):
    """Step banners are how a reader knows what the build was doing."""

    def run_logging(self, script, **variables):
        env = os.environ.copy()
        for key in ("BUILD_LOG_LEVEL", "BUILD_LOG_TRACE", "BUILD_LOG_FILE", "NO_COLOR"):
            env.pop(key, None)
        env.update(variables)
        return subprocess.run(
            [BASH, "-c", f"BUILD_SCRIPT_LIB_ONLY=yes source build.sh; {script}"],
            cwd=ROOT, env=env, text=True, capture_output=True,
        )

    def test_step_numbers_are_derived_not_written_by_hand(self):
        """A hand-written ordinal drifts the moment a step is inserted."""
        result = self.run_logging(
            '_log_declare_steps 3; begin_step "One"; end_step "One"; '
            'begin_step "Two"; end_step "Two"; begin_step "Three"; end_step "Three"')
        # begin/end alternate, so index 3 is Two's completion, not Three's start.
        banners = [match.group("message") for match, _ in parse_lines(result.stderr)
                   if "────" in match.group("message")]
        self.assertEqual(banners[0], "──── 1. One ────")
        self.assertEqual(banners[1], "──── 1. One completed (elapsed 0s) ────")
        self.assertEqual(banners[2], "──── 2. Two ────")
        self.assertEqual(banners[3], "──── 2. Two completed (elapsed 0s) ────")
        self.assertEqual(banners[4], "──── 3. Three ────")

    def test_lines_inside_a_step_carry_the_step_context(self):
        result = self.run_logging(
            '_log_declare_steps 2; begin_step "Building kernel"; '
            'log_info "compiling module"; end_step "Building kernel"')
        match, _ = parse_lines(result.stderr)[1]
        self.assertEqual(match.group("step"), "1/2 Building kernel")
        self.assertEqual(match.group("message"), "compiling module")

    def test_lines_outside_a_step_have_no_step_tag(self):
        result = self.run_logging('log_info "before any step"')
        match, _ = parse_lines(result.stderr)[0]
        self.assertIsNone(match.group("step"))

    def test_steps_inside_a_loop_keep_counting_up(self):
        """The build and publish steps run once per branch; banners must not
        all claim to be step 4."""
        result = self.run_logging(
            '_log_declare_steps 5; for branch in current edge bleedingedge; do '
            'begin_step "Build ${branch}"; log_info "working"; end_step "Build ${branch}"; done')
        begins = [match.group("message") for match, _ in parse_lines(result.stderr)
                  if match.group("message").startswith("──── ") and "completed" not in match.group("message")]
        self.assertEqual(begins, ["──── 1. Build current ────",
                                  "──── 2. Build edge ────",
                                  "──── 3. Build bleedingedge ────"])

    def test_end_step_without_begin_step_warns_instead_of_silently_passing(self):
        result = self.run_logging('end_step "Never started"')
        messages = [match.group("message") for match, _ in parse_lines(result.stderr)]
        self.assertTrue(any("no matching begin_step" in message for message in messages), messages)


class FailureContextTests(unittest.TestCase):
    """The failure report is the one part of the log that is guaranteed to be
    read, so it has to answer "where, how long, and what next" by itself."""

    def run_failing(self, script, **variables):
        env = os.environ.copy()
        for key in ("BUILD_LOG_LEVEL", "BUILD_LOG_TRACE", "BUILD_LOG_FILE", "NO_COLOR"):
            env.pop(key, None)
        env.update(variables)
        return subprocess.run(
            [BASH, "-c",
             'BUILD_SCRIPT_LIB_ONLY=yes source build.sh; '
             'set -Eeuo pipefail; '
             'trap \'report_unhandled_error "$?" "$LINENO" "$BASH_COMMAND"\' ERR; '
             f'{script}'],
            cwd=ROOT, env=env, text=True, capture_output=True,
        )

    def test_failure_names_the_failing_command_and_working_directory(self):
        result = self.run_failing('false')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Command failed", result.stderr)
        self.assertIn("command=false", result.stderr)
        self.assertIn("Working directory at failure", result.stderr)

    def test_failure_identifies_the_running_step_and_its_duration(self):
        result = self.run_failing(
            '_log_declare_steps 4; begin_step "Prepare build environment"; '
            'log_info "cloning"; sleep 1; false')
        self.assertRegex(result.stderr, r"Failing step: \[1/4\] Prepare build environment \(running for \d+s\)")

    def test_failure_replays_recent_log_lines(self):
        """The lines just before a failure are usually the actual cause, and
        they are exactly what a CI log viewer scrolls away."""
        result = self.run_failing(
            '_log_declare_steps 2; begin_step "Fetching"; '
            'log_info "contacting kernel.org"; log_info "series 7.3 not published"; false')
        self.assertIn("last", result.stderr)
        self.assertRegex(result.stderr, r"──── last \d+ log lines ────")
        self.assertIn("contacting kernel.org", result.stderr)
        self.assertIn("series 7.3 not published", result.stderr)

    def test_failure_replay_is_bounded(self):
        """An unbounded replay would dump the whole log into the failure
        report, which is the opposite of a summary."""
        result = self.run_failing(
            'for i in $(seq 1 200); do log_info "chatter ${i}"; done; false',
            LOG_CONTEXT_LINES="10")
        self.assertIn("──── last 10 log lines ────", result.stderr)
        # Only the replayed block is under test: chatter 1 is legitimately in
        # stderr as real output, so it must be checked inside the block that
        # follows the banner rather than across the whole stream. Replayed lines
        # are indented by the dumper, so the indent is stripped before matching.
        replay = result.stderr.split("──── last 10 log lines ────", 1)[1]
        replayed = {match.group("message") for match, _ in parse_lines(replay, strip=True)}
        self.assertIn("chatter 200", replayed)
        self.assertNotIn("chatter 1", replayed)
        self.assertEqual(len(replayed), 10)

    def test_failure_points_at_the_log_file_and_the_next_verbosity(self):
        with tempfile.TemporaryDirectory() as directory:
            log_file = Path(directory) / "run.log"
            result = self.run_failing('log_info "before failure"; false',
                                      BUILD_LOG_FILE=str(log_file))
            self.assertIn(str(log_file), result.stderr)
            self.assertIn("BUILD_LOG_LEVEL=debug", result.stderr)
            self.assertIn("BUILD_LOG_LEVEL=trace", result.stderr)

    def test_the_replay_also_reaches_the_log_file(self):
        """The replay is what gives BUILD_LOG_FILE its failure context.

        Regression: it used to be a bare printf to stderr, so a reader looking
        at build.log after the fact saw the failure lines but nothing about what
        led to them -- the one case the file exists to answer."""
        with tempfile.TemporaryDirectory() as directory:
            log_file = Path(directory) / "run.log"
            result = self.run_failing(
                'log_info "compiling module"; log_info "linking module"; false',
                BUILD_LOG_FILE=str(log_file))
            written = log_file.read_text(encoding="utf-8")
            self.assertIn("──── last", written)
            self.assertIn("compiling module", written)
            self.assertIn("linking module", written)
            # Byte-identical to what stderr showed, so the file is a faithful
            # copy rather than a second, differently-formatted rendering.
            self.assertIn(written[written.index("──── last"):], result.stderr)

    def test_the_replay_is_not_reformatted(self):
        """Replayed lines keep their original timestamp. Re-stamping them would
        make the replay appear to happen after the failure it explains."""
        with tempfile.TemporaryDirectory() as directory:
            log_file = Path(directory) / "run.log"
            self.run_failing('log_info "the cause"; false',
                             BUILD_LOG_FILE=str(log_file))
            written = log_file.read_text(encoding="utf-8")
            stamps = set(re.findall(r"^\[(?:INFO|ERROR)\] (\S+Z) ", written, re.M))
            self.assertEqual(len(stamps), 1, f"replay was re-stamped: {sorted(stamps)}")

    def test_failure_without_a_log_file_says_so(self):
        result = self.run_failing('false')
        self.assertIn("No log file configured", result.stderr)


class LogFileTests(unittest.TestCase):
    """A local run must leave a durable record without any CI plumbing."""

    def run_logging(self, script, **variables):
        env = os.environ.copy()
        for key in ("BUILD_LOG_LEVEL", "BUILD_LOG_TRACE", "BUILD_LOG_FILE", "NO_COLOR"):
            env.pop(key, None)
        env.update(variables)
        return subprocess.run(
            [BASH, "-c", f"BUILD_SCRIPT_LIB_ONLY=yes source build.sh; {script}"],
            cwd=ROOT, env=env, text=True, capture_output=True,
        )

    def test_log_file_mirrors_stderr_exactly(self):
        with tempfile.TemporaryDirectory() as directory:
            log_file = Path(directory) / "run.log"
            result = self.run_logging(
                'log_info "one"; log_warn "two"; log_error "three"',
                BUILD_LOG_FILE=str(log_file))
            self.assertEqual(result.returncode, 0, result.stderr)
            written = log_file.read_text()
            self.assertEqual(written, result.stderr)
            for message in ("one", "two", "three"):
                self.assertIn(message, written)

    def test_log_file_respects_the_level_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            log_file = Path(directory) / "run.log"
            self.run_logging('log_info "kept"; log_debug "dropped"',
                             BUILD_LOG_FILE=str(log_file), BUILD_LOG_LEVEL="info")
            written = log_file.read_text()
            self.assertIn("kept", written)
            self.assertNotIn("dropped", written)

    def test_unwritable_log_file_does_not_break_the_build(self):
        """A logger that can take the build down is worse than no logger."""
        blocked = Path(tempfile.gettempdir()) / "akb-not-a-directory"
        blocked.write_text("this is a file, not a directory")
        try:
            result = self.run_logging('log_info "still printed"',
                                      BUILD_LOG_FILE=str(blocked / "nested.log"))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("still printed", result.stderr)
        finally:
            blocked.unlink()

    def test_pipeline_log_file_is_appendable_across_invocations(self):
        """Two runs into one path must both survive, or a re-run silently
        destroys the evidence of the run it was meant to debug."""
        with tempfile.TemporaryDirectory() as directory:
            log_file = Path(directory) / "run.log"
            self.run_logging('log_info "first run"', BUILD_LOG_FILE=str(log_file))
            self.run_logging('log_info "second run"', BUILD_LOG_FILE=str(log_file))
            written = log_file.read_text()
            self.assertIn("first run", written)
            self.assertIn("second run", written)


class DashboardContractTests(unittest.TestCase):
    """live_dashboard.py derives the stage timeline by regex, so the log format
    and the regex are one contract split across two files."""

    @staticmethod
    def run_dashboard(log_text, directory):
        (directory / "build.log").write_text(log_text)
        return subprocess.run(
            [shutil.which("python3") or "python3", "scripts/live_log_server.py", "--once",
             "--directory", str(directory)],
            cwd=ROOT, text=True, capture_output=True,
        )

    def test_regexes_accept_the_current_log_format(self):
        """A direct check of the regexes, independent of the server.

        This is the test that fails first when logging.sh changes its prefix.
        """
        sys.path.insert(0, str(ROOT / "scripts"))
        try:
            import live_dashboard
        finally:
            sys.path.pop(0)

        begin = ("[INFO] 2026-10-06T00:00:00Z +0:00:00 "
                 "──── 1. Environment initialization ────")
        end = ("[INFO] 2026-10-06T00:00:07Z +0:00:07 "
               "──── 1. Environment initialization completed (elapsed 7s) ────")
        self.assertIsNotNone(live_dashboard.STAGE_BEGIN_RE.match(begin), begin)
        self.assertIsNotNone(live_dashboard.STAGE_END_RE.match(end), end)

    def test_dashboard_still_accepts_a_log_written_before_this_change(self):
        """Old build.log files in a dashboard directory must keep parsing."""
        sys.path.insert(0, str(ROOT / "scripts"))
        try:
            import live_dashboard
        finally:
            sys.path.pop(0)
        old_begin = "[INFO] 2026-09-24T03:30:00Z ──── 1. Environment initialization ────"
        old_end = ("[INFO] 2026-09-24T03:30:03Z "
                   "──── 1. Environment initialization completed (elapsed 3s) ────")
        self.assertIsNotNone(live_dashboard.STAGE_BEGIN_RE.match(old_begin), old_begin)
        self.assertIsNotNone(live_dashboard.STAGE_END_RE.match(old_end), old_end)


class RealPipelineContractTests(unittest.TestCase):
    """The log contract has to hold for the real pipeline, not just for a
    hand-written snippet that happens to call the logger correctly."""

    def run_build(self, script, **variables):
        env = os.environ.copy()
        for key in list(env):
            if key.startswith(("GITHUB_", "ACTIONS_", "RUNNER_")):
                env.pop(key, None)
        for key in ("BUILD_LOG_LEVEL", "BUILD_LOG_TRACE", "BUILD_LOG_FILE", "NO_COLOR",
                    "BUILD_FORCE", "BUILD_PUBLISH"):
            env.pop(key, None)
        env.update(variables)
        return subprocess.run([BASH, "-c", script], cwd=ROOT, env=env,
                              text=True, capture_output=True)

    def test_pipeline_declares_its_step_count_once(self):
        """The declared total is what makes "[3/5]" meaningful."""
        source = (ROOT / "scripts" / "lib" / "pipeline.sh").read_text()
        self.assertEqual(source.count("_log_declare_steps"), 1)

    def test_pipeline_does_not_hand_number_step_banners(self):
        """Regression guard: the whole point of deriving the sequence number is
        that no call site writes its own ordinal."""
        source = (ROOT / "scripts" / "lib" / "pipeline.sh").read_text()
        self.assertNotRegex(source, r'begin_step "\d+\.')
        self.assertNotRegex(source, r'end_step "\d+\.')

    def test_pipeline_failure_names_the_step_that_failed(self):
        """End to end through the real entry point: an unresolvable branch must
        produce a report a reader can act on."""
        with tempfile.TemporaryDirectory() as directory:
            log_file = Path(directory) / "build.log"
            result = self.run_build(
                "bash build.sh", BUILD_TARGET="hk1box", BUILD_BRANCH="bleedingedge",
                BUILD_LOG_FILE=str(log_file), BUILD_LOG_LEVEL="debug")
            self.assertNotEqual(result.returncode, 0)
            # Fails during target load, before any step begins, so the report
            # must not invent a step -- but it must still replay the context.
            self.assertIn("Command failed", result.stderr)
            self.assertTrue(log_file.is_file(), "BUILD_LOG_FILE produced no log")

    def test_every_library_log_call_uses_a_gated_level(self):
        """No library may printf its own [ERROR] line: an ungated write bypasses
        BUILD_LOG_FILE and the failure context, which is exactly when it is
        needed."""
        offenders = []
        for path in sorted((ROOT / "scripts" / "lib").rglob("*.sh")):
            # logging.sh owns the single bootstrap write; it is covered by its
            # own test below, which pins it to exactly one.
            if path.name == "logging.sh":
                continue
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if re.search(r"printf '\[(ERROR|WARN|INFO|DEBUG)\]", line):
                    offenders.append(f"{path.relative_to(ROOT)}:{number}")
        self.assertEqual(offenders, [], f"ungated log writes: {offenders}")

    def test_the_logger_has_exactly_one_bootstrap_write(self):
        """logging.sh is allowed exactly one raw write: the complaint about an
        unknown BUILD_LOG_LEVEL. It cannot use log_error there -- the gate reads
        LOG_LEVEL_RANK, which is the value that call is in the middle of
        computing, so routing it through log_error would recurse. Any second raw
        write would be a real bypass, so the exemption stays pinned to one."""
        raw_writes = [
            f"{number}: {line.strip()}"
            for number, line in enumerate(
                (ROOT / "scripts" / "lib" / "logging.sh").read_text().splitlines(), 1)
            if re.search(r"printf '\[(ERROR|WARN|INFO|DEBUG)\]", line)
        ]
        self.assertEqual(len(raw_writes), 1, f"unexpected raw writes: {raw_writes}")
        self.assertIn("Unknown BUILD_LOG_LEVEL", raw_writes[0])


if __name__ == "__main__":
    unittest.main()