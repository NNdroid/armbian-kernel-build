#!/usr/bin/env bash
# Build-wrapper library; loaded only from the synchronized Armbian tree.
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
