#!/usr/bin/env bash
# Thin public entry point. Libraries can also be sourced by regression tests.
set -Eeuo pipefail
BUILD_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
for build_library in logging host versions artifacts release armbian targets pipeline; do
    source "${BUILD_PROJECT_ROOT}/scripts/lib/${build_library}.sh"
done
unset build_library

# Shell execution trace, requested as a log level so that asking for more detail
# is a single knob. BUILD_LOG_TRACE=1 is honored as an alias so a caller who
# only wants the trace does not have to also know the level name; it must be
# folded into BUILD_LOG_LEVEL before logging.sh reads it.
if [[ "${BUILD_LOG_TRACE:-0}" == 1 && "${BUILD_LOG_LEVEL:-info}" != trace ]]; then
	BUILD_LOG_LEVEL=trace
	export BUILD_LOG_LEVEL
fi

# Enabled after the libraries are sourced deliberately: the libraries are pure
# definitions and tracing the sourcing produces noise without covering anything
# the caller wanted to see.
#
# PS4 carries line and function names because a bare "+" trace is close to
# unreadable in a 200k-line log. Both expansions must tolerate an unset variable:
# this shell runs under `set -u`, and at top level in a `bash -c` one-liner
# BASH_SOURCE has no element 0, so a naive ${BASH_SOURCE[0]} reference would abort
# the run the moment tracing was switched on -- exactly when the run is already
# in trouble.
if [[ "${BUILD_LOG_LEVEL:-info}" == trace ]]; then
	PS4='+ ${SECONDS}s ${BASH_SOURCE:-$0}:${LINENO}:${FUNCNAME[0]:-main}> '
	export PS4
	set -x
fi

if [[ "${BUILD_SCRIPT_LIB_ONLY:-no}" == yes ]]; then
    return 0 2>/dev/null || exit 0
fi

case "${1:-}" in
    --list-targets)
        shift
        case "${1:-}" in
            # The scheduled workflow builds every target and needs each one's
            # runner to pick a machine, so the id list is not enough on its own.
            --json) list_build_targets_json ;;
            '') list_build_targets ;;
            *) cat >&2 <<'JSON_USAGE'
Usage: build.sh --list-targets [--json]

  (no flag)  print every declared target id, one per line
  --json     print a GitHub Actions matrix object including runner, board and
             family, resolved from each profile
JSON_USAGE
                exit 1
                ;;
        esac
        ;;
    --check-targets)
        [[ $# -le 1 ]] || { echo 'Usage: build.sh --check-targets' >&2; exit 1; }
        check_all_targets
        ;;
    --new-target)
        shift
        new_build_target "$@"
        ;;
    --describe-target)
        [[ $# -le 2 ]] || { echo 'Usage: build.sh --describe-target [target]' >&2; exit 1; }
        BUILD_TARGET="${2:-${BUILD_TARGET:-rockchip64}}"
        load_build_target
        describe_build_target
        ;;
    '') build_main ;;
    *) cat >&2 <<'USAGE'
Usage: build.sh [--list-targets [--json] | --check-targets | --new-target <id> | --describe-target [target]]

  (no arguments)       build the configured target
  --list-targets       print every declared target id
  --list-targets --json  print the same list as an Actions matrix with runners
  --check-targets      load and validate every target profile
  --new-target <id>    scaffold a new target profile and its Armbian board shim
  --describe-target    print the fully resolved profile for a target

Environment:
  BUILD_TARGET       target id to build (default: rockchip64)
  BUILD_BRANCH       branch to build, or auto for every declared branch
  BUILD_FORCE=yes    build even when the upstream version was already released
  BUILD_PUBLISH=no   build and validate artifacts without publishing a release

Debugging:
  BUILD_LOG_LEVEL    error | warn | info | debug | trace (default: info)
                     debug adds decision-level detail, trace adds a shell trace
  BUILD_LOG_FILE     also write the log to this path
  BUILD_LOG_TRACE    deprecated alias for BUILD_LOG_LEVEL=trace
USAGE
        exit 1
        ;;
esac