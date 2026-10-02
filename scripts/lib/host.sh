#!/usr/bin/env bash
# Sourced library: definitions only; no build or external side effects.
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
