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

# 兼容性检查中允许不存在的旧负向符号会记录到这里，并写进 release notes。
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
		_kernel_inject_log err "构建证据损坏" \
			"$(basename "${manifest_file}") 缺少 ${wanted_key}"
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
			_kernel_inject_log err "模块附件导出" \
				"CONFIG_${config_symbol}=m，但内核包内找到 ${#matched_modules[@]} 份 ${module}.ko*（要求恰好一份）"
			return 1
		fi

		case "${module}" in
			brutal) display_name="TCP-Brutal v2" ;;
			amneziawg) display_name="AmneziaWG" ;;
			nf_deaf) display_name="nf_deaf" ;;
			wireguard) display_name="原生 WireGuard" ;;
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
		_kernel_inject_log info "模块附件导出" \
			"${display_name}: ${module_basename} -> ${asset_basename}"
	done

	if ((exported_module_count == 0)); then
		rm -f -- "${module_sums}"
		_kernel_inject_log info "模块附件导出" "最终配置没有 =m 的受管组件，无需生成独立 .ko 附件"
		return 0
	fi

	{
		printf '## 可加载模块附件\n\n'
		printf '下列组件的最终配置为 `m`。Release 同时上传了内核包中的原始 `.ko`'
		printf '（可能使用 `.gz`、`.xz` 或 `.zst` 压缩）以及校验文件 `%s`。\n\n' \
			"$(basename "${module_sums}")"
		printf '> 模块与内核 ABI 严格绑定：仅用于 `uname -r` 恰好为 `%s`、Debian 架构为 `%s` 的系统。不同内核 release、架构或配置不能混用。\n\n' \
			"${kernel_release}" "${debian_arch}"
		printf '| 组件 | Kconfig | Release 附件 | 安装后的规范文件名 | SHA256 |\n'
		printf '|---|---|---|---|---|\n'
		for ((i = 0; i < exported_module_count; i++)); do
			printf '| %s | `CONFIG_%s=m` | `%s` | `%s` | `%s` |\n' \
				"${exported_display_names[i]}" "${exported_config_symbols[i]}" \
				"${exported_names[i]}" "${exported_canonical_names[i]}" \
				"${exported_sha256[i]}"
		done
		printf '\n### 推荐方式：安装完整内核包\n\n'
		printf '对应的 `linux-image-*.deb` 已包含这些模块和完整的模块索引；安装该包并重启到目标内核后，只需：\n\n'
		printf '```bash\n'
		for module in "${exported_modules[@]}"; do
			printf 'sudo modprobe %q\n' "${module}"
		done
		printf '```\n\n'
		printf '### 只安装独立模块附件\n\n'
		printf '先下载上表附件到当前目录，再执行（文件名必须按命令恢复为模块的规范名称）：\n\n'
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
		printf '可用 `modinfo <模块名>` 和 `lsmod` 验证。若启用了 Secure Boot，独立模块还必须由系统信任的密钥签名；出现 `invalid module format` 时通常表示内核 release、架构、vermagic 或签名不匹配，应改装对应的完整 `.deb`。\n'
		printf '\n> MT7921E 还需要与硬件/驱动匹配的 MediaTek 固件文件（通常由发行版 `linux-firmware` 提供）；`.ko` 附件本身不包含固件。\n'
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

	_kernel_inject_log info "Release 元数据" "开始生成: branch=${branch}, board=${board}, release=${userspace_release}"
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
	config_sha256="$(sha256sum "${config_asset}" | awk '{print $1}')"
	if [[ "${config_sha256}" != "${expected_config_sha256}" ]]; then
		echo "[kernel-inject][error] final config checksum does not match packaged build evidence" >&2
		rm -rf -- "${staging}"
		return 1
	fi
	_kernel_inject_log debug "Release 元数据" "最终配置 SHA256=${config_sha256}"
	_kernel_inject_log debug "Release 元数据" "内核 release=${kernel_release}"
	if [[ ! -f "${evidence_dir}/config-vs-${kbuild_arch}-defconfig.txt" || \
		! -f "${evidence_dir}/${kbuild_arch}-defconfig-build.log" ]]; then
		echo "[kernel-inject][error] packaged defconfig diagnostics are incomplete" >&2
		rm -rf -- "${staging}"
		return 1
	fi
	cp -- "${evidence_dir}/config-vs-${kbuild_arch}-defconfig.txt" "${diff_asset}"
	cp -- "${evidence_dir}/${kbuild_arch}-defconfig-build.log" \
		"${staging}/${kbuild_arch}-defconfig-build.log"
	_kernel_inject_log info "Release 元数据" \
		"${kbuild_arch} defconfig 对照: ${baseline_status}, 配置差异 ${diff_count} 项"

	_kernel_inject_log debug "Release 元数据" \
		"源码提交: tcp-brutal=${tcp_commit:0:12}, amneziawg=${awg_commit:0:12}, nf_deaf=${nf_commit:0:12}"
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
		printf '# 内核构建详情\n\n'
		printf '| 项目 | 最终值 |\n|---|---|\n'
		printf '| 内核 release | `%s` |\n' "${kernel_release}"
		printf '| Armbian 分支 | `%s` |\n' "${branch}"
		printf '| 板型 / family / Debian 架构 / Kbuild 架构 | `%s` / `%s` / `%s` / `%s` |\n' \
			"${board}" "${linuxfamily}" "${debian_arch}" "${kbuild_arch}"
		printf '| Userspace release | `%s` |\n' "${userspace_release}"
		printf '| Armbian/build 基线提交 | `%s` |\n' "${armbian_build_commit}"
		printf '| 内核源码基线提交 | `%s` |\n' "${kernel_source_commit}"
		printf '| 最终配置 SHA256 | `%s` |\n' "${config_sha256}"
		printf '| 完整 eBPF 强制校验 | `%s` |\n' "${ENABLE_FULL_EBPF}"
		printf '| 完整网络功能强制校验 | `%s` |\n' "${ENABLE_FULL_NETWORKING}"
		printf '\n## 与标准内核配置的差异\n\n'
		printf '附件 `%s` 是经过 `olddefconfig` 解析后的最终有效配置。' "$(basename "${config_asset}")"
		if [[ "${baseline_status}" == generated ]]; then
			printf '与同一份 Armbian 补丁后源码树生成的 `%s defconfig` 相比，共有 **%s 项配置差异**。\n\n' \
				"${kbuild_arch}" "${diff_count}"
		else
			printf '本次未能生成 `%s defconfig` 对照，但最终配置仍已附带。\n\n' "${kbuild_arch}"
		fi
		if ((${#_kernel_inject_skipped_symbols[@]} > 0)); then
			printf '> 有 **%s 个旧版负向兼容符号在当前内核树未定义**，无需检查其关闭状态: %s\n\n' \
				"${#_kernel_inject_skipped_symbols[@]}" "${_kernel_inject_skipped_symbols[*]}"
		fi
		printf '> 这是配置层对比；Armbian 板级、设备树及其他补丁是相对于 kernel.org 的额外源码级差异。\n\n'
		printf '## 额外网络组件\n\n'
		printf '| 组件 | 构建模式 | 源码提交 |\n|---|---:|---|\n'
		printf '| TCP-Brutal v2 | `%s` | [`%s`](https://github.com/HyNetworks/tcp-brutal/commit/%s) |\n' \
			"$(config_value "${final_config}" TCP_CONG_BRUTAL)" "${tcp_commit:0:12}" "${tcp_commit}"
		printf '| AmneziaWG | `%s` | [`%s`](https://github.com/NNdroid/amneziawg-linux-kernel-module/commit/%s) |\n' \
			"$(config_value "${final_config}" AMNEZIAWG)" "${awg_commit:0:12}" "${awg_commit}"
		printf '| nf_deaf | `%s` | [`%s`](https://github.com/NNdroid/nf_deaf/commit/%s) |\n' \
			"$(config_value "${final_config}" NETFILTER_DEAF)" "${nf_commit:0:12}" "${nf_commit}"
		printf '| 原生 WireGuard（默认由 AmneziaWG 取代） | `%s` | Linux 内核源码树 |\n' \
			"$(config_value "${final_config}" WIREGUARD)"
		printf '\n'
		if ((exported_module_count > 0)); then
			cat "${exported_module_guide}"
		else
			printf '> 以上受管组件的最终模式均不是 `m`，因此本次 Release 不生成独立 `.ko` 附件；`y` 表示已直接内建进内核。\n'
		fi
		printf '\n## 完整网络功能集\n\n'
		if [[ "${ENABLE_FULL_NETWORKING}" == yes ]]; then
			printf '最终配置已逐项校验：MPLS 路由/隧道、SRv6、VXLAN/Geneve/GRE/FOU、AmneziaWG、netfilter/nftables、BBR+FQ、NPTv6、Linux bridge 与 USB Gadget 强制内建；Bluetooth 与 cfg80211/mac80211/MT7921E 驱动链强制为模块。\n\n'
			printf '| 能力 | 关键最终配置 |\n|---|---|\n'
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
			printf '本次构建关闭了完整网络功能强制校验；请检查附件中的最终配置。\n'
		fi
		printf '\n## eBPF / BTF / CO-RE\n\n'
		if [[ "${ENABLE_FULL_EBPF}" == yes ]]; then
			printf '最终配置已通过以下能力检查：BPF syscall/JIT、内核及模块 BTF、CO-RE、cgroup/LSM、XDP/AF_XDP、tc、netfilter、kprobe/uprobe 和 ftrace。非特权 BPF 默认关闭。\n'
		else
			printf '本次构建关闭了完整 eBPF 强制校验；使用 BTF/CO-RE 或追踪功能前请检查附件中的最终配置。\n'
		fi
		printf '\n完整配置差异见附件 `%s`。\n' "$(basename "${diff_asset}")"
	} > "${summary_file}"

	rm -rf -- "${metadata_dir}"
	mv -- "${staging}" "${metadata_dir}"
	_kernel_inject_log info "Release 元数据" "写入 ${metadata_dir}: $(find "${metadata_dir}" -maxdepth 1 -type f -printf '%f ' 2>/dev/null)"
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

_kernel_inject_log info "构建包装器" \
	"参数: target=kernel BRANCH=${requested_branch:-<unset>} BOARD=${requested_board:-<unset>} RELEASE=${userspace_release:-<unset>}"
_kernel_inject_log info "构建包装器" \
	"完整 eBPF: ${ENABLE_FULL_EBPF}, 完整网络功能: ${ENABLE_FULL_NETWORKING}, KERNEL_BTF: ${KERNEL_BTF}"
_kernel_inject_log info "构建包装器" \
	"Armbian 扩展: ${ENABLE_EXTENSIONS}（已确保启用 kernel-inject-evidence）"

mkdir -p output/debs
artifact_marker="$(mktemp "${TMPDIR:-/tmp}/kernel-build-start.XXXXXX")"
_kernel_inject_log info "构建包装器" "启动 Armbian: ./compile.sh $*"
./compile.sh "$@"
_kernel_inject_log info "构建包装器" "compile.sh 正常返回，开始校验本次构建产物"

# Armbian does not ship a separate linux-modules package: the .ko files live
# inside linux-image-<branch>-<family>. Start from the artifact this build
# actually produced: only kernel image packages newer than the marker created
# immediately before compile.sh are eligible. This prevents a stale package
# from a previous run from satisfying post-build validation.
image_deb_list="$(find output/debs -type f -name 'linux-image-*.deb' \
	-newer "${artifact_marker}" -printf '%T@ %p\n' 2>/dev/null | sort -rn || true)"
if [[ -z "${image_deb_list}" ]]; then
	_kernel_inject_log err "产物定位失败" "本次 compile.sh 未在 output/debs 生成新的 linux-image-*.deb"
	exit 1
fi
_kernel_inject_log debug "产物定位" "output/debs 中的内核包（按修改时间降序）:"
while IFS= read -r entry; do
	_kernel_inject_log debug "产物定位" "  ${entry#* }"
done <<< "${image_deb_list}"

image_deb_entry=""
if [[ -n "${requested_branch}" ]]; then
	if [[ ! "${requested_branch}" =~ ^[A-Za-z0-9._-]+$ ]]; then
		_kernel_inject_log err "不安全的 BRANCH 值" "${requested_branch}"
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
		_kernel_inject_log err "产物定位失败" "output/debs 下没有 BRANCH=${requested_branch} 的 linux-image deb"
		exit 1
	fi
else
	image_deb_entry="${image_deb_list%%$'\n'*}"
fi
image_deb_mtime="${image_deb_entry%% *}"
image_deb="${image_deb_entry#* }"
if [[ -z "${requested_branch}" ]]; then
	_kernel_inject_log warn "产物定位" "未传入 BRANCH，按修改时间取最新: $(basename "${image_deb}")"
fi
_kernel_inject_log info "产物定位" \
	"选定 $(basename "${image_deb}") ($(du -h "${image_deb}" | awk '{print $1}'), mtime $(date -u -d "@${image_deb_mtime}" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown))"

built_branch="$(basename "${image_deb}" | sed -n 's/^linux-image-\([A-Za-z0-9._-]*\)-rockchip64_.*/\1/p')"
if [[ -z "${built_branch}" ]]; then
	_kernel_inject_log err "产物命名异常" "无法从 $(basename "${image_deb}") 解析分支名"
	exit 1
fi
if [[ -n "${requested_branch}" && "${built_branch}" != "${requested_branch}" ]]; then
	_kernel_inject_log err "产物分支不匹配" \
		"最新 deb 属于分支 ${built_branch}，而本次构建 BRANCH=${requested_branch}"
	_kernel_inject_log err "产物分支不匹配" "通常是上一次构建的产物未被清理或本次构建实际未产出新包"
	exit 1
fi
_kernel_inject_log debug "产物定位" "deb 所属分支: ${built_branch}"

kernel_major_minor="$(basename "${image_deb}" | \
	sed -n 's/^.*__\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
if [[ -z "${kernel_major_minor}" ]]; then
	_kernel_inject_log err "产物命名异常" "cannot derive kernel version from $(basename "${image_deb}")"
	exit 1
fi
_kernel_inject_log info "产物定位" "实际构建内核大版本: ${kernel_major_minor}"

# Validate loadable-module files before extraction. Built-in components are
# verified later against both the packaged final config and modules.builtin.
# The package is the durable build result; Docker may discard its source tree
# before this wrapper regains control.
if ! command -v dpkg-deb >/dev/null 2>&1; then
	_kernel_inject_log err "产物校验失败" "dpkg-deb is required to verify $(basename "${image_deb}")"
	exit 1
fi
module_manifest="$(mktemp "${TMPDIR:-/tmp}/kernel-image-modules.XXXXXX")"
if ! dpkg-deb -c "${image_deb}" > "${module_manifest}" 2>/dev/null; then
	_kernel_inject_log err "模块产物校验" "无法读取 $(basename "${image_deb}") 的文件清单"
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
				_kernel_inject_log err "模块产物校验" \
					"${module}: requested =m but .ko is missing from $(basename "${image_deb}")"
				exit 1
			fi
			_kernel_inject_log debug "模块产物校验" "${module}=m: .ko 存在"
			;;
		y|n)
			if [[ "${module_present}" == yes ]]; then
				_kernel_inject_log err "模块产物校验" \
					"${module}: requested =${expected_mode} but package unexpectedly contains a loadable .ko"
				exit 1
			fi
			;;
	esac
done

package_extract_root="$(mktemp -d "${TMPDIR:-/tmp}/kernel-image-evidence.XXXXXX")"
if ! dpkg-deb -x "${image_deb}" "${package_extract_root}"; then
	_kernel_inject_log err "构建证据缺失" "无法解包 $(basename "${image_deb}")"
	exit 1
fi
mapfile -d '' -t evidence_manifests < <(
	find "${package_extract_root}/usr/lib/armbian-kernel-build" -type f \
		-name source-manifest.env -print0 2>/dev/null
)
if ((${#evidence_manifests[@]} != 1)); then
	_kernel_inject_log err "构建证据缺失" \
		"$(basename "${image_deb}") 必须包含且只包含一份 source-manifest.env，实际 ${#evidence_manifests[@]} 份"
	_kernel_inject_log err "构建证据缺失" \
		"kernel-inject-evidence 扩展未参与该包；检查 Extension Manager 日志和包版本中的 HK 哈希"
	exit 1
fi
evidence_manifest="${evidence_manifests[0]}"
evidence_dir="$(dirname "${evidence_manifest}")"
final_config="${evidence_dir}/kernel.config"
defined_symbols="${evidence_dir}/defined-symbols.txt"
if [[ ! -s "${final_config}" || ! -s "${defined_symbols}" ]]; then
	_kernel_inject_log err "构建证据损坏" "最终配置或 Kconfig 符号清单缺失"
	exit 1
fi

builtin_manifest="$(mktemp "${TMPDIR:-/tmp}/kernel-image-builtins.XXXXXX")"
find "${package_extract_root}" -type f -name modules.builtin -exec cat {} + \
	> "${builtin_manifest}" 2>/dev/null || true
for component_spec in "${component_specs[@]}"; do
	IFS=: read -r module config_symbol expected_mode <<< "${component_spec}"
	actual_mode="$(config_value "${final_config}" "${config_symbol}")"
	if [[ "${actual_mode}" != "${expected_mode}" ]]; then
		_kernel_inject_log err "构建模式校验" \
			"CONFIG_${config_symbol}: requested ${expected_mode}, packaged config has ${actual_mode}"
		exit 1
	fi
	if [[ "${expected_mode}" == y ]]; then
		if ! grep -Eq "/${module}\.ko$" "${builtin_manifest}"; then
			_kernel_inject_log err "内建产物校验" \
				"${module}: CONFIG_${config_symbol}=y but modules.builtin has no matching entry"
			exit 1
		fi
		_kernel_inject_log debug "内建产物校验" "${module}=y: modules.builtin 已确认"
	fi
done
_kernel_inject_log info "构建模式校验" \
	"brutal=${TCP_BRUTAL_MODE}, amneziawg=${AMNEZIAWG_MODE}, nf_deaf=${NF_DEAF_MODE}, native-wireguard=${WIREGUARD_MODE} 均与内核包一致"
if [[ "${ENABLE_FULL_NETWORKING}" == yes ]]; then
	_kernel_inject_log info "构建模式校验" \
		"Bluetooth core/BNEP 与 cfg80211/mac80211/MT7921E 依赖链均为模块且 .ko 存在"
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
	_kernel_inject_log err "构建证据不匹配" \
		"manifest(format=${manifest_format}, branch=${manifest_branch}, family=${manifest_family}, arch=${manifest_arch}, kernel=${manifest_kernel_major_minor})"
	_kernel_inject_log err "构建证据不匹配" \
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
		_kernel_inject_log err "pin 校验失败" \
			"${pin_key}: expected ${expected_commit:0:12}, got ${actual_commit:-missing}"
		exit 1
	fi
	_kernel_inject_log debug "pin 校验" "${pin_key}=${actual_commit:0:12} 通过"
done
_kernel_inject_log info "构建证据校验" \
	"最终配置、Kconfig 符号清单和三项源码 pin 均来自 linux-image 包，不依赖临时 worktree"

# Reuse the symbol inventory captured while the source tree still existed.
_kernel_inject_cleanup_symbol_cache
_KERNEL_INJECT_DEFINED_SYMBOLS_ROOT="${evidence_dir}"
_KERNEL_INJECT_DEFINED_SYMBOLS_FILE="${defined_symbols}"

if [[ "${ENABLE_FULL_EBPF}" == yes ]]; then
	_kernel_inject_log info "最终配置校验" "开始 eBPF / BTF / CO-RE 校验"
	_kernel_inject_verify_full_ebpf_config "${final_config}"
fi
if [[ "${ENABLE_FULL_NETWORKING}" == yes ]]; then
	_kernel_inject_log info "最终配置校验" "开始完整网络功能校验"
	_kernel_inject_verify_full_network_config "${final_config}"
fi

generate_release_metadata "${evidence_dir}" "${requested_branch:-${built_branch}}" \
	"${requested_board:-unknown}" "${userspace_release:-unknown}" \
	"${package_extract_root}"
