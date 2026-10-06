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
    # No series requirement here, and that is a deliberate reversal. A lock used
    # to be mandatory for this adapter, which pinned every such board to one
    # Armbian series until a human re-verified the boot chain. It is now
    # optional: when a profile declares one, validate_target_series aborts the
    # build if Armbian moves the branch off it, so a declared lock stays a real
    # gate; when it declares none, the target tracks Armbian and the packaging
    # derives the series from the version it built.
    #
    # Dropping the lock does not weaken the board checks, which are what actually
    # protect it: the packaging verifies the ARM64 Image text_offset, the DTB mmc
    # aliases and /memory@0 against the bytes it just built, so a branch that
    # moves in a way this board cannot boot fails on evidence rather than on a
    # version comparison made before the compile. A malformed lock needs no check
    # here either -- the schema's series validator rejects it while loading.
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
