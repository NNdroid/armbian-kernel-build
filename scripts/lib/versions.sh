#!/usr/bin/env bash
# Sourced library: definitions only; no build or external side effects.
function get_kernel_version() {
    local target_branch="$1"
    local file_path="$2"

    awk -v branch="$target_branch" '
        $0 ~ "^[ \t]*" branch "\\)" { in_block = 1; next }
        in_block && /KERNEL_MAJOR_MINOR[ \t]*=/ {
            split($0, arr, "\"")
            print arr[2]
            exit
        }
        in_block && /;;/ { in_block = 0 }
    ' "$file_path"
}

get_latest_github_tag() {
    local repo_url="$1"
    local prefix="$2"

    if [[ -z "$repo_url" || -z "$prefix" ]]; then
        return 1
    fi

    local escaped_prefix="${prefix//./\\.}"
    local latest_tag
	latest_tag=$(git ls-remote --tags "$repo_url" 2>/dev/null | \
        sed 's|.*refs/tags/||' | \
        sed 's/\^{}//' | \
        grep -E "^${escaped_prefix}(\.|$)" | \
        sort -Vu | \
		tail -n 1) || return 1

    if [[ -z "$latest_tag" ]]; then
        return 1
    fi
    echo "$latest_tag"
}

needs_update() {
	local released="$1"
	local upstream="$2"

	if [[ -z "${upstream}" ]]; then
		return 1
	fi
	if [[ -z "${released}" ]]; then
		return 0
	fi
	if [[ "${released}" == "${upstream}" ]]; then
		return 1
	fi
	[[ "$(printf '%s\n%s\n' "${released}" "${upstream}" | sort -V | tail -n 1)" == "${upstream}" ]]
}

get_kernel_org_latest() {
    local prefix="$1"
    local major_ver
    local index_html
    local latest_version

	[[ "${prefix}" =~ ^[0-9]+\.[0-9]+$ ]] || return 2
    major_ver="${prefix%%.*}"
    local target_url="https://cdn.kernel.org/pub/linux/kernel/v${major_ver}.x/"

	index_html="$(curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 \
		"${target_url}")" || return 1
	latest_version="$(printf '%s\n' "${index_html}" | parse_kernel_org_index "${prefix}" || true)"

	[[ -n "${latest_version}" ]] || return 2
    echo "$latest_version"
}

parse_kernel_org_index() {
	local prefix="$1"
	local escaped_prefix="${prefix//./\\.}"

	grep -oE "linux-${escaped_prefix}(\.[0-9]+)?\.tar\.xz" | \
		sed 's/linux-//;s/\.tar\.xz//' | \
		sort -Vu | \
		tail -n 1
}

load_kernel_org_version() {
	local branch="$1"
	local configured_version="$2"
	local latest_version
	local status

	if latest_version="$(get_kernel_org_latest "${configured_version}")"; then
		printf '%s\n' "${latest_version}"
		return 0
	else
		status=$?
	fi

	if ((status == 2)); then
		log_warn "kernel.org has not published ${configured_version}.x yet; skipping branch ${branch}."
		return 0
	fi

	log_error "Failed to query kernel.org for ${configured_version}.x; this is not an unpublished-version condition."
	return 1
}

# ==============================================================================
