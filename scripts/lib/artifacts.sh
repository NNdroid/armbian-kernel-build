#!/usr/bin/env bash
# Sourced library: definitions only; no build or external side effects.
resolve_built_version() {
	local branch="$1"
	local build_marker="${2:-}"
	local debs_dir="./build/output/debs"
	local newest_deb
	local built_version
	local -a freshness_filter=()

	if [[ -n "${build_marker}" ]]; then
		[[ -f "${build_marker}" ]] || {
			log_error "Build artifact marker does not exist: ${build_marker}"
			return 1
		}
		freshness_filter=(-newer "${build_marker}")
	fi

	newest_deb="$(find "${debs_dir}" -type f \
		-name "linux-image-${branch}-${BUILD_FAMILY:-rockchip64}_*.deb" "${freshness_filter[@]}" \
		-printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)"
	if [[ -z "${newest_deb}" ]]; then
		log_error "No linux-image-${branch}-${BUILD_FAMILY:-rockchip64}_*.deb produced by this build was found."
		return 1
	fi
	log_debug "${branch}: newest artifact $(basename "${newest_deb}")"

	built_version="$(basename "${newest_deb}" | \
		sed -n 's/^.*__\([0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)\?\)-.*$/\1/p')"
	if [[ -z "${built_version}" ]]; then
		log_error "Unable to derive the kernel version from $(basename "${newest_deb}") (missing __<version>- segment)."
		return 1
	fi
	printf '%s\n' "${built_version}"
}
