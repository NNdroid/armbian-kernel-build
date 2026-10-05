#!/usr/bin/env bash
# Sourced library: definitions only; no build or external side effects.
#
# Debuggability contract
# ----------------------
# A kernel build runs for hours and fails inside a Docker container. When it
# does, the only things that matter are: which step was running, how long it had
# been running, the last thing that happened before the failure, and what to
# change to see more. This module exists to make all four answerable.
#
#   BUILD_LOG_LEVEL   error | warn | info | debug | trace (default: info)
#                     Verbosity gate. Everything at or above the level prints;
#                     anything below costs one integer comparison.
#   BUILD_LOG_TRACE   1 to also emit a shell execution trace (set -x)
#   BUILD_LOG_FILE    path to mirror the rendered log into, in addition to stderr
#
# `trace` is deliberately a level rather than a separate switch: the point of
# asking for more output is to see commands, and a trace that could not be
# requested together with debug output would be a trap.
#
# Every line goes to stderr, including log_info. That is the one convention this
# module insists on: build.sh runs under `set -o pipefail` while CI pipes stdout
# into a redactor and then `tee`, and when two streams share a pipe their
# interleaving is decided by stdio buffering rather than by when the message was
# produced. A build log whose INFO and ERROR lines are reordered relative to
# real time is worse than no log at all, because it actively misleads.

# Levels, ordered. Declared as data so the gate, the help text and the tests all
# read the same list instead of three hand-maintained copies of it.
LOG_LEVELS=(error warn info debug trace)

LOG_LEVEL_DEFAULT=info
# Ring buffer of recent rendered lines, replayed on failure. Bounded because a
# 6-hour build would otherwise accumulate the whole log in memory.
LOG_CONTEXT_LINES=${LOG_CONTEXT_LINES:-40}

_LOG_RING=()
_LOG_START_SECONDS=${SECONDS}
_LOG_STEP_INDEX=0
_LOG_STEP_SEQ=0
_LOG_STEP_NAME='(none)'
_LOG_STEP_STARTED=0
_LOG_STEP_ACTIVE=no
_LOG_COLOUR=no
_LOG_FILE=${BUILD_LOG_FILE:-}

# Color is for a human watching a terminal. In a log file, in CI, or behind a
# pipe it is noise that breaks grep and confuses the dashboard's ANSI stripping,
# so it is enabled only for an actual TTY on stderr.
_log_init_colour() {
	if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-dumb}" != dumb ]]; then
		_LOG_COLOUR=yes
	else
		_LOG_COLOUR=no
	fi
}

# Resolve BUILD_LOG_LEVEL to an integer rank once, at source time. Doing this per
# log line would mean re-parsing an environment variable on every call, which is
# the kind of cost that makes people turn logging off.
_log_init_level() {
	local requested="${BUILD_LOG_LEVEL:-${LOG_LEVEL_DEFAULT}}" rank index

	rank=1
	for index in "${!LOG_LEVELS[@]}"; do
		if [[ "${LOG_LEVELS[index]}" == "${requested}" ]]; then
			rank=$((index + 1))
			break
		fi
	done

	if ((rank == 1)) && [[ "${requested}" != "${LOG_LEVELS[0]}" ]]; then
		# An unrecognised level must not silently fall back to the default: a
		# typo in BUILD_LOG_LEVEL would otherwise produce a plausible-looking
		# log at the wrong verbosity and send the reader looking for output
		# that was never emitted.
		printf '[ERROR] Unknown BUILD_LOG_LEVEL=%s; expected one of: %s\n' \
			"${requested}" "${LOG_LEVELS[*]}" >&2
		rank=2
	fi

	LOG_LEVEL_RANK=${rank}
}

_log_init_colour
_log_init_level
LOG_START_SECONDS=${SECONDS}

# Human-readable size for a single regular file. stat(1) is preferred over du(1)
# because du reports the allocated block count: on a sparse or hardlinked
# artifact the two disagree, and du also walks the file a second time when the
# caller already measured it for logging.
file_size_human() {
	local target="$1" bytes

	if ! bytes="$(stat -c '%s' "${target}" 2>/dev/null)"; then
		bytes="$(stat -f '%z' "${target}" 2>/dev/null)" || {
			printf 'unknown\n'
			return 1
		}
	fi
	awk -v bytes="${bytes}" 'BEGIN {
		split("B KiB MiB GiB TiB", unit, " ")
		# "index" is an awk built-in function name and cannot be a variable.
		position = 1
		while (bytes >= 1024 && position < 5) { bytes /= 1024; position++ }
		printf (position == 1 ? "%d %s\n" : "%.1f %s\n"), bytes, unit[position]
	}'
}

# Whether printf's %(...)T conversion is usable. That builtin is the only reason
# timestamping does not cost a fork per log line; `date` would spawn a process for
# every line, which over a 200k-line kernel build log is 400k processes spent on
# timestamps. The probe keeps the module usable on bash older than 4.2.
if [[ -z "${_LOG_BUILTIN_TIME:-}" ]]; then
	if printf -v _LOG_BUILTIN_TIME '%(%Y-%m-%dT%H:%M:%SZ)T' -1 2>/dev/null; then
		_LOG_BUILTIN_TIME=yes
	else
		_LOG_BUILTIN_TIME=no
	fi
fi

# Seconds since the logger was initialized, as H:MM:SS. Wall-clock timestamps
# alone force the reader to do arithmetic to answer "how long has this step been
# running", which is the first question after any stall.
_log_elapsed() {
	local total=$((SECONDS - LOG_START_SECONDS))
	printf '%d:%02d:%02d' $((total / 3600)) $(((total % 3600) / 60)) $((total % 60))
}

# Renders into _LOG_LINE rather than printing. Returning through stdout would
# force the caller to use $(...), and command substitution forks a subshell --
# one extra process for every line of a log that can reach 200k lines.
_log_render() {
	local level="$1" step="$2" message="$3" color reset dim stamp elapsed total

	if [[ "${_LOG_COLOUR}" == yes ]]; then
		reset=$'\e[0m'
		dim=$'\e[2m'
		case "${level}" in
			ERROR) color=$'\e[31m' ;;
			WARN)  color=$'\e[33m' ;;
			DEBUG) color=$'\e[34m' ;;
			*)     color=$'\e[32m' ;;
		esac
	else
		# Every escape has to collapse, including the dim one on the timestamp.
		# Leaving just the dim sequence behind is what puts stray control
		# characters into build.log and defeats grep on a CI artifact.
		reset=''
		color=''
		dim=''
	fi

	# printf's %(...)T conversion is a bash builtin, so the timestamp costs no
	# fork; `date` would spawn a process per line. The fallback keeps the module
	# usable on bash older than 4.2, which is the only case that pays for it.
	if [[ "${_LOG_BUILTIN_TIME}" == yes ]]; then
		printf -v stamp '%(%Y-%m-%dT%H:%M:%SZ)T' -1
	else
		stamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
	fi

	# Seconds since the logger was initialized. Wall-clock timestamps alone force
	# the reader to do arithmetic to answer "how long has this step been
	# running", which is the first question after any stall.
	total=$((SECONDS - LOG_START_SECONDS))
	printf -v elapsed '%d:%02d:%02d' \
		$((total / 3600)) $(((total % 3600) / 60)) $((total % 60))

	# Shape kept compatible with live_dashboard.py's BUILD_LOG_PREFIX:
	#   [LEVEL] <utc timestamp> +<elapsed> [<step>] <message>
	# The dashboard strips ANSI and then matches this prefix, so the level tag
	# and the timestamp must stay first and stay in that order.
	printf -v _LOG_LINE '%s[%s]%s %s%s%s +%s %s%s' \
		"${color}" "${level}" "${reset}" "${dim}" "${stamp}" "${reset}" \
		"${elapsed}" "${step}" "${message}"
}

# Single sink for every level. Keeping one writer is what makes the file mirror,
# the ring buffer and the stderr stream impossible to drift apart.
_log_emit() {
	local level="$1" rank="$2"
	shift 2

	# The gate runs before anything else, including string building: at
	# BUILD_LOG_LEVEL=error a debug line must cost one integer comparison.
	((rank <= LOG_LEVEL_RANK)) || return 0

	local step
	if [[ "${_LOG_STEP_ACTIVE}" == yes ]]; then
		step="[${_LOG_STEP_SEQ}/${_LOG_STEP_INDEX} ${_LOG_STEP_NAME}] "
	else
		step=''
	fi

	# printf-style when the caller passed a format plus values, literal when it
	# passed one pre-built string. The distinction matters: expanding a lone
	# argument would corrupt any message that happens to contain a percent sign,
	# and not expanding a format string would print the specifiers verbatim.
	# Formatting happens after the gate so a suppressed line still costs nothing.
	local message
	if (($# > 1)); then
		printf -v message "$@"
	else
		message="$*"
	fi

	# Rendered once into _LOG_LINE and then emitted three times verbatim, so the
	# stderr stream, the log file and the failure context cannot differ by a
	# single byte -- a mismatch there would make the replayed context a lie.
	_log_render "${level}" "${step}" "${message}"

	printf '%s\n' "${_LOG_LINE}" >&2
	if [[ -n "${_LOG_FILE}" ]]; then
		# Best effort: a log file that cannot be written must never take the
		# build down, and the failure is already visible on stderr.
		printf '%s\n' "${_LOG_LINE}" >> "${_LOG_FILE}" 2>/dev/null || true
	fi

	_LOG_RING+=("${_LOG_LINE}")
	if ((${#_LOG_RING[@]} > LOG_CONTEXT_LINES)); then
		_LOG_RING=("${_LOG_RING[@]:1}")
	fi
	return 0
}

log_error() { _log_emit ERROR 1 "$@"; }
log_warn()  { _log_emit WARN 2 "$@"; }
log_info()  { _log_emit INFO 3 "$@"; }
log_debug() { _log_emit DEBUG 4 "$@"; }

# Step tracking. The sequence number is derived rather than passed in: a
# hand-written "4." in the call site drifts the moment a step is inserted or
# skipped, and a step banner that says "4" when it is the sixth thing that ran
# sends the reader hunting for a step that does not exist.
begin_step() {
	_LOG_STEP_STARTED=${SECONDS}
	_LOG_STEP_ACTIVE=no
	_LOG_STEP_SEQ=$((_LOG_STEP_SEQ + 1))
	# The banner carries the running sequence number, which is what the reader
	# (and live_dashboard.py's stage regex) keys off. It is deliberately not the
	# declared total: steps run inside loops, so "4 of 7" may execute six times.
	log_info "──── ${_LOG_STEP_SEQ}. $1 ────"
	_LOG_STEP_NAME="$1"
	_LOG_STEP_ACTIVE=yes
}

end_step() {
	[[ "${_LOG_STEP_ACTIVE}" == yes ]] || {
		log_warn "end_step '${1:-}' called with no matching begin_step"
		return 0
	}
	local elapsed=$((SECONDS - _LOG_STEP_STARTED))
	_LOG_STEP_ACTIVE=no
	log_info "──── ${_LOG_STEP_SEQ}. ${1} completed (elapsed ${elapsed}s) ────"
}

# Announce the total step count once, right before the first step starts. Doing
# it here rather than deriving it from a call to begin_step means the pipeline
# states its own shape instead of the logger inferring it.
_log_declare_steps() {
	_LOG_STEP_INDEX=$1
	_LOG_STEP_SEQ=0
	_LOG_STEP_NAME='(none)'
	_LOG_STEP_ACTIVE=no
}

# Replay recent output at the point of failure. An error message naming a file
# and a line number is only half the story; the lines immediately before it are
# usually where the actual cause is, and they are exactly what a CI log viewer
# scrolls away.
# Replays the tail of the ring buffer. Written straight to stderr rather than
# through log_info on purpose: these lines are already formatted, and routing
# them back through the formatter would re-stamp them, so the replay would show
# a later timestamp than the lines it is replaying. They are appended to the log
# file too -- the replay exists precisely to give BUILD_LOG_FILE the context
# leading up to a failure, so keeping it off stderr-only would defeat it.
_log_dump_context() {
	local line
	_log_write_raw "──── last ${#_LOG_RING[@]} log lines ────"
	for line in "${_LOG_RING[@]}"; do
		_log_write_raw "  ${line}"
	done
}

# Unformatted pass-through to stderr and the log file. The third and last
# writer in the logger; it exists only for content that must not be
# re-rendered, namely the failure replay.
_log_write_raw() {
	printf '%s\n' "$1" >&2
	if [[ -n "${_LOG_FILE}" ]]; then
		printf '%s\n' "$1" >> "${_LOG_FILE}" 2>/dev/null || true
	fi
	return 0
}

report_unhandled_error() {
	local exit_code="$1"
	local line_number="$2"
	local failed_command="$3"

	trap - ERR
	log_error "Command failed: exit=${exit_code}, line=${line_number}, command=${failed_command}"
	log_error "Working directory at failure: ${PWD}"
	if [[ "${_LOG_STEP_ACTIVE}" == yes ]]; then
		log_error "Failing step: [${_LOG_STEP_SEQ}/${_LOG_STEP_INDEX}] ${_LOG_STEP_NAME} (running for $((SECONDS - _LOG_STEP_STARTED))s)"
	fi
	if [[ -n "${_LOG_FILE}" ]]; then
		log_error "Full log: ${_LOG_FILE}"
	else
		log_error "No log file configured; set BUILD_LOG_FILE to keep a durable copy of this run"
	fi
	log_error "Re-run with BUILD_LOG_LEVEL=debug for decision-level detail, or BUILD_LOG_LEVEL=trace for shell execution"
	_log_dump_context
	exit "${exit_code}"
}