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
case "${KERNEL_BTF}" in
	yes|no) ;;
	*)
		echo "[kernel-inject][error] KERNEL_BTF must be yes or no" >&2
		exit 1
		;;
esac
export ENABLE_FULL_EBPF KERNEL_BTF

# Runtime path is the Armbian build root.
# shellcheck disable=SC1091
source userpatches/lib.config

validation_marker="$(mktemp)"
trap 'rm -f -- "${validation_marker}"' EXIT

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

	kernel_release="$(make -s -C "${kernel_root}" ARCH=arm64 kernelrelease 2>/dev/null || true)"
	kernel_release="${kernel_release:-$(basename "${kernel_root}")}"
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
	rm -rf -- "${baseline_dir}"

	tcp_commit="$(source_commit "${kernel_root}/net/ipv4/tcp_brutal/.source-revision")"
	awg_commit="$(source_commit "${kernel_root}/drivers/net/amneziawg/.source-revision")"
	nf_commit="$(source_commit "${kernel_root}/net/netfilter/nf_deaf/.source-revision")"
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
		printf '\n## 与标准内核配置的差异\n\n'
		printf '附件 `%s` 是经过 `olddefconfig` 解析后的最终有效配置。' "$(basename "${config_asset}")"
		if [[ "${baseline_status}" == generated ]]; then
			printf '与同一份 Armbian 补丁后源码树生成的 `arm64 defconfig` 相比，共有 **%s 项配置差异**。\n\n' "${diff_count}"
		else
			printf '本次未能生成 `arm64 defconfig` 对照，但最终配置仍已附带。\n\n'
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
	echo "[kernel-inject] Release metadata written to ${metadata_dir}"
}

# Remove the obsolete v1 patch if it remains in a reused/ignored userpatches
# directory. TCP-Brutal v2 owns its socket-option routing.
rm -f -- userpatches/90_patch_brutal.sh

echo "[kernel-inject] Starting Armbian with pinned source injection (full eBPF: ${ENABLE_FULL_EBPF})"
./compile.sh "$@"

mapfile -d '' -t injected_revisions < <(find cache/sources/linux-kernel-worktree -type f \
	-path '*/net/ipv4/tcp_brutal/.source-revision' \
	-newer "${validation_marker}" -print0 2>/dev/null)
if ((${#injected_revisions[@]} != 1)); then
	echo "[kernel-inject][error] expected one freshly injected kernel tree, found ${#injected_revisions[@]}" >&2
	exit 1
fi

kernel_root="$(cd "$(dirname "${injected_revisions[0]}")/../../.." && pwd -P)"
if [[ "${ENABLE_FULL_EBPF}" == yes ]]; then
	_kernel_inject_verify_full_ebpf_config "${kernel_root}/.config"
fi

branch="$(argument_value BRANCH "$@" || true)"
board="$(argument_value BOARD "$@" || true)"
userspace_release="$(argument_value RELEASE "$@" || true)"
generate_release_metadata "${kernel_root}" "${branch:-unknown}" \
	"${board:-unknown}" "${userspace_release:-unknown}"
