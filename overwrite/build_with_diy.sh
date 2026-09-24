#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

if [[ ! -x ./compile.sh ]]; then
	echo "[kernel-inject][error] compile.sh is missing or not executable" >&2
	exit 1
fi

if [[ ! -s userpatches/lib.config ]]; then
	echo "[kernel-inject][error] userpatches/lib.config is missing or empty" >&2
	exit 1
fi

: "${ENABLE_FULL_EBPF:=yes}"
: "${ENABLE_FULL_NETWORKING:=yes}"
: "${KERNEL_BTF:=yes}"
case "${ENABLE_FULL_EBPF}" in
	yes)
		if [[ "${KERNEL_BTF}" == no ]]; then
			echo "[kernel-inject][error] ENABLE_FULL_EBPF=yes conflicts with KERNEL_BTF=no" >&2
			exit 1
		fi
		;;
	no) ;;
	*)
		echo "[kernel-inject][error] ENABLE_FULL_EBPF must be yes or no" >&2
		exit 1
		;;
esac
case "${ENABLE_FULL_NETWORKING}" in
	yes|no) ;;
	*)
		echo "[kernel-inject][error] ENABLE_FULL_NETWORKING must be yes or no" >&2
		exit 1
		;;
esac
case "${KERNEL_BTF}" in
	yes|no) ;;
	*)
		echo "[kernel-inject][error] KERNEL_BTF must be yes or no" >&2
		exit 1
		;;
esac
export ENABLE_FULL_EBPF ENABLE_FULL_NETWORKING KERNEL_BTF

# Runtime path is the Armbian build root.
# shellcheck disable=SC1091
source userpatches/lib.config
for mode_name in TCP_BRUTAL_MODE AMNEZIAWG_MODE NF_DEAF_MODE WIREGUARD_MODE; do
	mode_value="${!mode_name}"
	case "${mode_value}" in
		y|m|n) ;;
		*)
			echo "[kernel-inject][error] ${mode_name} must be y, m or n" >&2
			exit 1
			;;
	esac
done
if [[ "${AMNEZIAWG_MODE}" == y && "${WIREGUARD_MODE}" == y ]]; then
	echo "[kernel-inject][error] AMNEZIAWG_MODE=y conflicts with WIREGUARD_MODE=y" >&2
	exit 1
fi
export TCP_BRUTAL_MODE AMNEZIAWG_MODE NF_DEAF_MODE WIREGUARD_MODE

_kernel_inject_skipped_symbols=()
artifact_marker=""
module_manifest=""
builtin_manifest=""
package_extract_root=""

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

generate_release_metadata() {
	local evidence_dir="$1"
	local branch="$2"
	local board="$3"
	local userspace_release="$4"
	local extracted_package_root="$5"
	local metadata_parent="output/release-metadata"
	local metadata_dir="${metadata_parent}/${branch}"
	local staging
	local manifest_file="${evidence_dir}/source-manifest.env"
	local final_config="${evidence_dir}/kernel.config"
	local config_asset
	local diff_asset
	local summary_file
	local kernel_release
	local config_sha256
	local expected_config_sha256
	local diff_count
	local baseline_status
	local kbuild_arch
	local debian_arch
	local linuxfamily
	local tcp_commit
	local awg_commit
	local nf_commit
	local armbian_build_commit
	local kernel_source_commit

	_kernel_inject_log info "Release metadata" "Generating: branch=${branch}, board=${board}, release=${userspace_release}"
	[[ "${branch}" =~ ^[A-Za-z0-9._-]+$ ]] || {
		echo "[kernel-inject][error] unsafe BRANCH value for release metadata: ${branch}" >&2
		return 1
	}
	[[ -f "${final_config}" ]] || {
		echo "[kernel-inject][error] final kernel config is missing: ${final_config}" >&2
		return 1
	}
	[[ -s "${manifest_file}" ]] || {
		echo "[kernel-inject][error] build evidence manifest is missing: ${manifest_file}" >&2
		return 1
	}

	kbuild_arch="$(require_manifest_value "${manifest_file}" kbuild_arch)" || return 1
	debian_arch="$(require_manifest_value "${manifest_file}" debian_arch)" || return 1
	linuxfamily="$(require_manifest_value "${manifest_file}" linuxfamily)" || return 1
	kernel_release="$(require_manifest_value "${manifest_file}" kernel_release)" || return 1
	baseline_status="$(require_manifest_value "${manifest_file}" baseline_status)" || return 1
	diff_count="$(require_manifest_value "${manifest_file}" diff_count)" || return 1
	tcp_commit="$(require_manifest_value "${manifest_file}" tcp_brutal_commit)" || return 1
	awg_commit="$(require_manifest_value "${manifest_file}" amneziawg_commit)" || return 1
	nf_commit="$(require_manifest_value "${manifest_file}" nf_deaf_commit)" || return 1
	armbian_build_commit="$(require_manifest_value "${manifest_file}" armbian_build_commit)" || return 1
	kernel_source_commit="$(require_manifest_value "${manifest_file}" kernel_source_commit)" || return 1
	expected_config_sha256="$(require_manifest_value "${manifest_file}" config_sha256)" || return 1
	if [[ ! "${kbuild_arch}" =~ ^[A-Za-z0-9._-]+$ || \
		! "${debian_arch}" =~ ^[A-Za-z0-9._-]+$ || \
		! "${kernel_release}" =~ ^[A-Za-z0-9._+-]+$ || \
		! "${diff_count}" =~ ^[0-9]+$ ]]; then
		echo "[kernel-inject][error] unsafe values in build evidence manifest" >&2
		return 1
	fi

	mkdir -p "${metadata_parent}"
	staging="$(mktemp -d "${metadata_parent}/.${branch}.XXXXXX")"
	config_asset="${staging}/${branch}-kernel.config"
	diff_asset="${staging}/${branch}-config-vs-${kbuild_arch}-defconfig.txt"
	summary_file="${staging}/build-summary.md"
	cp -- "${final_config}" "${config_asset}"
	cp -- "${manifest_file}" "${staging}/${branch}-source-manifest.env"
	config_sha256="$(sha256sum "${config_asset}" | awk '{print $1}')"
	if [[ "${config_sha256}" != "${expected_config_sha256}" ]]; then
		echo "[kernel-inject][error] final config checksum does not match packaged build evidence" >&2
		rm -rf -- "${staging}"
		return 1
	fi
	_kernel_inject_log debug "Release metadata" "Final config SHA256=${config_sha256}"
	_kernel_inject_log debug "Release metadata" "Kernel release=${kernel_release}"
	if [[ ! -f "${evidence_dir}/config-vs-${kbuild_arch}-defconfig.txt" || \
		! -f "${evidence_dir}/${kbuild_arch}-defconfig-build.log" ]]; then
		echo "[kernel-inject][error] packaged defconfig diagnostics are incomplete" >&2
		rm -rf -- "${staging}"
		return 1
	fi
	cp -- "${evidence_dir}/config-vs-${kbuild_arch}-defconfig.txt" "${diff_asset}"
	cp -- "${evidence_dir}/${kbuild_arch}-defconfig-build.log" \
		"${staging}/${kbuild_arch}-defconfig-build.log"
	_kernel_inject_log info "Release metadata" \
		"${kbuild_arch} defconfig comparison: ${baseline_status}, ${diff_count} config differences"

	_kernel_inject_log debug "Release metadata" \
		"Source commits: tcp-brutal=${tcp_commit:0:12}, amneziawg=${awg_commit:0:12}, nf_deaf=${nf_commit:0:12}"
	if [[ ! "${tcp_commit}" =~ ^[0-9a-f]{40}$ || \
		! "${awg_commit}" =~ ^[0-9a-f]{40}$ || \
		! "${nf_commit}" =~ ^[0-9a-f]{40}$ ]]; then
		echo "[kernel-inject][error] release metadata contains an invalid source commit" >&2
		rm -rf -- "${staging}"
		return 1
	fi

	export_loadable_module_assets "${final_config}" "${extracted_package_root}" \
		"${staging}" "${branch}" "${kernel_release}" "${debian_arch}" || {
		rm -rf -- "${staging}"
		return 1
	}

	{
		printf '# Kernel build details\n\n'
		printf '| Item | Final value |\n|---|---|\n'
		printf '| Kernel release | `%s` |\n' "${kernel_release}"
		printf '| Armbian branch | `%s` |\n' "${branch}"
		printf '| Board / family / Debian architecture / Kbuild architecture | `%s` / `%s` / `%s` / `%s` |\n' \
			"${board}" "${linuxfamily}" "${debian_arch}" "${kbuild_arch}"
		printf '| Userspace release | `%s` |\n' "${userspace_release}"
		printf '| Armbian/build baseline commit | `%s` |\n' "${armbian_build_commit}"
		printf '| Kernel source baseline commit | `%s` |\n' "${kernel_source_commit}"
		printf '| Final config SHA256 | `%s` |\n' "${config_sha256}"
		printf '| Full eBPF enforcement | `%s` |\n' "${ENABLE_FULL_EBPF}"
		printf '| Full networking enforcement | `%s` |\n' "${ENABLE_FULL_NETWORKING}"
		printf '\n## Differences from the standard kernel configuration\n\n'
		printf 'Attachment `%s` is the final effective configuration after `olddefconfig`.' "$(basename "${config_asset}")"
		if [[ "${baseline_status}" == generated ]]; then
			printf 'Compared with `%s defconfig` generated from the same Armbian-patched source tree, there are **%s configuration differences**.\n\n' \
				"${kbuild_arch}" "${diff_count}"
		else
			printf 'The `%s defconfig` baseline could not be generated for this build, but the final configuration is still attached.\n\n' "${kbuild_arch}"
		fi
		if ((${#_kernel_inject_skipped_symbols[@]} > 0)); then
			printf '> **%s legacy negative compatibility symbols are not defined by this kernel tree** and therefore do not require disabled-state checks: %s\n\n' \
				"${#_kernel_inject_skipped_symbols[@]}" "${_kernel_inject_skipped_symbols[*]}"
		fi
		printf '> This is a configuration-level comparison. Armbian board, device-tree, and other patches are additional source-level differences from kernel.org.\n\n'
		printf '## Additional networking components\n\n'
		printf '| Component | Build mode | Source commit |\n|---|---:|---|\n'
		printf '| TCP-Brutal v2 | `%s` | [`%s`](https://github.com/HyNetworks/tcp-brutal/commit/%s) |\n' \
			"$(config_value "${final_config}" TCP_CONG_BRUTAL)" "${tcp_commit:0:12}" "${tcp_commit}"
		printf '| AmneziaWG | `%s` | [`%s`](https://github.com/NNdroid/amneziawg-linux-kernel-module/commit/%s) |\n' \
			"$(config_value "${final_config}" AMNEZIAWG)" "${awg_commit:0:12}" "${awg_commit}"
		printf '| nf_deaf | `%s` | [`%s`](https://github.com/NNdroid/nf_deaf/commit/%s) |\n' \
			"$(config_value "${final_config}" NETFILTER_DEAF)" "${nf_commit:0:12}" "${nf_commit}"
		printf '| Native WireGuard (replaced by AmneziaWG by default) | `%s` | Linux kernel source tree |\n' \
			"$(config_value "${final_config}" WIREGUARD)"
		printf '\n'
		if ((exported_module_count > 0)); then
			cat "${exported_module_guide}"
		else
			printf '> None of the managed components above has final mode `m`, so this release does not produce standalone `.ko` attachments; `y` means the component is built directly into the kernel.\n'
		fi
		printf '\n## Full networking feature set\n\n'
		if [[ "${ENABLE_FULL_NETWORKING}" == yes ]]; then
			printf 'The final configuration was verified feature by feature: MPLS routing/tunneling, SRv6, VXLAN/Geneve/GRE/FOU, AmneziaWG, netfilter/nftables, BBR+FQ, NPTv6, Linux bridge, and USB Gadget are forced built-in; Bluetooth and the cfg80211/mac80211/MT7921E driver chain are forced as modules.\n\n'
			printf '| Capability | Key final configuration |\n|---|---|\n'
			printf '| MPLS / SRv6 | `MPLS_ROUTING=%s`, `IPV6_SEG6_LWTUNNEL=%s` |\n' \
				"$(config_value "${final_config}" MPLS_ROUTING)" \
				"$(config_value "${final_config}" IPV6_SEG6_LWTUNNEL)"
			printf '| Overlay / tunnel | `VXLAN=%s`, `GENEVE=%s`, `NET_IPGRE=%s`, `IPV6_GRE=%s`, `NET_FOU=%s` |\n' \
				"$(config_value "${final_config}" VXLAN)" \
				"$(config_value "${final_config}" GENEVE)" \
				"$(config_value "${final_config}" NET_IPGRE)" \
				"$(config_value "${final_config}" IPV6_GRE)" \
				"$(config_value "${final_config}" NET_FOU)"
			printf '| Netfilter | `NF_TABLES=%s`, `NFT_TPROXY=%s`, `NFT_SYNPROXY=%s`, `IP6_NF_TARGET_NPT=%s` |\n' \
				"$(config_value "${final_config}" NF_TABLES)" \
				"$(config_value "${final_config}" NFT_TPROXY)" \
				"$(config_value "${final_config}" NFT_SYNPROXY)" \
				"$(config_value "${final_config}" IP6_NF_TARGET_NPT)"
			printf '| BBR / bridge / BNEP | `TCP_CONG_BBR=%s`, `BRIDGE=%s`, `BT_BNEP=%s` |\n' \
				"$(config_value "${final_config}" TCP_CONG_BBR)" \
				"$(config_value "${final_config}" BRIDGE)" \
				"$(config_value "${final_config}" BT_BNEP)"
			printf '| Bluetooth / Wi-Fi modules | `BT=%s`, `CFG80211=%s`, `MAC80211=%s`, `MT76_CORE=%s`, `MT7921E=%s` |\n' \
				"$(config_value "${final_config}" BT)" \
				"$(config_value "${final_config}" CFG80211)" \
				"$(config_value "${final_config}" MAC80211)" \
				"$(config_value "${final_config}" MT76_CORE)" \
				"$(config_value "${final_config}" MT7921E)"
			printf '| USB Gadget | `USB_GADGET=%s`, `USB_CONFIGFS=%s`, `USB_FUNCTIONFS=%s` |\n' \
				"$(config_value "${final_config}" USB_GADGET)" \
				"$(config_value "${final_config}" USB_CONFIGFS)" \
				"$(config_value "${final_config}" USB_FUNCTIONFS)"
		else
			printf 'Full networking enforcement is disabled for this build; inspect the attached final configuration.\n'
		fi
		printf '\n## eBPF / BTF / CO-RE\n\n'
		if [[ "${ENABLE_FULL_EBPF}" == yes ]]; then
			printf 'The final configuration passed checks for BPF syscall/JIT, kernel and module BTF, CO-RE, cgroup/LSM, XDP/AF_XDP, tc, netfilter, kprobe/uprobe, and ftrace. Unprivileged BPF is disabled by default.\n'
		else
			printf 'Full eBPF enforcement is disabled for this build; inspect the attached final configuration before using BTF/CO-RE or tracing features.\n'
		fi
		printf '\nSee attachment `%s` for the complete configuration diff.\n' "$(basename "${diff_asset}")"
	} > "${summary_file}"

	rm -rf -- "${metadata_dir}"
	mv -- "${staging}" "${metadata_dir}"
	_kernel_inject_log info "Release metadata" "Wrote ${metadata_dir}: $(find "${metadata_dir}" -maxdepth 1 -type f -printf '%f ' 2>/dev/null)"
}

# Remove the obsolete v1 patch if it remains in a reused/ignored userpatches
# directory. TCP-Brutal v2 owns its socket-option routing.
rm -f -- userpatches/90_patch_brutal.sh

requested_branch="$(argument_value BRANCH "$@" || true)"
requested_board="$(argument_value BOARD "$@" || true)"
userspace_release="$(argument_value RELEASE "$@" || true)"
requested_extensions="$(argument_value ENABLE_EXTENSIONS "$@" || true)"
requested_legacy_extensions="$(argument_value EXT "$@" || true)"
configured_extensions="${requested_extensions:-${requested_legacy_extensions:-${ENABLE_EXTENSIONS:-${EXT:-}}}}"

# Armbian initializes the extension manager before it sources lib.config. The
# package-evidence hook therefore lives in userpatches/extensions and must be
# enabled before compile.sh starts. Merge rather than replace caller-provided
# extensions, then remove duplicate CLI assignments so the final value cannot
# be overridden later in argument order.
ENABLE_EXTENSIONS="$(merge_extension_lists \
	"${configured_extensions}" \
	"kernel-inject-evidence")"
export ENABLE_EXTENSIONS
compile_arguments=()
for argument in "$@"; do
	case "${argument}" in
		ENABLE_EXTENSIONS=* | EXT=*) ;;
		*) compile_arguments+=("${argument}") ;;
	esac
done
set -- "${compile_arguments[@]}" "ENABLE_EXTENSIONS=${ENABLE_EXTENSIONS}"

_kernel_inject_log info "Build wrapper" \
	"Arguments: target=kernel BRANCH=${requested_branch:-<unset>} BOARD=${requested_board:-<unset>} RELEASE=${userspace_release:-<unset>}"
_kernel_inject_log info "Build wrapper" \
	"Full eBPF: ${ENABLE_FULL_EBPF}, full networking: ${ENABLE_FULL_NETWORKING}, KERNEL_BTF: ${KERNEL_BTF}"
_kernel_inject_log info "Build wrapper" \
	"Armbian extensions: ${ENABLE_EXTENSIONS} (kernel-inject-evidence is ensured enabled)"

mkdir -p output/debs
artifact_marker="$(mktemp "${TMPDIR:-/tmp}/kernel-build-start.XXXXXX")"
_kernel_inject_log info "Build wrapper" "Starting Armbian: ./compile.sh $*"
./compile.sh "$@"
_kernel_inject_log info "Build wrapper" "compile.sh returned successfully; validating artifacts from this build"

# Armbian does not ship a separate linux-modules package: the .ko files live
# inside linux-image-<branch>-<family>. Start from the artifact this build
# actually produced: only kernel image packages newer than the marker created
# immediately before compile.sh are eligible. This prevents a stale package
# from a previous run from satisfying post-build validation.
image_deb_list="$(find output/debs -type f -name 'linux-image-*.deb' \
	-newer "${artifact_marker}" -printf '%T@ %p\n' 2>/dev/null | sort -rn || true)"
if [[ -z "${image_deb_list}" ]]; then
	_kernel_inject_log err "Artifact discovery failed" "compile.sh did not produce a new linux-image-*.deb in output/debs"
	exit 1
fi
_kernel_inject_log debug "Artifact discovery" "Kernel packages in output/debs (newest first):"
while IFS= read -r entry; do
	_kernel_inject_log debug "Artifact discovery" "  ${entry#* }"
done <<< "${image_deb_list}"

image_deb_entry=""
if [[ -n "${requested_branch}" ]]; then
	if [[ ! "${requested_branch}" =~ ^[A-Za-z0-9._-]+$ ]]; then
		_kernel_inject_log err "Unsafe BRANCH value" "${requested_branch}"
		exit 1
	fi
	while IFS= read -r entry; do
		candidate_path="${entry#* }"
		case "$(basename "${candidate_path}")" in
			"linux-image-${requested_branch}-rockchip64_"*)
				image_deb_entry="${entry}"
				break
				;;
		esac
	done <<< "${image_deb_list}"
	if [[ -z "${image_deb_entry}" ]]; then
		_kernel_inject_log err "Artifact discovery failed" "No linux-image deb for BRANCH=${requested_branch} exists under output/debs"
		exit 1
	fi
else
	image_deb_entry="${image_deb_list%%$'\n'*}"
fi
image_deb_mtime="${image_deb_entry%% *}"
image_deb="${image_deb_entry#* }"
if [[ -z "${requested_branch}" ]]; then
	_kernel_inject_log warn "Artifact discovery" "BRANCH was not provided; selecting the newest by modification time: $(basename "${image_deb}")"
fi
_kernel_inject_log info "Artifact discovery" \
	"Selected $(basename "${image_deb}") ($(du -h "${image_deb}" | awk '{print $1}'), mtime $(date -u -d "@${image_deb_mtime}" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown))"

built_branch="$(basename "${image_deb}" | sed -n 's/^linux-image-\([A-Za-z0-9._-]*\)-rockchip64_.*/\1/p')"
if [[ -z "${built_branch}" ]]; then
	_kernel_inject_log err "Unexpected artifact name" "Unable to derive branch name from $(basename "${image_deb}")"
	exit 1
fi
if [[ -n "${requested_branch}" && "${built_branch}" != "${requested_branch}" ]]; then
	_kernel_inject_log err "Artifact branch mismatch" \
		"Newest deb belongs to branch ${built_branch}, but this build requested BRANCH=${requested_branch}"
	_kernel_inject_log err "Artifact branch mismatch" "Usually this means artifacts from a previous build were not cleaned or this build produced no new package"
	exit 1
fi
_kernel_inject_log debug "Artifact discovery" "deb branch: ${built_branch}"

kernel_major_minor="$(basename "${image_deb}" | \
	sed -n 's/^.*__\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
if [[ -z "${kernel_major_minor}" ]]; then
	_kernel_inject_log err "Unexpected artifact name" "cannot derive kernel version from $(basename "${image_deb}")"
	exit 1
fi
_kernel_inject_log info "Artifact discovery" "Built kernel major version: ${kernel_major_minor}"

# Validate loadable-module files before extraction. Built-in components are
# verified later against both the packaged final config and modules.builtin.
# The package is the durable build result; Docker may discard its source tree
# before this wrapper regains control.
if ! command -v dpkg-deb >/dev/null 2>&1; then
	_kernel_inject_log err "Artifact validation failed" "dpkg-deb is required to verify $(basename "${image_deb}")"
	exit 1
fi
module_manifest="$(mktemp "${TMPDIR:-/tmp}/kernel-image-modules.XXXXXX")"
if ! dpkg-deb -c "${image_deb}" > "${module_manifest}" 2>/dev/null; then
	_kernel_inject_log err "Module artifact validation" "Unable to read the file list from $(basename "${image_deb}")"
	exit 1
fi
component_specs=(
	"brutal:TCP_CONG_BRUTAL:${TCP_BRUTAL_MODE}"
	"amneziawg:AMNEZIAWG:${AMNEZIAWG_MODE}"
	"nf_deaf:NETFILTER_DEAF:${NF_DEAF_MODE}"
	"wireguard:WIREGUARD:${WIREGUARD_MODE}"
)
if [[ "${ENABLE_FULL_NETWORKING}" == yes ]]; then
	component_specs+=(
		"6lowpan:6LOWPAN:m"
		"bluetooth:BT:m"
		"rfcomm:BT_RFCOMM:m"
		"bnep:BT_BNEP:m"
		"hidp:BT_HIDP:m"
		"bluetooth_6lowpan:BT_6LOWPAN:m"
		"rfkill:RFKILL:m"
		"cfg80211:CFG80211:m"
		"mac80211:MAC80211:m"
		"mt76:MT76_CORE:m"
		"mt76-connac-lib:MT76_CONNAC_LIB:m"
		"mt792x-lib:MT792x_LIB:m"
		"mt7921-common:MT7921_COMMON:m"
		"mt7921e:MT7921E:m"
	)
fi
for component_spec in "${component_specs[@]}"; do
	IFS=: read -r module config_symbol expected_mode <<< "${component_spec}"
	module_present=no
	if grep -Eq "/${module}\.ko(\.(gz|xz|zst))?$" "${module_manifest}"; then
		module_present=yes
	fi
	case "${expected_mode}" in
		m)
			if [[ "${module_present}" != yes ]]; then
				_kernel_inject_log err "Module artifact validation" \
					"${module}: requested =m but .ko is missing from $(basename "${image_deb}")"
				exit 1
			fi
			_kernel_inject_log debug "Module artifact validation" "${module}=m: .ko exists"
			;;
		y|n)
			if [[ "${module_present}" == yes ]]; then
				_kernel_inject_log err "Module artifact validation" \
					"${module}: requested =${expected_mode} but package unexpectedly contains a loadable .ko"
				exit 1
			fi
			;;
	esac
done

package_extract_root="$(mktemp -d "${TMPDIR:-/tmp}/kernel-image-evidence.XXXXXX")"
if ! dpkg-deb -x "${image_deb}" "${package_extract_root}"; then
	_kernel_inject_log err "Missing build evidence" "Unable to unpack $(basename "${image_deb}")"
	exit 1
fi
mapfile -d '' -t evidence_manifests < <(
	find "${package_extract_root}/usr/lib/armbian-kernel-build" -type f \
		-name source-manifest.env -print0 2>/dev/null
)
if ((${#evidence_manifests[@]} != 1)); then
	_kernel_inject_log err "Missing build evidence" \
		"$(basename "${image_deb}") must contain exactly one source-manifest.env; found ${#evidence_manifests[@]}"
	_kernel_inject_log err "Missing build evidence" \
		"kernel-inject-evidence did not participate in this package; check Extension Manager logs and the HK hash in the package version"
	exit 1
fi
evidence_manifest="${evidence_manifests[0]}"
evidence_dir="$(dirname "${evidence_manifest}")"
final_config="${evidence_dir}/kernel.config"
defined_symbols="${evidence_dir}/defined-symbols.txt"
if [[ ! -s "${final_config}" || ! -s "${defined_symbols}" ]]; then
	_kernel_inject_log err "Corrupt build evidence" "Final configuration or Kconfig symbol inventory is missing"
	exit 1
fi

builtin_manifest="$(mktemp "${TMPDIR:-/tmp}/kernel-image-builtins.XXXXXX")"
find "${package_extract_root}" -type f -name modules.builtin -exec cat {} + \
	> "${builtin_manifest}" 2>/dev/null || true
for component_spec in "${component_specs[@]}"; do
	IFS=: read -r module config_symbol expected_mode <<< "${component_spec}"
	actual_mode="$(config_value "${final_config}" "${config_symbol}")"
	if [[ "${actual_mode}" != "${expected_mode}" ]]; then
		_kernel_inject_log err "Build mode validation" \
			"CONFIG_${config_symbol}: requested ${expected_mode}, packaged config has ${actual_mode}"
		exit 1
	fi
	if [[ "${expected_mode}" == y ]]; then
		if ! grep -Eq "/${module}\.ko$" "${builtin_manifest}"; then
			_kernel_inject_log err "Built-in artifact validation" \
				"${module}: CONFIG_${config_symbol}=y but modules.builtin has no matching entry"
			exit 1
		fi
		_kernel_inject_log debug "Built-in artifact validation" "${module}=y: confirmed in modules.builtin"
	fi
done
_kernel_inject_log info "Build mode validation" \
	"brutal=${TCP_BRUTAL_MODE}, amneziawg=${AMNEZIAWG_MODE}, nf_deaf=${NF_DEAF_MODE}, native-wireguard=${WIREGUARD_MODE} all match the kernel package"
if [[ "${ENABLE_FULL_NETWORKING}" == yes ]]; then
	_kernel_inject_log info "Build mode validation" \
		"Bluetooth core/BNEP and the cfg80211/mac80211/MT7921E dependency chains are modules and their .ko files exist"
fi

manifest_format="$(require_manifest_value "${evidence_manifest}" evidence_format)" || exit 1
manifest_branch="$(require_manifest_value "${evidence_manifest}" branch)" || exit 1
manifest_family="$(require_manifest_value "${evidence_manifest}" linuxfamily)" || exit 1
manifest_arch="$(require_manifest_value "${evidence_manifest}" debian_arch)" || exit 1
manifest_kernel_major_minor="$(require_manifest_value "${evidence_manifest}" kernel_major_minor)" || exit 1
package_arch="$(dpkg-deb -f "${image_deb}" Architecture 2>/dev/null || true)"
if [[ "${manifest_format}" != 1 || "${manifest_branch}" != "${built_branch}" || \
	"${manifest_family}" != rockchip64 || "${manifest_arch}" != "${package_arch}" || \
	"${manifest_kernel_major_minor}" != "${kernel_major_minor}" ]]; then
	_kernel_inject_log err "Build evidence mismatch" \
		"manifest(format=${manifest_format}, branch=${manifest_branch}, family=${manifest_family}, arch=${manifest_arch}, kernel=${manifest_kernel_major_minor})"
	_kernel_inject_log err "Build evidence mismatch" \
		"artifact(branch=${built_branch}, family=rockchip64, arch=${package_arch:-unknown}, kernel=${kernel_major_minor})"
	exit 1
fi

for pin_entry in \
	"tcp_brutal_commit:${TCP_BRUTAL_COMMIT}" \
	"amneziawg_commit:${AMNEZIAWG_COMMIT}" \
	"nf_deaf_commit:${NF_DEAF_COMMIT}"; do
	pin_key="${pin_entry%%:*}"
	expected_commit="${pin_entry##*:}"
	actual_commit="$(require_manifest_value "${evidence_manifest}" "${pin_key}")" || exit 1
	if [[ "${actual_commit}" != "${expected_commit}" ]]; then
		_kernel_inject_log err "Pin validation failed" \
			"${pin_key}: expected ${expected_commit:0:12}, got ${actual_commit:-missing}"
		exit 1
	fi
	_kernel_inject_log debug "Pin validation" "${pin_key}=${actual_commit:0:12} passed"
done
_kernel_inject_log info "Build evidence validation" \
	"The final config, Kconfig symbol inventory, and all three source pins come from the linux-image package and do not depend on a temporary worktree"

# Reuse the symbol inventory captured while the source tree still existed.
_kernel_inject_cleanup_symbol_cache
_KERNEL_INJECT_DEFINED_SYMBOLS_ROOT="${evidence_dir}"
_KERNEL_INJECT_DEFINED_SYMBOLS_FILE="${defined_symbols}"

if [[ "${ENABLE_FULL_EBPF}" == yes ]]; then
	_kernel_inject_log info "Final config validation" "Starting eBPF / BTF / CO-RE validation"
	_kernel_inject_verify_full_ebpf_config "${final_config}"
fi
if [[ "${ENABLE_FULL_NETWORKING}" == yes ]]; then
	_kernel_inject_log info "Final config validation" "Starting full networking validation"
	_kernel_inject_verify_full_network_config "${final_config}"
fi

generate_release_metadata "${evidence_dir}" "${requested_branch:-${built_branch}}" \
	"${requested_board:-unknown}" "${userspace_release:-unknown}" \
	"${package_extract_root}"
