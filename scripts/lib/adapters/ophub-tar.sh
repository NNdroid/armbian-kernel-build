#!/usr/bin/env bash
# Adapt installation format only; compilation always stays in Armbian.
target_adapter_validate() {
    # The current worker is specifically validated for HK1 Box ARM64 / 7.2.
    # Other boards can introduce their own adapter without changing the pipeline.
    [[ "${TARGET_BOARD}" == hk1box && "${TARGET_ARCH}" == arm64 ]] || {
        echo '[ERROR] ophub-tar currently supports HK1 Box ARM64 only' >&2
        return 1
    }
}
target_package_artifacts() {
    bash "${BUILD_PROJECT_ROOT}/scripts/package_hk1box.sh" "$@"
}
target_extra_release_assets() {
    local version="$1" path
    local -a paths=()
    mapfile -t paths < <(compgen -G "./build/output/${BUILD_TARGET}/${version}-*.tar.gz*" || true)
    ((${#paths[@]} > 0)) || {
        echo '[ERROR] Installation bundle is missing; refusing incomplete release' >&2
        return 1
    }
    for path in "${paths[@]}"; do printf '%s\n' "${path}"; done
}
