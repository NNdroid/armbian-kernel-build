#!/usr/bin/env bash
# Build-wrapper library; loaded only from the synchronized Armbian tree.
cleanup_wrapper() {
	[[ -z "${artifact_marker:-}" ]] || rm -f -- "${artifact_marker}"
	[[ -z "${module_manifest:-}" ]] || rm -f -- "${module_manifest}"
	[[ -z "${builtin_manifest:-}" ]] || rm -f -- "${builtin_manifest}"
	[[ -z "${package_extract_root:-}" ]] || rm -rf -- "${package_extract_root}"
	if declare -F _kernel_inject_cleanup_symbol_cache >/dev/null 2>&1; then
		_kernel_inject_cleanup_symbol_cache
	fi
}
trap cleanup_wrapper EXIT

argument_value() {
	local wanted="$1"
	local argument
	shift

	for argument in "$@"; do
		case "${argument}" in
			"${wanted}"=*) printf '%s\n' "${argument#*=}"; return 0 ;;
		esac
	done
	return 1
}

merge_extension_lists() {
	local merged=""
	local extension_list
	local extension
	local -a extensions=()

	for extension_list in "$@"; do
		extensions=()
		read -r -a extensions <<< "${extension_list//,/ }"
		for extension in "${extensions[@]}"; do
			[[ -n "${extension}" ]] || continue
			case ",${merged}," in
				*,"${extension}",*) ;;
				*) merged="${merged:+${merged},}${extension}" ;;
			esac
		done
	done
	printf '%s\n' "${merged}"
}

config_value() {
	local config_file="$1"
	local symbol="$2"
	local value

	value="$(sed -n "s/^CONFIG_${symbol}=//p" "${config_file}")"
	if [[ -n "${value}" ]]; then
		printf '%s\n' "${value}"
	else
		printf 'n\n'
	fi
}

manifest_value() {
	local manifest_file="$1"
	local wanted_key="$2"

	awk -F= -v wanted_key="${wanted_key}" '
		$1 == wanted_key {
			sub(/^[^=]*=/, "")
			print
			found = 1
			exit
		}
		END { if (!found) exit 1 }
	' "${manifest_file}"
}

require_manifest_value() {
	local manifest_file="$1"
	local wanted_key="$2"
	local value

	value="$(manifest_value "${manifest_file}" "${wanted_key}" 2>/dev/null || true)"
	if [[ -z "${value}" ]]; then
		_kernel_inject_log err "Corrupt build evidence" \
			"$(basename "${manifest_file}") is missing ${wanted_key}"
		return 1
	fi
	printf '%s\n' "${value}"
}
