#!/usr/bin/env bash
# Sourced library: definitions only; no build or external side effects.
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
	if declare -F target_extra_release_assets >/dev/null; then
		local -a bundle_files=()
		local extra_assets
		extra_assets="$(target_extra_release_assets "${kernel_version}")" || return 1
		[[ -z "${extra_assets}" ]] || mapfile -t bundle_files <<< "${extra_assets}"
		upload_files+=("${bundle_files[@]}")
	fi
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
