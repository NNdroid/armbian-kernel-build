#!/bin/bash
# shellcheck disable=SC2016

# ==============================================================================
# ==============================================================================

# ==========================================
# ==========================================
set -Eeuo pipefail # Abort on command errors, unset variables, or pipeline failures

# ==========================================
# ==========================================
log_now() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

log_info()  { printf '\e[32m[INFO]\e[0m \e[2m%s\e[0m %s\n' "$(log_now)" "$1"; }
log_debug() { printf '\e[34m[DEBUG]\e[0m \e[2m%s\e[0m %s\n' "$(log_now)" "$1" >&2; }
log_warn()  { printf '\e[33m[WARN]\e[0m \e[2m%s\e[0m %s\n' "$(log_now)" "$1" >&2; }
log_error() { printf '\e[31m[ERROR]\e[0m \e[2m%s\e[0m %s\n' "$(log_now)" "$1" >&2; }

STEP_START=0
begin_step() {
	STEP_START=$SECONDS
	log_info "──── $1 ────"
}
end_step() {
	log_info "──── $1 completed (elapsed $((SECONDS - STEP_START))s) ────"
}

report_unhandled_error() {
	local exit_code="$1"
	local line_number="$2"
	local failed_command="$3"

	trap - ERR
	log_error "Command failed: exit=${exit_code}, line=${line_number}, command=${failed_command}"
	log_error "Working directory at failure: ${PWD}"
	exit "${exit_code}"
}

resolve_repository_url() {
	local repository_root="${1:-${PWD}}"
	local repository_url

	if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
		printf '%s/%s.git\n' "${GITHUB_SERVER_URL%/}" "${GITHUB_REPOSITORY}"
		return 0
	fi

	repository_url="$(git -c safe.directory="${repository_root}" -C "${repository_root}" \
		remote get-url origin 2>/dev/null || true)"
	[[ -n "${repository_url}" ]] || return 1
	printf '%s\n' "${repository_url}"
}

# ==============================================================================
# ==============================================================================
ensure_host_dependencies() {
	local required=(git curl jq gh)
	local -a missing=()
	local tool

	for tool in "${required[@]}"; do
		if ! command -v "${tool}" > /dev/null 2>&1; then
			missing+=("${tool}")
		fi
	done

	if ((${#missing[@]} == 0)); then
		log_debug "Host dependencies are ready: ${required[*]}"
		return 0
	fi

	log_info "Installing missing host dependencies: ${missing[*]}"
	if sudo apt-get update -qq && sudo apt-get install -y -qq "${missing[@]}"; then
		log_info "Host dependency installation completed"
	else
		log_warn "apt installation failed (${missing[*]})"
	fi

	missing=()
	for tool in "${required[@]}"; do
		command -v "${tool}" > /dev/null 2>&1 || missing+=("${tool}")
	done
	if ((${#missing[@]} > 0)); then
		log_error "Missing required host tools: ${missing[*]}"
		return 1
	fi
}

# ==============================================================================
# ==============================================================================
function sync_tree() {
    if [ "$#" -ne 2 ]; then
        log_error "Usage: ${FUNCNAME[0]} <source-directory> <destination-directory>"
        return 1
    fi

    local SRC_DIR="${1%/}"
    local DEST_DIR="${2%/}"

    if [ ! -d "$SRC_DIR" ]; then
        log_error "Source directory '$SRC_DIR' does not exist."
        return 1
    fi

    local DEST_ABS
    case "$DEST_DIR" in
        /*) DEST_ABS="$DEST_DIR" ;;
        *)  DEST_ABS="$PWD/$DEST_DIR" ;;
    esac

    log_debug "Starting exact mapped sync: [$SRC_DIR] => [$DEST_ABS]"

    local copied_count=0
    if (
        cd "$SRC_DIR" || exit 1
		while IFS= read -r -d '' ITEM; do

            local REL_PATH="${ITEM#./}"
            local TARGET_ITEM="$DEST_ABS/$REL_PATH"

            if [ -d "$ITEM" ]; then
                if [ ! -d "$TARGET_ITEM" ]; then
                    mkdir -p "$TARGET_ITEM"
                    log_debug "  [create directory] $TARGET_ITEM"
                fi
            elif [ -f "$ITEM" ]; then
                local TARGET_DIR="${TARGET_ITEM%/*}"
                mkdir -p "$TARGET_DIR"
                cp -af "$ITEM" "$TARGET_ITEM"
                log_debug "  [overwrite file] $TARGET_ITEM"
            fi
		done < <(find . -mindepth 1 -print0)
    ); then
        copied_count="$(find "$SRC_DIR" -type f | wc -l | tr -d ' ')"
        log_info "Directory sync completed: $SRC_DIR (${copied_count} files)"
        return 0
    else
        log_error "An error occurred during directory synchronization."
        return 1
    fi
}

# ==============================================================================
# ==============================================================================
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

# ==============================================================================
# ==============================================================================
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

# ==============================================================================
# ==============================================================================
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

# ==============================================================================
# ==============================================================================
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
# ==============================================================================
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
		-name "linux-image-${branch}-rockchip64_*.deb" "${freshness_filter[@]}" \
		-printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)"
	if [[ -z "${newest_deb}" ]]; then
		log_error "No linux-image-${branch}-rockchip64_*.deb produced by this build was found."
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

# ==============================================================================
# ==============================================================================
function upload_to_github_release() {
    local tag_name="$1"
	local branch="$2"
	local kernel_version="$3"
	local upstream_version="$4"
	local files_pattern="$5"
	local metadata_dir="./build/output/release-metadata/${branch}"
	local notes_file="${metadata_dir}/release-notes.md"
	local summary_file="${metadata_dir}/build-summary.md"
	local file
	local file_name
	local file_size
	local file_sha256

    if ! command -v gh &> /dev/null; then
        log_error "GitHub CLI (gh) is not installed. Check the host dependencies."
        return 1
    fi

    log_info "Checking for files matching: ${files_pattern}"

    local -a upload_files=()
    mapfile -t upload_files < <(compgen -G "${files_pattern}" || true)
	local -a metadata_files=()
	mapfile -d '' -t metadata_files < <(find "${metadata_dir}" -maxdepth 1 -type f \
		\( -name '*.config' -o -name '*-config-vs-*-defconfig.txt' \
			-o -name '*-defconfig-build.log' -o -name '*-loadable-modules.md' \
			-o -name '*-source-manifest.env' -o -name '*-loadable-modules-SHA256SUMS' \
			-o -name '*.ko' \
			-o -name '*.ko.gz' -o -name '*.ko.xz' -o -name '*.ko.zst' \) \
		-print0 2>/dev/null)

    if [ ${#upload_files[@]} -eq 0 ]; then
        log_error "No build artifacts match ${files_pattern}; refusing to publish an empty release."
        return 1
    fi
	if [[ ! -s "${summary_file}" || ${#metadata_files[@]} -eq 0 ]]; then
		log_error "Missing build metadata for ${branch}; refusing to publish an incomplete release."
		return 1
	fi

	log_info "Preparing ${#upload_files[@]} kernel package(s) and ${#metadata_files[@]} metadata file(s) for upload:"
	for file in "${upload_files[@]}"; do
		log_debug "  artifact: $(basename "${file}") ($(du -h "${file}" | awk '{print $1}'))"
	done
	for file in "${metadata_files[@]}"; do
		log_debug "  attachment: $(basename "${file}")"
	done

	cp -- "${summary_file}" "${notes_file}"
	{
		printf '\n## Build artifacts\n\n'
		printf '| File | Size | SHA256 |\n|---|---:|---|\n'
		for file in "${upload_files[@]}"; do
			file_name="$(basename "${file}")"
			file_size="$(du -h "${file}" | awk '{print $1}')"
			file_sha256="$(sha256sum "${file}" | awk '{print $1}')"
			printf '| `%s` | %s | `%s` |\n' "${file_name}" "${file_size}" "${file_sha256}"
		done
		printf '\n## Build provenance\n\n'
		printf -- '- Release tag: `%s`\n' "${tag_name}"
		printf -- '- Kernel version (artifact): `%s`\n' "${kernel_version}"
		printf -- '- kernel.org upstream version: `%s`\n' "${upstream_version}"
		printf -- '- Repository commit: `%s`\n' \
			"${GITHUB_SHA:-$(git -c safe.directory="${PWD}" rev-parse HEAD)}"
		printf -- '- Build time: `%s`\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
	} >> "${notes_file}"

    log_info "Creating GitHub Release and uploading artifacts: ${tag_name} ..."

	if gh release create "${tag_name}" "${upload_files[@]}" "${metadata_files[@]}" \
        --title "Auto Build ${tag_name}" \
        --notes-file "${notes_file}"; then
        log_info "Successfully published and uploaded artifacts to: ${tag_name}"
	else
		if gh release view "${tag_name}" &> /dev/null; then
			log_warn "Release ${tag_name} already exists; updating notes and replacing same-name assets"
			gh release edit "${tag_name}" \
				--title "Auto Build ${tag_name}" --notes-file "${notes_file}" || return 1
			gh release upload "${tag_name}" "${upload_files[@]}" "${metadata_files[@]}" \
				--clobber || return 1
			log_info "Successfully updated existing Release: ${tag_name}"
		else
			log_error "Release upload failed. Check network access, permissions, and tag conflicts."
			return 1
		fi
	fi
	return 0
}

run_armbian_build() {
	local build_root="$1"
	shift

	(
		cd "${build_root}"
		./build_with_diy.sh "$@"
	)
}

# Allow regression tests to load the functions without installing packages,
# cloning Armbian or contacting GitHub.
if [[ "${BUILD_SCRIPT_LIB_ONLY:-no}" == yes ]]; then
	# exit is the direct-execution fallback.
	# shellcheck disable=SC2317
	return 0 2>/dev/null || exit 0
fi

SCRIPT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${SCRIPT_ROOT}"

trap 'report_unhandled_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

# ==============================================================================
# ==============================================================================

begin_step "1. Environment initialization"
ensure_host_dependencies

ROCKCHIP64_CONFIG_FILE="./rockchip64_common.inc"
ROCKCHIP64_CONFIG_TMP="$(mktemp "${ROCKCHIP64_CONFIG_FILE}.XXXXXX")"
log_debug "Downloading ${ROCKCHIP64_CONFIG_FILE}..."
if curl --fail --location --silent --show-error --retry 4 --retry-all-errors \
	--output "${ROCKCHIP64_CONFIG_TMP}" \
	https://raw.githubusercontent.com/armbian/build/refs/heads/main/config/sources/families/include/rockchip64_common.inc; then
	mv -- "${ROCKCHIP64_CONFIG_TMP}" "${ROCKCHIP64_CONFIG_FILE}"
else
	rm -f -- "${ROCKCHIP64_CONFIG_TMP}"
	log_error "Failed to download rockchip64_common.inc. Check network connectivity."
	exit 1
fi
if [[ ! -s "${ROCKCHIP64_CONFIG_FILE}" ]]; then
    log_error "Failed to download rockchip64_common.inc or the file is empty. Check network connectivity."
    exit 1
fi
log_info "rockchip64_common.inc downloaded ($(wc -l < "${ROCKCHIP64_CONFIG_FILE}" | tr -d ' ') lines)"
end_step "1. Environment initialization"

if ! CUR_GIT_REPO_URL="$(resolve_repository_url "${PWD}")"; then
	log_error "Unable to determine the current GitHub repository. Check GITHUB_REPOSITORY or the origin remote."
	exit 1
fi
log_info "Release repository: ${CUR_GIT_REPO_URL}"

# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
begin_step "2. Version comparison"
branch_list=(current edge bleedingedge)
declare -A BRANCH_UPSTREAM_VER=()
declare -A NEED_BUILD=()

for branch in "${branch_list[@]}"; do
	CONFIG_KERNEL_VER="$(get_kernel_version "${branch}" "${ROCKCHIP64_CONFIG_FILE}" || true)"
	if [[ -z "${CONFIG_KERNEL_VER}" ]]; then
		log_warn "${branch}: no KERNEL_MAJOR_MINOR entry exists for this branch in the Armbian config; skipping"
		continue
	fi
	log_info "${branch}: Armbian configured major version = ${CONFIG_KERNEL_VER}"

	KERNEL_ORG_VER="$(load_kernel_org_version "${branch}" "${CONFIG_KERNEL_VER}")" || exit 1
	if [[ -z "${KERNEL_ORG_VER}" ]]; then
		continue
	fi

	RELEASED_TAG="$(get_latest_github_tag "${CUR_GIT_REPO_URL}" "${branch}-${CONFIG_KERNEL_VER}" || true)"
	RELEASED_VER="${RELEASED_TAG#"${branch}-"}"

	if needs_update "${RELEASED_VER}" "${KERNEL_ORG_VER}"; then
		NEED_BUILD["${branch}"]=yes
		BRANCH_UPSTREAM_VER["${branch}"]="${KERNEL_ORG_VER}"
		if [[ -z "${RELEASED_TAG}" ]]; then
			log_info "${branch}: no release exists yet; upstream is ${KERNEL_ORG_VER} -> build planned"
		else
			log_info "${branch}: released ${RELEASED_TAG} < upstream ${KERNEL_ORG_VER} -> build planned"
		fi
	else
		log_info "${branch}: released ${RELEASED_TAG} >= upstream ${KERNEL_ORG_VER} -> no build needed"
	fi
done
end_step "2. Version comparison"

# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
planned_branches=()
for branch in "${branch_list[@]}"; do
	if [[ "${NEED_BUILD[${branch}]:-}" == yes ]]; then
		planned_branches+=("${branch}")
	fi
done

if ((${#planned_branches[@]} == 0)); then
    log_info "All branch kernel versions are current; no build is required. Exiting."
    exit 0
fi
log_info "Branches scheduled for build: ${planned_branches[*]}"

begin_step "3. Prepare Armbian build environment"
if [ -d "build" ]; then
    log_info "Updating existing build directory..."
	git -C build checkout .
	git -C build clean -fd
	git -C build pull --ff-only
    sync_tree ./overwrite ./build
    sync_tree ./userpatches ./build/userpatches
else
    log_info "Cloning build directory..."
    git clone https://github.com/armbian/build
    sync_tree ./overwrite ./build
    sync_tree ./userpatches ./build/userpatches
fi
end_step "3. Prepare Armbian build environment"

for branch in "${planned_branches[@]}"; do
	begin_step "4. Build ${branch} kernel (target ${BRANCH_UPSTREAM_VER[${branch}]})"
	BUILD_MARKER="$(mktemp "${TMPDIR:-/tmp}/kernel-build-${branch}.XXXXXX")"
	if ! run_armbian_build ./build kernel BOARD=nanopi-r5s BRANCH="${branch}" RELEASE=trixie; then
		rm -f -- "${BUILD_MARKER}"
		log_error "${branch}: Armbian kernel build failed"
		exit 1
	fi

	BUILT_KERNEL_VER="$(resolve_built_version "${branch}" "${BUILD_MARKER}")" || {
		rm -f -- "${BUILD_MARKER}"
		exit 1
	}
	rm -f -- "${BUILD_MARKER}"
	log_info "${branch}: derived kernel version from artifact = ${BUILT_KERNEL_VER}"
	end_step "4. Build ${branch} kernel"

	begin_step "5. Publish ${branch}-${BUILT_KERNEL_VER}"
	upload_to_github_release "${branch}-${BUILT_KERNEL_VER}" "${branch}" \
		"${BUILT_KERNEL_VER}" "${BRANCH_UPSTREAM_VER[${branch}]}" \
		"./build/output/debs/*-${branch}-rockchip64_*__${BUILT_KERNEL_VER}-*.deb"
	end_step "5. Publish ${branch}-${BUILT_KERNEL_VER}"
done

log_info "All automation steps completed successfully."
