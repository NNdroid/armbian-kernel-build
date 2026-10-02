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
