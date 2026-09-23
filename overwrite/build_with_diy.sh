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

# 版本相关符号随内核增删，被强制校验跳过的符号会记录到这里，
# 并写进 release notes，方便追溯。
_kernel_inject_skipped_symbols=()

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

source_commit() {
	local revision_file="$1"
	local commit

	commit="$(sed -n 's/^commit=//p' "${revision_file}" 2>/dev/null || true)"
	printf '%s\n' "${commit:-unknown}"
}

generate_release_metadata() {
	local kernel_root="$1"
	local branch="$2"
	local board="$3"
	local userspace_release="$4"
	local metadata_parent="output/release-metadata"
	local metadata_dir="${metadata_parent}/${branch}"
	local staging
	local baseline_dir
	local final_config="${kernel_root}/.config"
	local config_asset
	local diff_asset
	local summary_file
	local kernel_release
	local config_sha256
	local diff_count=0
	local baseline_status="unavailable"
	local tcp_commit
	local awg_commit
	local nf_commit

	_kernel_inject_log info "Release 元数据" "开始生成: branch=${branch}, board=${board}, release=${userspace_release}"
	[[ "${branch}" =~ ^[A-Za-z0-9._-]+$ ]] || {
		echo "[kernel-inject][error] unsafe BRANCH value for release metadata: ${branch}" >&2
		return 1
	}
	[[ -f "${final_config}" ]] || {
		echo "[kernel-inject][error] final kernel config is missing: ${final_config}" >&2
		return 1
	}

	mkdir -p "${metadata_parent}"
	staging="$(mktemp -d "${metadata_parent}/.${branch}.XXXXXX")"
	config_asset="${staging}/${branch}-kernel.config"
	diff_asset="${staging}/${branch}-config-vs-arm64-defconfig.txt"
	summary_file="${staging}/build-summary.md"
	cp -- "${final_config}" "${config_asset}"
	config_sha256="$(sha256sum "${config_asset}" | awk '{print $1}')"
	_kernel_inject_log debug "Release 元数据" "最终配置 SHA256=${config_sha256}"

	kernel_release="$(make -s -C "${kernel_root}" ARCH=arm64 kernelrelease 2>/dev/null || true)"
	kernel_release="${kernel_release:-$(basename "${kernel_root}")}"
	_kernel_inject_log debug "Release 元数据" "内核 release=${kernel_release}"
	baseline_dir="$(mktemp -d "${TMPDIR:-/tmp}/arm64-defconfig.XXXXXX")"
	if [[ -f "${kernel_root}/Makefile" ]] && {
		make -s -C "${kernel_root}" O="${baseline_dir}" ARCH=arm64 defconfig \
			> "${staging}/arm64-defconfig-build.log" 2>&1 ||
		KCONFIG_CONFIG="${baseline_dir}/.config" \
			make -s -C "${kernel_root}" ARCH=arm64 defconfig \
				>> "${staging}/arm64-defconfig-build.log" 2>&1
	}; then
		if [[ -x "${kernel_root}/scripts/diffconfig" ]] && \
			"${kernel_root}/scripts/diffconfig" "${baseline_dir}/.config" "${final_config}" \
				> "${diff_asset}"; then
			baseline_status="generated"
			diff_count="$(awk 'NF { count++ } END { print count + 0 }' "${diff_asset}")"
		else
			printf 'Unable to run scripts/diffconfig against arm64 defconfig.\n' > "${diff_asset}"
		fi
	else
		printf 'Unable to generate an arm64 defconfig baseline; see arm64-defconfig-build.log.\n' \
			> "${diff_asset}"
	fi
	_kernel_inject_log info "Release 元数据" "arm64 defconfig 对照: ${baseline_status}, 配置差异 ${diff_count} 项"
	rm -rf -- "${baseline_dir}"

	tcp_commit="$(source_commit "${kernel_root}/net/ipv4/tcp_brutal/.source-revision")"
	awg_commit="$(source_commit "${kernel_root}/drivers/net/amneziawg/.source-revision")"
	nf_commit="$(source_commit "${kernel_root}/net/netfilter/nf_deaf/.source-revision")"
	_kernel_inject_log debug "Release 元数据" \
		"源码提交: tcp-brutal=${tcp_commit:0:12}, amneziawg=${awg_commit:0:12}, nf_deaf=${nf_commit:0:12}"
	if [[ ! "${tcp_commit}" =~ ^[0-9a-f]{40}$ || \
		! "${awg_commit}" =~ ^[0-9a-f]{40}$ || \
		! "${nf_commit}" =~ ^[0-9a-f]{40}$ ]]; then
		echo "[kernel-inject][error] release metadata contains an invalid source commit" >&2
		rm -rf -- "${staging}"
		return 1
	fi

	{
		printf '# 内核构建详情\n\n'
		printf '| 项目 | 最终值 |\n|---|---|\n'
		printf '| 内核 release | `%s` |\n' "${kernel_release}"
		printf '| Armbian 分支 | `%s` |\n' "${branch}"
		printf '| 板型 / 架构 | `%s` / `arm64` |\n' "${board}"
		printf '| Userspace release | `%s` |\n' "${userspace_release}"
		printf '| 最终配置 SHA256 | `%s` |\n' "${config_sha256}"
		printf '| 完整 eBPF 强制校验 | `%s` |\n' "${ENABLE_FULL_EBPF}"
		printf '| 完整网络功能强制校验 | `%s` |\n' "${ENABLE_FULL_NETWORKING}"
		printf '\n## 与标准内核配置的差异\n\n'
		printf '附件 `%s` 是经过 `olddefconfig` 解析后的最终有效配置。' "$(basename "${config_asset}")"
		if [[ "${baseline_status}" == generated ]]; then
			printf '与同一份 Armbian 补丁后源码树生成的 `arm64 defconfig` 相比，共有 **%s 项配置差异**。\n\n' "${diff_count}"
		else
			printf '本次未能生成 `arm64 defconfig` 对照，但最终配置仍已附带。\n\n'
		fi
		if ((${#_kernel_inject_skipped_symbols[@]} > 0)); then
			# 清单里随内核版本增删的符号在本树未定义时被跳过并记录在这里。
			printf '> 强制校验清单中有 **%s 个符号在当前内核树未定义**，已跳过: %s\n\n' \
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
		printf '| 原生 WireGuard | `%s` | Linux 内核源码树 |\n' \
			"$(config_value "${final_config}" WIREGUARD)"
		printf '\n## 完整网络功能集\n\n'
		if [[ "${ENABLE_FULL_NETWORKING}" == yes ]]; then
			printf '最终配置已逐项校验：MPLS 路由/隧道、SRv6（LWT/HMAC/BPF）、VXLAN、Geneve、IPv4/IPv6 GRE、FOU、WireGuard、TPROXY、SYNPROXY、nftables、BBR+FQ、NPTv6、Linux bridge/bridge netfilter、Bluetooth BNEP，以及 ConfigFS/FunctionFS USB Gadget。\n\n'
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

_kernel_inject_log info "构建包装器" \
	"参数: target=kernel BRANCH=${requested_branch:-<unset>} BOARD=${requested_board:-<unset>} RELEASE=${userspace_release:-<unset>}"
_kernel_inject_log info "构建包装器" \
	"完整 eBPF: ${ENABLE_FULL_EBPF}, 完整网络功能: ${ENABLE_FULL_NETWORKING}, KERNEL_BTF: ${KERNEL_BTF}"

_kernel_inject_log info "构建包装器" "启动 Armbian: ./compile.sh $*"
./compile.sh "$@"
_kernel_inject_log info "构建包装器" "compile.sh 正常返回，开始校验本次构建产物"

# Armbian does not ship a separate linux-modules package: the .ko files live
# inside linux-image-<branch>-<family>. Start from the artifact this build
# actually produced: the most recently modified kernel image package in
# output/debs.
image_deb_list="$(find output/debs -name 'linux-image-*.deb' -printf '%T@ %p\n' 2>/dev/null | sort -rn || true)"
if [[ -z "${image_deb_list}" ]]; then
	_kernel_inject_log err "产物定位失败" "output/debs 下没有 linux-image-*.deb"
	exit 1
fi
_kernel_inject_log debug "产物定位" "output/debs 中的内核包（按修改时间降序）:"
while IFS= read -r entry; do
	_kernel_inject_log debug "产物定位" "  ${entry#* }"
done <<< "${image_deb_list}"

image_deb=""
if [[ -n "${requested_branch}" ]]; then
	if [[ ! "${requested_branch}" =~ ^[A-Za-z0-9._-]+$ ]]; then
		_kernel_inject_log err "不安全的 BRANCH 值" "${requested_branch}"
		exit 1
	fi
	image_deb="$(printf '%s\n' "${image_deb_list}" \
		| grep -E "linux-image-${requested_branch}-rockchip64_" \
		| head -n 1 | cut -d' ' -f2- || true)"
	if [[ -z "${image_deb}" ]]; then
		_kernel_inject_log err "产物定位失败" "output/debs 下没有 BRANCH=${requested_branch} 的 linux-image deb"
		exit 1
	fi
else
	image_deb="$(printf '%s\n' "${image_deb_list}" | head -n 1 | cut -d' ' -f2-)"
	_kernel_inject_log warn "产物定位" "未传入 BRANCH，按修改时间取最新: $(basename "${image_deb}")"
fi
_kernel_inject_log info "产物定位" \
	"选定 $(basename "${image_deb}") ($(du -h "${image_deb}" | awk '{print $1}'), mtime $(date -u -d "@${image_deb%% *}" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown))"

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

# Armbian names each worktree ${KERNEL_MAJOR_MINOR}__${LINUXFAMILY}__${ARCH},
# so the artifact's version selects the tree it was built from.
_kernel_inject_log debug "worktree 扫描" "在 cache/sources/linux-kernel-worktree 中查找内核 ${kernel_major_minor} 的构建树"
revision_files="$(find cache/sources/linux-kernel-worktree -maxdepth 5 -type f \
	-path "*/${kernel_major_minor}__*/net/ipv4/tcp_brutal/.source-revision" \
	2>/dev/null || true)"
if [[ -z "${revision_files}" ]]; then
	_kernel_inject_log err "worktree 缺失" "no kernel ${kernel_major_minor} worktree under cache/sources/linux-kernel-worktree"
	_kernel_inject_log debug "worktree 缺失" "existing worktrees:"
	find cache/sources/linux-kernel-worktree -maxdepth 1 -mindepth 1 -print 2>/dev/null >&2 || true
	exit 1
fi
while IFS= read -r revision_file; do
	_kernel_inject_log debug "worktree 扫描" \
		"候选: ${revision_file} -> commit=$(sed -n 's/^commit=//p' "${revision_file}" 2>/dev/null || echo '<unreadable>')"
done <<< "${revision_files}"

kernel_root=""
while IFS= read -r revision_file; do
	if [[ "$(sed -n 's/^commit=//p' "${revision_file}" 2>/dev/null)" == "${TCP_BRUTAL_COMMIT}" ]]; then
		kernel_root="$(cd "$(dirname "${revision_file}")/../../.." && pwd -P)"
		break
	fi
done <<< "${revision_files}"

if [[ -z "${kernel_root}" ]]; then
	_kernel_inject_log err "pin 校验失败" "kernel ${kernel_major_minor} worktree does not match pinned TCP-Brutal commit ${TCP_BRUTAL_COMMIT:0:12}"
	_kernel_inject_log err "pin 校验失败" "the custom_kernel_config hook did not run in this build"
	exit 1
fi
_kernel_inject_log info "worktree 定位" "构建树: ${kernel_root}"

# A TCP-Brutal pin match does not prove the other two modules were injected
# into the same tree at their pinned revisions.
for revision_path in \
	"drivers/net/amneziawg:${AMNEZIAWG_COMMIT}" \
	"net/netfilter/nf_deaf:${NF_DEAF_COMMIT}"; do
	relative_path="${revision_path%%:*}"
	expected_commit="${revision_path##*:}"
	actual_commit="$(sed -n 's/^commit=//p' "${kernel_root}/${relative_path}/.source-revision" 2>/dev/null || true)"
	if [[ "${actual_commit}" != "${expected_commit}" ]]; then
		_kernel_inject_log err "pin 校验失败" "${relative_path}: expected ${expected_commit:0:12}, got ${actual_commit:-missing}"
		exit 1
	fi
	_kernel_inject_log debug "pin 校验" "${relative_path} = ${actual_commit:0:12} 通过"
done

# All three modules default to =m, so they ship in the kernel image package.
# The worktree can outlive a build that never compiled them; the artifact
# cannot lie.
if command -v dpkg-deb >/dev/null 2>&1; then
	for module in tcp_brutal amneziawg nf_deaf; do
		if dpkg-deb -c "${image_deb}" 2>/dev/null | grep -q "${module}"; then
			_kernel_inject_log debug "模块产物校验" "${module}: 存在于 $(basename "${image_deb}")"
		else
			_kernel_inject_log err "模块产物校验" "module '${module}' missing from $(basename "${image_deb}")"
			_kernel_inject_log err "模块产物校验" "source was injected but did not compile into the package"
			exit 1
		fi
	done
	_kernel_inject_log info "模块产物校验" "tcp_brutal / amneziawg / nf_deaf 均已编译进内核包"
else
	_kernel_inject_log warn "模块产物校验" "dpkg-deb unavailable; skipping module contents verification of $(basename "${image_deb}")"
fi

if [[ "${ENABLE_FULL_EBPF}" == yes ]]; then
	_kernel_inject_log info "最终配置校验" "开始 eBPF / BTF / CO-RE 校验"
	_kernel_inject_verify_full_ebpf_config "${kernel_root}/.config"
fi
if [[ "${ENABLE_FULL_NETWORKING}" == yes ]]; then
	_kernel_inject_log info "最终配置校验" "开始完整网络功能校验"
	_kernel_inject_verify_full_network_config "${kernel_root}/.config"
fi

generate_release_metadata "${kernel_root}" "${requested_branch:-unknown}" \
	"${requested_board:-unknown}" "${userspace_release:-unknown}"
