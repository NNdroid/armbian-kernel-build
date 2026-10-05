#!/usr/bin/env bash
# Build-wrapper library; loaded only from the synchronized Armbian tree.
export_loadable_module_assets() {
	local final_config="$1"
	local extracted_package_root="$2"
	local staging="$3"
	local branch="$4"
	local kernel_release="$5"
	local debian_arch="$6"
	local module_guide="${staging}/${branch}-loadable-modules.md"
	local module_sums="${staging}/${branch}-loadable-modules-SHA256SUMS"
	local component_spec
	local module
	local config_symbol
	local _expected_mode
	local actual_mode
	local i
	local display_name
	local module_path
	local module_basename
	local module_suffix
	local asset_basename
	local asset_path
	local asset_sha256
	local -a matched_modules=()
	local -a exported_names=()
	local -a exported_modules=()
	local -a exported_canonical_names=()
	local -a exported_display_names=()
	local -a exported_config_symbols=()
	local -a exported_sha256=()

	exported_module_count=0
	exported_module_guide=""
	[[ -d "${extracted_package_root}" ]] || {
		echo "[kernel-inject][error] extracted linux-image root is missing: ${extracted_package_root}" >&2
		return 1
	}

	for component_spec in "${component_specs[@]}"; do
		IFS=: read -r module config_symbol _expected_mode <<< "${component_spec}"
		actual_mode="$(config_value "${final_config}" "${config_symbol}")"
		[[ "${actual_mode}" == m ]] || continue

		matched_modules=()
		mapfile -d '' -t matched_modules < <(
			find "${extracted_package_root}" -type f \
				\( -name "${module}.ko" -o -name "${module}.ko.gz" \
					-o -name "${module}.ko.xz" -o -name "${module}.ko.zst" \) \
				-print0 2>/dev/null
		)
		if ((${#matched_modules[@]} != 1)); then
			_kernel_inject_log err "Module attachment export" \
				"CONFIG_${config_symbol}=m, but ${#matched_modules[@]} copies of ${module}.ko* were found in the kernel package (exactly one is required)"
			return 1
		fi

		case "${module}" in
			brutal) display_name="TCP-Brutal v2" ;;
			amneziawg) display_name="AmneziaWG" ;;
			nf_deaf) display_name="nf_deaf" ;;
			wireguard) display_name="Native WireGuard" ;;
			bluetooth) display_name="Bluetooth core" ;;
			bluetooth_6lowpan) display_name="Bluetooth 6LoWPAN" ;;
			rfkill) display_name="RFKill" ;;
			cfg80211) display_name="cfg80211" ;;
			mac80211) display_name="mac80211" ;;
			mt76) display_name="MediaTek mt76 core" ;;
			mt76-connac-lib) display_name="MediaTek Connac library" ;;
			mt792x-lib) display_name="MediaTek MT792x library" ;;
			mt7921-common) display_name="MediaTek MT7921 common" ;;
			mt7921e) display_name="MediaTek MT7921E PCIe" ;;
			*) display_name="${module}" ;;
		esac
		module_path="${matched_modules[0]}"
		module_basename="$(basename "${module_path}")"
		module_suffix="${module_basename#${module}}"
		asset_basename="${branch}-${kernel_release}-${debian_arch}-${module}${module_suffix}"
		asset_path="${staging}/${asset_basename}"
		cp -- "${module_path}" "${asset_path}"
		asset_sha256="$(sha256sum "${asset_path}" | awk '{print $1}')"
		printf '%s  %s\n' "${asset_sha256}" "${asset_basename}" >> "${module_sums}"

		exported_names+=("${asset_basename}")
		exported_modules+=("${module}")
		exported_canonical_names+=("${module_basename}")
		exported_display_names+=("${display_name}")
		exported_config_symbols+=("${config_symbol}")
		exported_sha256+=("${asset_sha256}")
		((exported_module_count += 1))
		_kernel_inject_log info "Module attachment export" \
			"${display_name}: ${module_basename} -> ${asset_basename}"
	done

	if ((exported_module_count == 0)); then
		rm -f -- "${module_sums}"
		_kernel_inject_log info "Module attachment export" "The final config has no managed =m components; no standalone .ko attachments are required"
		return 0
	fi

	{
		printf '## Loadable module attachments\n\n'
		printf 'The following components are configured as `m`. The release also uploads the original `.ko` files from the kernel package'
		printf ' (possibly compressed with `.gz`, `.xz`, or `.zst`) and checksum file `%s`.\n\n' \
			"$(basename "${module_sums}")"
		printf '> Modules are strictly tied to the kernel ABI: use them only when `uname -r` is exactly `%s` and the Debian architecture is `%s`. Do not mix kernel releases, architectures, or configurations.\n\n' \
			"${kernel_release}" "${debian_arch}"
		printf '| Component | Kconfig | Release attachment | Canonical installed filename | SHA256 |\n'
		printf '|---|---|---|---|---|\n'
		for ((i = 0; i < exported_module_count; i++)); do
			printf '| %s | `CONFIG_%s=m` | `%s` | `%s` | `%s` |\n' \
				"${exported_display_names[i]}" "${exported_config_symbols[i]}" \
				"${exported_names[i]}" "${exported_canonical_names[i]}" \
				"${exported_sha256[i]}"
		done
		printf '\n### Recommended: install the complete kernel package\n\n'
		printf 'The matching `linux-image-*.deb` already contains these modules and the complete module index. After installing it and rebooting into the target kernel, run:\n\n'
		printf '```bash\n'
		for module in "${exported_modules[@]}"; do
			printf 'sudo modprobe %q\n' "${module}"
		done
		printf '```\n\n'
		printf '### Install standalone module attachments only\n\n'
		printf 'Download the attachments listed above into the current directory, then run the commands below (filenames must be restored to their canonical module names):\n\n'
		printf '```bash\n'
		printf 'KERNEL_RELEASE=%q\n' "${kernel_release}"
		printf 'DEBIAN_ARCH=%q\n' "${debian_arch}"
		printf 'sha256sum -c %q\n' "$(basename "${module_sums}")"
		printf 'test "$(uname -r)" = "${KERNEL_RELEASE}"\n'
		printf 'test "$(dpkg --print-architecture)" = "${DEBIAN_ARCH}"\n'
		printf 'sudo install -d -m 0755 "/lib/modules/${KERNEL_RELEASE}/extra"\n'
		for ((i = 0; i < exported_module_count; i++)); do
			printf 'sudo install -m 0644 %q "/lib/modules/${KERNEL_RELEASE}/extra/%s"\n' \
				"./${exported_names[i]}" "${exported_canonical_names[i]}"
		done
		printf 'sudo depmod -a "${KERNEL_RELEASE}"\n'
		for module in "${exported_modules[@]}"; do
			printf 'sudo modprobe %q\n' "${module}"
		done
		printf '```\n\n'
		printf 'Verify with `modinfo <module>` and `lsmod`. With Secure Boot enabled, standalone modules must also be signed by a trusted key. `invalid module format` usually means a kernel release, architecture, vermagic, or signature mismatch; install the matching complete `.deb` instead.\n'
		printf '\n> MT7921E also requires MediaTek firmware matching the hardware and driver (normally provided by the distribution `linux-firmware` package); the `.ko` attachment does not include firmware.\n'
	} > "${module_guide}"
	exported_module_guide="${module_guide}"
}
