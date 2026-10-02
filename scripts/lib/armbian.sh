#!/usr/bin/env bash
# Sourced library: definitions only; no build or external side effects.
run_armbian_build() {
	local build_root="$1"
	shift

	(
		cd "${build_root}"
		./build_with_diy.sh "$@"
	)
}

# Match Armbian's board search paths before paying the Docker startup cost.
validate_armbian_board_registration() {
    local build_root="$1" board="$2" directory type
    for directory in "${build_root}/config/boards" "${build_root}/userpatches/config/boards"; do
        for type in conf wip csc eos tvb; do
            if [[ -f "${directory}/${board}.${type}" ]]; then
                log_info "Board configuration located: ${directory}/${board}.${type}"
                return 0
            fi
        done
    done
    log_error "No board configuration for ${board}; expected config/boards or userpatches/config/boards inside ${build_root}"
    return 1
}
