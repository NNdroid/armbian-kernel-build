#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Resolved from the computed repository root.
# shellcheck disable=SC1091
source "${REPO_ROOT}/userpatches/lib.config"

fail() {
	printf '[FAIL] %s\n' "$*" >&2
	exit 1
}

assert_file() {
	[[ -f "$1" ]] || fail "missing file: $1"
}

assert_absent() {
	[[ ! -e "$1" ]] || fail "legacy path still exists: $1"
}

assert_contains() {
	grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

assert_not_contains() {
	if grep -Fq -- "$2" "$1"; then
		fail "$1 unexpectedly contains: $2"
	fi
}

assert_count() {
	local actual
	actual="$(grep -Fc -- "$2" "$1" || true)"
	[[ "${actual}" == "$3" ]] || fail "$1 contains '$2' ${actual} times, expected $3"
}

assert_array_contains() {
	local array_name="$1"
	local expected="$2"
	local item
	local -n values="${array_name}"

	for item in "${values[@]}"; do
		[[ "${item}" == "${expected}" ]] && return 0
	done
	fail "${array_name} does not contain: ${expected}"
}

reset_hook_arrays() {
	# These arrays are consumed dynamically by the sourced Armbian hook.
	# shellcheck disable=SC2034
	opts_y=()
	# shellcheck disable=SC2034
	opts_m=()
	# shellcheck disable=SC2034
	opts_n=()
	# shellcheck disable=SC2034
	kernel_config_modifying_hashes=()
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kernel-injection-test.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
KERNEL_ROOT="${TEST_ROOT}/linux"

mkdir -p \
	"${KERNEL_ROOT}/net/ipv4" \
	"${KERNEL_ROOT}/net/netfilter" \
	"${KERNEL_ROOT}/drivers/net"
printf 'CONFIG_LSM="lockdown,yama,integrity,apparmor"\n' > "${KERNEL_ROOT}/.config"

cat > "${KERNEL_ROOT}/net/ipv4/tcp.c" <<'LEGACY_TCP_C'
#include <net/tcp.h>
// --- 新增: TCP Brutal 专属宏 ---
#define TCP_BRUTAL_PARAMS 23301
// -------------------------------------------
static int tcp_setsockopt_test(void)
{
	case TCP_BRUTAL_PARAMS: { // --- 新增: TCP Brutal 专属处理分支 ---
		return 0;
	} // -------------------------------------------
}
LEGACY_TCP_C

cat > "${KERNEL_ROOT}/net/ipv4/Kconfig" <<'LEGACY_TCP_KCONFIG'
menu "IPv4"
endmenu

config TCP_CONG_BRUTAL
	tristate "TCP Brutal"
config TCP_AFTER_LEGACY
	bool "Must survive legacy cleanup"
LEGACY_TCP_KCONFIG
cat > "${KERNEL_ROOT}/net/ipv4/Makefile" <<'LEGACY_TCP_MAKEFILE'
obj-y += tcp.o
obj-$(CONFIG_TCP_CONG_BRUTAL) += tcp_brutal.o
LEGACY_TCP_MAKEFILE
touch "${KERNEL_ROOT}/net/ipv4/tcp_brutal.c"

cat > "${KERNEL_ROOT}/drivers/net/Kconfig" <<'DRIVERS_NET_KCONFIG'
menu "Network device support"
endmenu
source "drivers/net/amneziawg/Kconfig"
DRIVERS_NET_KCONFIG
cat > "${KERNEL_ROOT}/drivers/net/Makefile" <<'DRIVERS_NET_MAKEFILE'
obj-y += loopback.o
obj-$(CONFIG_AMNEZIAWG) += amneziawg/
DRIVERS_NET_MAKEFILE
mkdir -p "${KERNEL_ROOT}/drivers/net/amneziawg"
printf 'stale\n' > "${KERNEL_ROOT}/drivers/net/amneziawg/stale.c"

cat > "${KERNEL_ROOT}/net/netfilter/Kconfig" <<'LEGACY_NF_KCONFIG'
menu "Netfilter"
endmenu

config NETFILTER_DEAF
	tristate "Netfilter Deaf Module"
config NF_AFTER_LEGACY
	bool "Must survive legacy cleanup"
LEGACY_NF_KCONFIG
cat > "${KERNEL_ROOT}/net/netfilter/Makefile" <<'LEGACY_NF_MAKEFILE'
obj-y += core.o
obj-$(CONFIG_NETFILTER_DEAF) += nf_deaf.o
LEGACY_NF_MAKEFILE
touch "${KERNEL_ROOT}/net/netfilter/nf_deaf.c"

reset_hook_arrays
original_pwd="$(pwd -P)"
cd "${KERNEL_ROOT}"
# Reproduce Armbian's nounset-unsafe display_alert contract. The injector must
# not turn on nounset while calling framework-owned helpers.
unset ANSI_COLOR
display_alert() {
	: "${ANSI_COLOR}" "$1" "$2" "$3"
}
set +u
custom_kernel_config
set -u
unset -f display_alert
cd "${original_pwd}"

assert_array_contains opts_y BPF_SYSCALL
assert_array_contains opts_y BPF_JIT_ALWAYS_ON
assert_array_contains opts_y DEBUG_INFO_BTF_MODULES
assert_array_contains opts_y CGROUP_BPF
assert_array_contains opts_y BPF_LSM
assert_array_contains opts_y XDP_SOCKETS
assert_array_contains opts_y FUNCTION_TRACER
assert_array_contains opts_m NET_CLS_BPF
assert_array_contains opts_m NET_ACT_BPF
assert_array_contains opts_y MPLS
assert_array_contains opts_m MPLS_ROUTING
assert_array_contains opts_y IPV6_SEG6_LWTUNNEL
assert_array_contains opts_m VXLAN
assert_array_contains opts_m GENEVE
assert_array_contains opts_m NET_IPGRE
assert_array_contains opts_m IPV6_GRE
assert_array_contains opts_m NET_FOU
assert_array_contains opts_y WIREGUARD
assert_array_contains opts_m NFT_TPROXY
assert_array_contains opts_m NFT_SYNPROXY
assert_array_contains opts_m IP6_NF_TARGET_NPT
assert_array_contains opts_m TCP_CONG_BBR
assert_array_contains opts_y BRIDGE
assert_array_contains opts_m BT_BNEP
assert_array_contains opts_y USB_GADGET
assert_array_contains opts_m USB_CONFIGFS
assert_array_contains opts_y USB_CONFIGFS_F_MIDI2
assert_contains "${KERNEL_ROOT}/.config" \
	'CONFIG_LSM="lockdown,yama,integrity,apparmor,bpf"'

# 内核树已定义符号扫描：强制校验依据它把"清单有、本树没有"的符号降级为跳过。
KCONFIG_SCAN_ROOT="${TEST_ROOT}/kconfig-scan"
mkdir -p "${KCONFIG_SCAN_ROOT}"
printf 'config DEBUG_INFO_BTF\n\tbool "btf"\nmenuconfig WIREGUARD\n' > "${KCONFIG_SCAN_ROOT}/Kconfig"
_kernel_inject_load_defined_symbols "${KCONFIG_SCAN_ROOT}"
_kernel_inject_symbol_is_defined DEBUG_INFO_BTF || \
	fail "symbol scanner missed a plain config symbol"
_kernel_inject_symbol_is_defined WIREGUARD || \
	fail "symbol scanner missed a menuconfig symbol"
if _kernel_inject_symbol_is_defined NOT_IN_THIS_TREE; then
	fail "symbol scanner invented a symbol that no Kconfig defines"
fi

# 验证器会扫描"内核树"里 Kconfig 实际定义的符号，所以给最终配置准备一棵
# 合成内核树：Kconfig 覆盖两份清单的全部符号，负向用例才仍然有效。
VERIFY_TREE="${TEST_ROOT}/verify-tree"
mkdir -p "${VERIFY_TREE}"
: > "${VERIFY_TREE}/Kconfig"
for symbol in "${opts_y[@]}" "${opts_m[@]}"; do
	printf 'config %s\n\tbool "synthetic"\n' "${symbol}" >> "${VERIFY_TREE}/Kconfig"
done
printf 'config HAVE_EBPF_JIT\n\tbool "synthetic"\n' >> "${VERIFY_TREE}/Kconfig"
printf 'config DEBUG_INFO_NONE\n\tbool "synthetic"\n' >> "${VERIFY_TREE}/Kconfig"
printf 'config DEBUG_INFO_REDUCED\n\tbool "synthetic"\n' >> "${VERIFY_TREE}/Kconfig"

EFFECTIVE_CONFIG="${VERIFY_TREE}/effective-ebpf.config"
{
	for symbol in "${opts_y[@]}"; do
		printf 'CONFIG_%s=y\n' "${symbol}"
	done
	for symbol in "${opts_m[@]}"; do
		printf 'CONFIG_%s=m\n' "${symbol}"
	done
	printf 'CONFIG_HAVE_EBPF_JIT=y\n'
	printf '# CONFIG_DEBUG_INFO_NONE is not set\n'
	printf '# CONFIG_DEBUG_INFO_REDUCED is not set\n'
	printf 'CONFIG_LSM="lockdown,yama,integrity,apparmor,bpf"\n'
} > "${EFFECTIVE_CONFIG}"
_kernel_inject_verify_full_ebpf_config "${EFFECTIVE_CONFIG}"
_kernel_inject_verify_full_network_config "${EFFECTIVE_CONFIG}"

# 清单里"当前内核树并未定义"的符号必须降级为跳过，而不是让构建失败。
custom_required=(VXLAN A_SYMBOL_NO_KCONFIG_DEFINES)
_kernel_inject_verify_symbol_list "${EFFECTIVE_CONFIG}" '[ym]' custom_required || \
	fail "verifier must skip required symbols that the kernel tree does not define"
if ! printf '%s\n' "${_kernel_inject_skipped_symbols[@]}" | grep -qx A_SYMBOL_NO_KCONFIG_DEFINES; then
	fail "skipped symbols were not recorded for the release notes"
fi

# 由 select/def_bool 决定（Kconfig 里没有 prompt）的符号无法被 scripts/config
# 直接开启：配置里没有记载时必须跳过，一旦有记载就必须按取值严格校验。
SELECT_ONLY_TREE="${TEST_ROOT}/select-only-tree"
mkdir -p "${SELECT_ONLY_TREE}"
printf 'config SELECT_ONLY_SYMBOL\n\ttristate\n' > "${SELECT_ONLY_TREE}/Kconfig"
printf 'config AUTO_SYMBOL\n\ttristate\n' >> "${SELECT_ONLY_TREE}/Kconfig"
cp "${EFFECTIVE_CONFIG}" "${SELECT_ONLY_TREE}/.config"
select_required=(SELECT_ONLY_SYMBOL)
_kernel_inject_verify_symbol_list "${SELECT_ONLY_TREE}/.config" y select_required || \
	fail "verifier must skip prompt-less symbols that the config never materialized"
printf 'CONFIG_AUTO_SYMBOL=m\n' >> "${SELECT_ONLY_TREE}/.config"
auto_required=(AUTO_SYMBOL)
if _kernel_inject_verify_symbol_list "${SELECT_ONLY_TREE}/.config" y auto_required; then
	fail "verifier must still check prompt-less symbols that did materialize"
fi

# 扫描不到任何 Kconfig 时必须退回严格模式（宁可失败也不能静默放过）。
NO_KCONFIG_TREE="${TEST_ROOT}/no-kconfig-tree"
mkdir -p "${NO_KCONFIG_TREE}"
cp "${EFFECTIVE_CONFIG}" "${NO_KCONFIG_TREE}/.config"
sed -i 's/^CONFIG_VXLAN=m$/# CONFIG_VXLAN is not set/' "${NO_KCONFIG_TREE}/.config"
if _kernel_inject_verify_full_network_config "${NO_KCONFIG_TREE}/.config"; then
	fail "verifier must fall back to strict checking when no Kconfig file is present"
fi

sed -i 's/^CONFIG_DEBUG_INFO_BTF=y$/# CONFIG_DEBUG_INFO_BTF is not set/' "${EFFECTIVE_CONFIG}"
if _kernel_inject_verify_full_ebpf_config "${EFFECTIVE_CONFIG}"; then
	fail "eBPF verifier accepted a config without DEBUG_INFO_BTF"
fi
sed -i 's/^# CONFIG_DEBUG_INFO_BTF is not set$/CONFIG_DEBUG_INFO_BTF=y/' "${EFFECTIVE_CONFIG}"

sed -i 's/^CONFIG_VXLAN=m$/# CONFIG_VXLAN is not set/' "${EFFECTIVE_CONFIG}"
if _kernel_inject_verify_full_network_config "${EFFECTIVE_CONFIG}"; then
	fail "network verifier accepted a config without VXLAN"
fi
sed -i 's/^# CONFIG_VXLAN is not set$/CONFIG_VXLAN=m/' "${EFFECTIVE_CONFIG}"

RELEASE_TEST_ROOT="${TEST_ROOT}/release-notes"
RELEASE_METADATA="${RELEASE_TEST_ROOT}/build/output/release-metadata/edge"
RELEASE_DEBS="${RELEASE_TEST_ROOT}/build/output/debs"
mkdir -p "${RELEASE_METADATA}" "${RELEASE_DEBS}"
printf '# 动态构建摘要\n\neBPF 已校验。\n' > "${RELEASE_METADATA}/build-summary.md"
printf 'CONFIG_BPF=y\n' > "${RELEASE_METADATA}/edge-kernel.config"
printf '+BPF y\n' > "${RELEASE_METADATA}/edge-config-vs-arm64-defconfig.txt"
printf 'edge package\n' > \
	"${RELEASE_DEBS}/linux-image-edge-rockchip64_test__7.2.1-build.deb"
printf 'must not upload\n' > \
	"${RELEASE_DEBS}/linux-image-bleedingedge-rockchip64_test__7.2.1-build.deb"
(
	cd "${RELEASE_TEST_ROOT}"
	BUILD_SCRIPT_LIB_ONLY=yes source "${REPO_ROOT}/build.sh"
	resolved_url="$(GITHUB_SERVER_URL=https://github.example \
		GITHUB_REPOSITORY=owner/kernel-build resolve_repository_url "${PWD}")"
	[[ "${resolved_url}" == 'https://github.example/owner/kernel-build.git' ]] || \
		fail "GitHub Actions repository URL fallback is incorrect: ${resolved_url}"
	needs_update "" "6.18.1" || fail "needs_update must trigger on a first release"
	if needs_update "" ""; then fail "needs_update must not trigger without an upstream version"; fi
	if needs_update "6.18.1" "6.18.1"; then fail "needs_update must not trigger on equal versions"; fi
	if needs_update "6.18.2" "6.18.1"; then fail "needs_update must not trigger when released is newer"; fi
	needs_update "6.18.1" "6.18.2" || fail "needs_update must trigger when upstream is newer"
	needs_update "6.18.9" "6.18.10" || fail "needs_update must compare versions numerically"
	kernel_index_fixture='<a href="linux-7.2.tar.xz">base</a>
<a href="linux-7.2.6.tar.xz">old</a>
<a href="linux-7.2.7.tar.xz">latest</a>'
	parsed_kernel_version="$(printf '%s\n' "${kernel_index_fixture}" | \
		parse_kernel_org_index 7.2)"
	[[ "${parsed_kernel_version}" == 7.2.7 ]] || \
		fail "kernel.org index parser returned ${parsed_kernel_version}"
	if printf '%s\n' "${kernel_index_fixture}" | parse_kernel_org_index 7.3 >/dev/null; then
		fail "kernel.org index parser invented an unreleased 7.3 version"
	fi
	CAPTURED_NOTES="${RELEASE_TEST_ROOT}/captured-notes.md"
	CAPTURED_ARGS="${RELEASE_TEST_ROOT}/captured-gh-args.txt"
	gh() {
		local argument
		local notes_next=no
		printf '%s\n' "$@" > "${CAPTURED_ARGS}"
		for argument in "$@"; do
			if [[ "${notes_next}" == yes ]]; then
				cp "${argument}" "${CAPTURED_NOTES}"
				notes_next=no
			elif [[ "${argument}" == --notes-file ]]; then
				notes_next=yes
			fi
		done
	}
	export GITHUB_SHA=0123456789abcdef0123456789abcdef01234567
	upload_to_github_release edge-7.2.1 edge 7.2.1 7.2.0 \
		'./build/output/debs/*-edge-rockchip64_*__7.2.1-*.deb'

	# 版本必须从构建产物反解；日志不得混进捕获的返回值。
	built_version="$(resolve_built_version edge)"
	[[ "${built_version}" == '7.2.1' ]] || \
		fail "resolve_built_version returned '${built_version}' instead of 7.2.1"
	if resolve_built_version current; then
		fail "resolve_built_version invented a version for a branch with no artifact"
	fi
)
assert_contains "${RELEASE_TEST_ROOT}/captured-notes.md" '# 动态构建摘要'
assert_contains "${RELEASE_TEST_ROOT}/captured-notes.md" 'linux-image-edge-rockchip64'
assert_contains "${RELEASE_TEST_ROOT}/captured-notes.md" \
	'0123456789abcdef0123456789abcdef01234567'
assert_contains "${RELEASE_TEST_ROOT}/captured-notes.md" '内核版本（构建产物）：`7.2.1`'
assert_contains "${RELEASE_TEST_ROOT}/captured-notes.md" 'kernel.org 上游版本：`7.2.0`'
assert_not_contains "${RELEASE_TEST_ROOT}/captured-gh-args.txt" 'bleedingedge'
assert_contains "${RELEASE_TEST_ROOT}/captured-gh-args.txt" 'edge-kernel.config'

WRAPPER_ROOT="${TEST_ROOT}/wrapper-root"
mkdir -p "${WRAPPER_ROOT}/userpatches"
cp "${REPO_ROOT}/overwrite/build_with_diy.sh" "${WRAPPER_ROOT}/build_with_diy.sh"
cp "${REPO_ROOT}/userpatches/lib.config" "${WRAPPER_ROOT}/userpatches/lib.config"
cat > "${WRAPPER_ROOT}/compile.sh" <<'FAKE_COMPILE'
#!/usr/bin/env bash
set -Eeuo pipefail
kernel_root="cache/sources/linux-kernel-worktree/6.18__fake__arm64"
mkdir -p "${kernel_root}/net/ipv4/tcp_brutal" \
	"${kernel_root}/drivers/net/amneziawg" \
	"${kernel_root}/net/netfilter/nf_deaf" \
	output/debs
cp "${EFFECTIVE_CONFIG}" "${kernel_root}/.config"
printf 'commit=%s\n' "${TCP_BRUTAL_COMMIT}" \
	> "${kernel_root}/net/ipv4/tcp_brutal/.source-revision"
printf 'commit=%s\n' "${AMNEZIAWG_COMMIT}" \
	> "${kernel_root}/drivers/net/amneziawg/.source-revision"
printf 'commit=%s\n' "${NF_DEAF_COMMIT}" \
	> "${kernel_root}/net/netfilter/nf_deaf/.source-revision"
FAKE_COMPILE
chmod +x "${WRAPPER_ROOT}/compile.sh" "${WRAPPER_ROOT}/build_with_diy.sh"

# The wrapper verifies the built artifact, not just the worktree. A real .deb
# is needed when dpkg-deb is available (CI); a plain placeholder elsewhere.
FAKE_DEB="${WRAPPER_ROOT}/output/debs/linux-image-fake-rockchip64_1.0_arm64__6.18.53-S9a8b-D7c6-P5e4-C3H2.deb"
mkdir -p "${WRAPPER_ROOT}/output/debs"
if command -v dpkg-deb >/dev/null 2>&1; then
	DEB_STAGE="${WRAPPER_ROOT}/deb-stage"
	rm -rf -- "${DEB_STAGE}"
	mkdir -p "${DEB_STAGE}/usr/lib/modules/fake/kernel/net/ipv4/tcp_brutal" \
		"${DEB_STAGE}/usr/lib/modules/fake/kernel/drivers/net/amneziawg" \
		"${DEB_STAGE}/usr/lib/modules/fake/kernel/net/netfilter/nf_deaf" \
		"${DEB_STAGE}/DEBIAN"
	: > "${DEB_STAGE}/usr/lib/modules/fake/kernel/net/ipv4/tcp_brutal/tcp_brutal.ko"
	: > "${DEB_STAGE}/usr/lib/modules/fake/kernel/drivers/net/amneziawg/amneziawg.ko"
	: > "${DEB_STAGE}/usr/lib/modules/fake/kernel/net/netfilter/nf_deaf/nf_deaf.ko"
	cat > "${DEB_STAGE}/DEBIAN/control" <<'CONTROL'
Package: linux-image-fake
Version: 6.18.53-0-fake
Section: kernel
Priority: optional
Architecture: arm64
Maintainer: NNdroid <nn@users.noreply.github.com>
Description: fake modules package for wrapper verification
CONTROL
	dpkg-deb --build "${DEB_STAGE}" "${FAKE_DEB}" >/dev/null
else
	printf 'tcp_brutal amneziawg nf_deaf\n' > "${FAKE_DEB}"
fi

(
	cd "${WRAPPER_ROOT}"
	EFFECTIVE_CONFIG="${EFFECTIVE_CONFIG}" \
	TCP_BRUTAL_COMMIT="${TCP_BRUTAL_COMMIT}" \
	AMNEZIAWG_COMMIT="${AMNEZIAWG_COMMIT}" \
	NF_DEAF_COMMIT="${NF_DEAF_COMMIT}" \
	./build_with_diy.sh kernel BOARD=fake
)
assert_file "${WRAPPER_ROOT}/output/release-metadata/unknown/unknown-kernel.config"
assert_file "${WRAPPER_ROOT}/output/release-metadata/unknown/unknown-config-vs-arm64-defconfig.txt"
assert_contains "${WRAPPER_ROOT}/output/release-metadata/unknown/build-summary.md" \
	'eBPF / BTF / CO-RE'
assert_contains "${WRAPPER_ROOT}/output/release-metadata/unknown/build-summary.md" \
	'完整网络功能集'
assert_contains "${WRAPPER_ROOT}/output/release-metadata/unknown/build-summary.md" \
	'MPLS / SRv6'

sed -i 's/^CONFIG_DEBUG_INFO_BTF=y$/# CONFIG_DEBUG_INFO_BTF is not set/' "${EFFECTIVE_CONFIG}"
if (
	cd "${WRAPPER_ROOT}"
	EFFECTIVE_CONFIG="${EFFECTIVE_CONFIG}" \
	TCP_BRUTAL_COMMIT="${TCP_BRUTAL_COMMIT}" \
	AMNEZIAWG_COMMIT="${AMNEZIAWG_COMMIT}" \
	NF_DEAF_COMMIT="${NF_DEAF_COMMIT}" \
	./build_with_diy.sh kernel BOARD=fake
); then
	fail "build wrapper accepted a final config without DEBUG_INFO_BTF"
fi
sed -i 's/^# CONFIG_DEBUG_INFO_BTF is not set$/CONFIG_DEBUG_INFO_BTF=y/' "${EFFECTIVE_CONFIG}"

# A worktree left behind by another BRANCH shares cache/sources and must not
# satisfy this build just because it carries a .source-revision at all.
MISMATCH_ROOT="${TEST_ROOT}/wrapper-mismatch"
mkdir -p "${MISMATCH_ROOT}/userpatches"
cp "${REPO_ROOT}/overwrite/build_with_diy.sh" "${MISMATCH_ROOT}/build_with_diy.sh"
cp "${REPO_ROOT}/userpatches/lib.config" "${MISMATCH_ROOT}/userpatches/lib.config"
cat > "${MISMATCH_ROOT}/compile.sh" <<'FAKE_COMPILE'
#!/usr/bin/env bash
set -Eeuo pipefail
kernel_root="cache/sources/linux-kernel-worktree/6.18__stale__arm64"
mkdir -p "${kernel_root}/net/ipv4/tcp_brutal" \
	"${kernel_root}/drivers/net/amneziawg" \
	"${kernel_root}/net/netfilter/nf_deaf" output/debs
cp "${EFFECTIVE_CONFIG}" "${kernel_root}/.config"
printf 'commit=0000000000000000000000000000000000000000\n' \
	> "${kernel_root}/net/ipv4/tcp_brutal/.source-revision"
printf 'commit=0000000000000000000000000000000000000000\n' \
	> "${kernel_root}/drivers/net/amneziawg/.source-revision"
printf 'commit=0000000000000000000000000000000000000000\n' \
	> "${kernel_root}/net/netfilter/nf_deaf/.source-revision"
printf 'tcp_brutal amneziawg nf_deaf\n' \
	> output/debs/linux-image-stale-rockchip64_1.0_arm64__6.18.53-S0.deb
FAKE_COMPILE
chmod +x "${MISMATCH_ROOT}/compile.sh" "${MISMATCH_ROOT}/build_with_diy.sh"
if (
	cd "${MISMATCH_ROOT}"
	EFFECTIVE_CONFIG="${EFFECTIVE_CONFIG}" \
	TCP_BRUTAL_COMMIT="${TCP_BRUTAL_COMMIT}" \
	AMNEZIAWG_COMMIT="${AMNEZIAWG_COMMIT}" \
	NF_DEAF_COMMIT="${NF_DEAF_COMMIT}" \
	./build_with_diy.sh kernel BOARD=fake
); then
	fail "build wrapper accepted a worktree whose TCP-Brutal commit is not the pinned one"
fi

# A deb produced for another branch (e.g. a stale artifact from a previous
# build in the same output/debs) must never satisfy this build's BRANCH.
BRANCH_MISMATCH_ROOT="${TEST_ROOT}/wrapper-branch-mismatch"
mkdir -p "${BRANCH_MISMATCH_ROOT}/userpatches"
cp "${REPO_ROOT}/overwrite/build_with_diy.sh" "${BRANCH_MISMATCH_ROOT}/build_with_diy.sh"
cp "${REPO_ROOT}/userpatches/lib.config" "${BRANCH_MISMATCH_ROOT}/userpatches/lib.config"
cat > "${BRANCH_MISMATCH_ROOT}/compile.sh" <<'FAKE_COMPILE'
#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p output/debs
printf 'tcp_brutal amneziawg nf_deaf\n' \
	> output/debs/linux-image-current-rockchip64_1.0_arm64__6.18.53-S0.deb
FAKE_COMPILE
chmod +x "${BRANCH_MISMATCH_ROOT}/compile.sh" "${BRANCH_MISMATCH_ROOT}/build_with_diy.sh"
if (
	cd "${BRANCH_MISMATCH_ROOT}"
	./build_with_diy.sh kernel BOARD=fake BRANCH=bleedingedge
); then
	fail "build wrapper accepted an artifact that belongs to a different branch"
fi

assert_file "${KERNEL_ROOT}/net/ipv4/tcp_brutal/brutal_cc.c"
assert_file "${KERNEL_ROOT}/net/ipv4/tcp_brutal/brutal_sockopt.c"
assert_file "${KERNEL_ROOT}/net/ipv4/tcp_brutal/brutal_rules.c"
assert_file "${KERNEL_ROOT}/net/ipv4/tcp_brutal/brutal.h"
assert_contains "${KERNEL_ROOT}/net/ipv4/tcp_brutal/Makefile" 'BRUTAL_HAVE_TSO_SEGS'
assert_contains "${KERNEL_ROOT}/net/ipv4/tcp_brutal/.source-revision" \
	'commit=fd3e540223c8d22adbed6d1f4fc54caa623d49c0'
assert_absent "${KERNEL_ROOT}/net/ipv4/tcp_brutal.c"
assert_not_contains "${KERNEL_ROOT}/net/ipv4/tcp.c" 'TCP_BRUTAL_PARAMS'
assert_contains "${KERNEL_ROOT}/net/ipv4/Kconfig" 'config TCP_AFTER_LEGACY'

assert_file "${KERNEL_ROOT}/drivers/net/amneziawg/Kbuild"
assert_file "${KERNEL_ROOT}/drivers/net/amneziawg/compat/Kbuild.include"
assert_absent "${KERNEL_ROOT}/drivers/net/amneziawg/stale.c"
assert_contains "${KERNEL_ROOT}/drivers/net/amneziawg/uapi/wireguard.h" \
	'#define WG_GENL_NAME "amneziawg"'
assert_contains "${KERNEL_ROOT}/drivers/net/amneziawg/.source-revision" \
	'commit=85fcc17788ed8afd929e3a4ea02edafeaa1769cc'

assert_file "${KERNEL_ROOT}/net/netfilter/nf_deaf/nf_deaf.c"
assert_file "${KERNEL_ROOT}/net/netfilter/nf_deaf/Kconfig"
assert_absent "${KERNEL_ROOT}/net/netfilter/nf_deaf.c"
assert_contains "${KERNEL_ROOT}/net/netfilter/Kconfig" 'config NF_AFTER_LEGACY'
assert_contains "${KERNEL_ROOT}/net/netfilter/nf_deaf/.source-revision" \
	'commit=d600e9c7f2784137348b3bbe2c94e781177e878d'

assert_count "${KERNEL_ROOT}/net/ipv4/Kconfig" 'BEGIN ARMBIAN-KERNEL-INJECT: TCP_BRUTAL_V2' 1
assert_count "${KERNEL_ROOT}/net/ipv4/Makefile" 'BEGIN ARMBIAN-KERNEL-INJECT: TCP_BRUTAL_V2' 1
assert_count "${KERNEL_ROOT}/drivers/net/Kconfig" 'BEGIN ARMBIAN-KERNEL-INJECT: AMNEZIAWG' 1
assert_count "${KERNEL_ROOT}/drivers/net/Makefile" 'BEGIN ARMBIAN-KERNEL-INJECT: AMNEZIAWG' 1
assert_count "${KERNEL_ROOT}/net/netfilter/Kconfig" 'BEGIN ARMBIAN-KERNEL-INJECT: NF_DEAF' 1
assert_count "${KERNEL_ROOT}/net/netfilter/Makefile" 'BEGIN ARMBIAN-KERNEL-INJECT: NF_DEAF' 1

before="$(sha256sum \
	"${KERNEL_ROOT}/net/ipv4/Kconfig" \
	"${KERNEL_ROOT}/net/ipv4/Makefile" \
	"${KERNEL_ROOT}/drivers/net/Kconfig" \
	"${KERNEL_ROOT}/drivers/net/Makefile" \
	"${KERNEL_ROOT}/net/netfilter/Kconfig" \
	"${KERNEL_ROOT}/net/netfilter/Makefile")"

reset_hook_arrays
cd "${KERNEL_ROOT}"
custom_kernel_config
cd "${original_pwd}"

after="$(sha256sum \
	"${KERNEL_ROOT}/net/ipv4/Kconfig" \
	"${KERNEL_ROOT}/net/ipv4/Makefile" \
	"${KERNEL_ROOT}/drivers/net/Kconfig" \
	"${KERNEL_ROOT}/drivers/net/Makefile" \
	"${KERNEL_ROOT}/net/netfilter/Kconfig" \
	"${KERNEL_ROOT}/net/netfilter/Makefile")"
[[ "${before}" == "${after}" ]] || fail "second injection changed parent Kconfig/Makefiles"

reset_hook_arrays
if AMNEZIAWG_MODE=y WIREGUARD_MODE=y custom_kernel_config; then
	fail "unsafe built-in AmneziaWG/WireGuard combination was accepted"
fi

reset_hook_arrays
if ENABLE_FULL_NETWORKING=invalid custom_kernel_config; then
	fail "invalid ENABLE_FULL_NETWORKING value was accepted"
fi

printf '[PASS] kernel injection is pinned/idempotent; full eBPF and networking are enforced\n'
