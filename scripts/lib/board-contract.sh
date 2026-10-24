#!/usr/bin/env bash
# Validate a target's optional board contract against the extracted image DEB.
# Uses the wrapper's manifest reader and logging; never reads a kernel worktree.
validate_board_contract() {
    local evidence_dir="$1" package_root="$2" config="$3"
    local manifest="${evidence_dir}/source-manifest.env" board dtb source_sha symbol
    if [[ -n "${TARGET_BOARD_DTB:-}" ]]; then
        board="$(require_manifest_value "${manifest}" board)" || return 1
        # board_dtb is written only when the DTS that BOOT_FDT_FILE names was
        # present in the kernel tree. A missing key therefore means the source
        # file was never there, which for this target means the board patch that
        # adds it did not apply. Name that instead of the generic "missing key"
        # the manifest reader reports, which pointed at the evidence collector.
        if ! dtb="$(require_manifest_value "${manifest}" board_dtb)"; then
            _kernel_inject_log err "Board evidence incomplete" \
                "${TARGET_BOARD_DTB} was not built, so no DTS provenance was recorded"
            _kernel_inject_log err "Board evidence incomplete" \
                "The board patch that adds it did not apply; check the log for 'Using kernel patch dir:' and the patch set under ${USERPATCHES_PATH:-userpatches}/${TARGET_BOARD_PATCHES:-}"
            return 1
        fi
        source_sha="$(require_manifest_value "${manifest}" board_dts_sha256)" || return 1
        if [[ "${board}" != "${TARGET_BOARD}" || "${dtb}" != "${TARGET_BOARD_DTB}" || \
            ! -s "${evidence_dir}/board.dts" || \
            "$(sha256sum "${evidence_dir}/board.dts" | awk '{print $1}')" != "${source_sha}" ]]; then
            _kernel_inject_log err "Board evidence mismatch" "DTS and its hash must come from the built kernel package"
            return 1
        fi
        local -a board_dtbs=()
        mapfile -d '' -t board_dtbs < <(find "${package_root}/usr/lib" -type f \
            -name "${TARGET_BOARD_DTB##*/}" -print0)
        ((${#board_dtbs[@]} == 1)) || {
            _kernel_inject_log err "Board DTB missing" "Expected one ${TARGET_BOARD_DTB} in the image package"
            return 1
        }
    fi
    local actual
    local -a missing=()
    for symbol in "${TARGET_REQUIRED_Y[@]}"; do
        if ! grep -qx "CONFIG_${symbol}=y" "${config}"; then
            actual="$(sed -n "s/^CONFIG_${symbol}=//p" "${config}")"
            missing+=("CONFIG_${symbol}=y(actual=${actual:-n/undefined})")
        fi
    done
    if ((${#missing[@]})); then
        _kernel_inject_log err "Boot-critical driver missing" "${TARGET_BOARD}: ${missing[*]}"
        return 1
    fi
    _kernel_inject_log info "Board verification" "${TARGET_BOARD}: declared DTB and built-in driver requirements verified"
}
