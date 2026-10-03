#!/usr/bin/env bash
# Profiles are trusted, version-controlled Bash data, never downloaded or eval'd.
build_targets_directory() {
    printf '%s\n' "${BUILD_TARGETS_DIR:-${BUILD_PROJECT_ROOT}/userpatches/config/build-targets}"
}

list_build_targets() {
    local directory path
    directory="$(build_targets_directory)"
    for path in "${directory}"/*.conf; do
        [[ -f "${path}" ]] || continue
        path="${path##*/}"
        printf '%s\n' "${path%.conf}"
    done
}

load_build_target() {
    BUILD_TARGET="${BUILD_TARGET:-rockchip64}"
    [[ "${BUILD_TARGET}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
        echo '[ERROR] Unsafe BUILD_TARGET identifier' >&2; return 1
    }
    local profile field branch found=no
    profile="$(build_targets_directory)/${BUILD_TARGET}.conf"
    [[ -f "${profile}" ]] || {
        printf '[ERROR] Unknown BUILD_TARGET: %s\n' "${BUILD_TARGET}" >&2; return 1
    }
    # Reset all schema fields and callbacks so sequential loads cannot leak data.
    for field in TARGET_BOARD TARGET_FAMILY TARGET_ARCH TARGET_KBUILD_ARCH TARGET_RUNNER \
        TARGET_VERSION_CONFIG TARGET_RELEASE_PREFIX TARGET_ADAPTER TARGET_BOARD_DTB; do
        unset "${field}"
    done
    declare -ga TARGET_BRANCHES=() TARGET_REQUIRED_Y=()
    declare -gA TARGET_SERIES=()
    unset -f target_package_artifacts target_extra_release_assets target_adapter_validate
    source "${profile}"
    for field in TARGET_BOARD TARGET_FAMILY TARGET_ARCH TARGET_KBUILD_ARCH TARGET_RUNNER TARGET_ADAPTER; do
        [[ "${!field:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
            printf '[ERROR] Invalid or missing target field: %s\n' "${field}" >&2; return 1
        }
    done
    [[ "${TARGET_VERSION_CONFIG:-}" =~ ^([A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+\.(inc|conf)$ && \
        "${TARGET_RELEASE_PREFIX:-}" =~ ^[A-Za-z0-9._-]*$ ]] || return 1
    case "${TARGET_ARCH}:${TARGET_KBUILD_ARCH}" in
        arm64:arm64|armhf:arm|amd64:x86|riscv64:riscv) ;;
        *) echo '[ERROR] Invalid Debian/Kbuild architecture mapping' >&2; return 1 ;;
    esac
    ((${#TARGET_BRANCHES[@]} > 0)) || return 1
    for branch in "${TARGET_BRANCHES[@]}"; do
        [[ "${branch}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
        [[ -z "${TARGET_SERIES[${branch}]:-}" || "${TARGET_SERIES[${branch}]}" =~ ^[0-9]+\.[0-9]+$ ]] || return 1
        [[ "${BUILD_BRANCH:-auto}" != "${branch}" ]] || found=yes
    done
    branch_list=("${TARGET_BRANCHES[@]}")
    if [[ "${BUILD_BRANCH:-auto}" != auto ]]; then
        [[ "${found}" == yes ]] || {
            printf '[ERROR] Branch %s is not supported by target %s\n' "${BUILD_BRANCH}" "${BUILD_TARGET}" >&2
            return 1
        }
        branch_list=("${BUILD_BRANCH}")
    fi
    if [[ -n "${TARGET_BOARD_DTB:-}" ]]; then
        [[ "${TARGET_BOARD_DTB}" =~ ^[A-Za-z0-9_-]+/[A-Za-z0-9._-]+\.dtb$ ]] || return 1
    fi
    for field in "${TARGET_REQUIRED_Y[@]}"; do
        [[ "${field}" =~ ^[A-Za-z0-9_]+$ ]] || return 1
    done
    case "${BUILD_PUBLISH:-yes}" in yes|no) ;; *) return 1 ;; esac
    case "${BUILD_FORCE:-no}" in yes|no) ;; *) return 1 ;; esac
    local adapter="${BUILD_LIBRARY_ROOT:-${BUILD_PROJECT_ROOT}/scripts/lib}/adapters/${TARGET_ADAPTER}.sh"
    [[ -f "${adapter}" ]] || { echo '[ERROR] Unknown packaging adapter' >&2; return 1; }
    source "${adapter}"
    declare -F target_package_artifacts >/dev/null || return 1
    declare -F target_extra_release_assets >/dev/null || return 1
    declare -F target_adapter_validate >/dev/null || return 1
    target_adapter_validate || return 1
    BUILD_BOARD="${TARGET_BOARD}"
    BUILD_FAMILY="${TARGET_FAMILY}"
    BUILD_ARCH="${TARGET_ARCH}"
    RELEASE_PREFIX="${TARGET_RELEASE_PREFIX:-}"
    export BUILD_TARGET BUILD_FAMILY BUILD_ARCH
}

validate_target_series() {
    local branch="$1" series="$2" expected="${TARGET_SERIES[$1]:-}"
    [[ -z "${expected}" || "${expected}" == "${series}" ]] || {
        printf '[ERROR] %s / %s requires kernel series %s, got %s\n' \
            "${BUILD_TARGET}" "${branch}" "${expected}" "${series}" >&2
        return 1
    }
}

describe_build_target() {
    printf 'target=%s\nboard=%s\nfamily=%s\narch=%s\nkbuild_arch=%s\nrunner=%s\nadapter=%s\nbranches=%s\n' \
        "${BUILD_TARGET}" "${TARGET_BOARD}" "${TARGET_FAMILY}" "${TARGET_ARCH}" \
        "${TARGET_KBUILD_ARCH}" "${TARGET_RUNNER}" "${TARGET_ADAPTER}" "${branch_list[*]}"
}
