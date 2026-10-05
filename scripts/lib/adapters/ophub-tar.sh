#!/usr/bin/env bash
# Adapt installation format only; compilation always stays in Armbian.
#
# The ophub-tar layout is generic: every board-specific value (series lock, DTB,
# boot checks) comes from the target profile, so this adapter is not tied to any
# one board and a new ophub-tar target needs no code here.
target_adapter_validate() {
    # ophub-tar installs a DTB, so a target using this adapter must name one.
    [[ -n "${TARGET_BOARD_DTB:-}" ]] || {
        log_error 'Target %s selects the ophub-tar adapter but declares no TARGET_BOARD_DTB' \
            "${BUILD_TARGET}"
        return 1
    }
    # The container validates the built release against the pinned series, so a
    # target that declares no lock could never be packaged. Fail here instead of
    # after a full kernel build.
    local branch
    for branch in "${TARGET_BRANCHES[@]}"; do
        [[ -n "${TARGET_SERIES[${branch}]:-}" ]] || {
            log_error 'Target %s / %s needs a TARGET_SERIES lock for ophub-tar packaging' \
                "${BUILD_TARGET}" "${branch}"
            return 1
        }
    done
}
target_package_artifacts() {
    bash "${BUILD_PROJECT_ROOT}/scripts/package_ophub_tar.sh" "$@"
}
target_extra_release_assets() {
    local version="$1" path
    local -a paths=()
    mapfile -t paths < <(compgen -G "./build/output/${BUILD_TARGET}/${version}-*.tar.gz*" || true)
    ((${#paths[@]} > 0)) || {
        log_error 'Installation bundle is missing; refusing incomplete release'
        return 1
    }
    for path in "${paths[@]}"; do printf '%s\n' "${path}"; done
}
