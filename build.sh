#!/usr/bin/env bash
# Thin public entry point. Libraries can also be sourced by regression tests.
set -Eeuo pipefail
BUILD_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
for build_library in logging host versions artifacts release armbian targets pipeline; do
    source "${BUILD_PROJECT_ROOT}/scripts/lib/${build_library}.sh"
done
unset build_library

if [[ "${BUILD_SCRIPT_LIB_ONLY:-no}" == yes ]]; then
    return 0 2>/dev/null || exit 0
fi

case "${1:-}" in
    --list-targets) list_build_targets ;;
    --describe-target)
        [[ $# -le 2 ]] || { echo 'Usage: build.sh --describe-target [target]' >&2; exit 1; }
        BUILD_TARGET="${2:-${BUILD_TARGET:-rockchip64}}"
        load_build_target
        describe_build_target
        ;;
    '') build_main ;;
    *) echo 'Usage: build.sh [--list-targets | --describe-target [target]]' >&2; exit 1 ;;
esac
