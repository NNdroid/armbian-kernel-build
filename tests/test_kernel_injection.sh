#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Load the actual extension entry points; no legacy lib.config is allowed.
# shellcheck disable=SC1091
source "${REPO_ROOT}/userpatches/extensions/kernel-inject-evidence.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/userpatches/extensions/kernel-inject.sh"
[[ ! -e "${REPO_ROOT}/userpatches/lib.config" ]] || {
	printf '[FAIL] unsupported lib.config is still shipped\n' >&2
	exit 1
}
declare -F custom_kernel_config__kernel_inject >/dev/null

declare -F pre_package_kernel_image__kernel_inject_evidence >/dev/null || {
	printf '[FAIL] package evidence extension hook is not defined\n' >&2
	exit 1
}

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

assert_array_not_contains() {
	local array_name="$1"
	local unexpected="$2"
	local item
	local -n values="${array_name}"

	for item in "${values[@]}"; do
		[[ "${item}" != "${unexpected}" ]] || \
			fail "${array_name} unexpectedly contains: ${unexpected}"
	done
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
	# Reset the compatibility-skip report too, otherwise an assertion about it
	# can be satisfied by entries left over from an earlier hook invocation.
	# shellcheck disable=SC2034
	_kernel_inject_skipped_symbols=()
	# shellcheck disable=SC2034
	KERNEL_INJECT_MISSING_SYMBOLS=()
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kernel-injection-test.XXXXXX")"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
KERNEL_ROOT="${TEST_ROOT}/linux"

# Windows (Git Bash) compatibility.
#
# Git for Windows resolves a POSIX absolute path such as /tmp/foo by treating
# the leading slash as the root of the current drive, so the checkout lands in
# C:\tmp\foo instead of the MSYS /tmp mapping. Every git command still exits 0
# and `rev-parse HEAD` returns the pinned SHA, so the injector only notices when
# the required-files check finds an empty work tree. The production build runs
# inside a Linux container and never hits this, so the shim lives here rather
# than in the injector: this keeps the shipped script free of platform branches.
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]] &&
	command -v cygpath > /dev/null 2>&1; then
	_GIT_SHIM_BIN="${TEST_ROOT}/git-shim-bin"
	# Resolve the real git before the shim shadows it on PATH; hardcoding
	# /usr/bin/git would break on Git Bash installations that live elsewhere.
	_GIT_REAL="$(command -v git)"
	mkdir -p "${_GIT_SHIM_BIN}"
	cat > "${_GIT_SHIM_BIN}/git" <<GIT_SHIM
#!/usr/bin/env bash
# Translate only absolute POSIX path arguments; everything else is passed
# through untouched so ordinary repository URLs and refs keep working.
set -e
declare -a translated=()
for argument in "\$@"; do
	case "\${argument}" in
		/*) translated+=("\$(cygpath -m "\${argument}")") ;;
		*) translated+=("\${argument}") ;;
	esac
done
exec ${_GIT_REAL} "\${translated[@]}"
GIT_SHIM
	chmod +x "${_GIT_SHIM_BIN}/git"
	export PATH="${_GIT_SHIM_BIN}:${PATH}"
fi

mkdir -p \
	"${KERNEL_ROOT}/net/ipv4" \
	"${KERNEL_ROOT}/net/netfilter" \
	"${KERNEL_ROOT}/drivers/net"
printf 'CONFIG_LSM="lockdown,yama,integrity,apparmor"\n' > "${KERNEL_ROOT}/.config"

cat > "${KERNEL_ROOT}/net/ipv4/tcp.c" <<'LEGACY_TCP_C'
#include <net/tcp.h>
// --- Added: TCP Brutal-specific macro ---
#define TCP_BRUTAL_PARAMS 23301
// -------------------------------------------
static int tcp_setsockopt_test(void)
{
	case TCP_BRUTAL_PARAMS: { // --- Added: TCP Brutal-specific handling branch ---
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

# Reproduce representative Armbian core-hook requests that run before
# custom_kernel_config. The custom hook must remove conflicting mode requests,
# not merely append another value: Armbian applies opts_n -> opts_y -> opts_m.
opts_m+=(
	NF_CONNTRACK NF_DEFRAG_IPV6 NETFILTER_CONNCOUNT PSAMPLE VLAN_8021Q
	NET_IPGRE_DEMUX NET_IPGRE IPV6_GRE VXLAN GENEVE NF_NAT
	NF_TABLES NF_TABLES_BRIDGE NETFILTER_XTABLES BRIDGE_NF_EBTABLES
	SOUND OPENVSWITCH OPENVSWITCH_GRE OPENVSWITCH_VXLAN OPENVSWITCH_GENEVE
	SND SND_PCM SND_RAWMIDI USB_U_AUDIO USB_F_UAC1 USB_F_UAC2 USB_F_MIDI
	USB_F_MIDI2 USB_AUDIO USB_MIDI_GADGET
)
opts_y+=(BT CFG80211 MAC80211)

original_pwd="$(pwd -P)"
cd "${KERNEL_ROOT}"
# Reproduce Armbian's nounset-unsafe display_alert contract. The injector must
# not turn on nounset while calling framework-owned helpers.
unset ANSI_COLOR
display_alert() {
	: "${ANSI_COLOR}" "$1" "$2" "$3"
}
set +u
custom_kernel_config__kernel_inject
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
assert_array_contains opts_y MPLS_ROUTING
assert_array_contains opts_y IPV6_SEG6_LWTUNNEL
assert_array_contains opts_y VXLAN
assert_array_contains opts_y GENEVE
assert_array_contains opts_y NET_IPGRE
assert_array_contains opts_y IPV6_GRE
assert_array_contains opts_y NET_FOU
assert_array_contains opts_y TCP_CONG_BRUTAL
assert_array_contains opts_y AMNEZIAWG
assert_array_contains opts_y NETFILTER_DEAF
assert_array_contains opts_n WIREGUARD
assert_array_contains opts_y NF_TABLES
assert_array_contains opts_y NFT_TPROXY
assert_array_contains opts_y NFT_SYNPROXY
assert_array_contains opts_y IP6_NF_TARGET_NPT
assert_array_contains opts_y TCP_CONG_BBR
assert_array_contains opts_y NF_CONNTRACK
assert_array_contains opts_y VLAN_8021Q
assert_array_contains opts_y CRYPTO_LIB_CURVE25519
assert_array_contains opts_y CRYPTO_LIB_CHACHA20POLY1305
assert_array_contains opts_y BRIDGE
assert_array_contains opts_m BT
assert_array_contains opts_m BT_RFCOMM
assert_array_contains opts_m BT_BNEP
assert_array_contains opts_m BT_HIDP
assert_array_contains opts_m BT_6LOWPAN
assert_array_contains opts_m RFKILL
assert_array_contains opts_m CFG80211
assert_array_contains opts_m MAC80211
assert_array_contains opts_m MT76_CORE
assert_array_contains opts_m MT76_CONNAC_LIB
assert_array_contains opts_m MT792x_LIB
assert_array_contains opts_m MT7921_COMMON
assert_array_contains opts_m MT7921E
assert_array_contains opts_y PCI
assert_array_contains opts_y FW_LOADER
assert_array_contains opts_y WIRELESS
assert_array_contains opts_y WLAN
assert_array_contains opts_y WLAN_VENDOR_MEDIATEK
assert_array_contains opts_y USB_GADGET
assert_array_contains opts_y USB_CONFIGFS
assert_array_contains opts_y USB_FUNCTIONFS
assert_array_contains opts_y USB_CONFIGFS_F_MIDI2

# The synthetic Armbian core requests above must be fully overridden.
for overridden_builtin in NF_CONNTRACK NF_DEFRAG_IPV6 NETFILTER_CONNCOUNT \
	PSAMPLE VLAN_8021Q SOUND NET_IPGRE_DEMUX NET_IPGRE IPV6_GRE VXLAN \
	GENEVE OPENVSWITCH OPENVSWITCH_GRE OPENVSWITCH_VXLAN OPENVSWITCH_GENEVE \
	NF_NAT NF_TABLES NF_TABLES_BRIDGE NETFILTER_XTABLES BRIDGE_NF_EBTABLES \
	SND SND_PCM SND_RAWMIDI USB_U_AUDIO USB_F_UAC1 USB_F_UAC2 USB_F_MIDI \
	USB_F_MIDI2 USB_AUDIO USB_MIDI_GADGET; do
	assert_array_contains opts_y "${overridden_builtin}"
	assert_array_not_contains opts_m "${overridden_builtin}"
	assert_array_not_contains opts_n "${overridden_builtin}"
done

# Radio stacks deliberately remain modules even if an upstream hook requested y.
for overridden_module in BT CFG80211 MAC80211; do
	assert_array_contains opts_m "${overridden_module}"
	assert_array_not_contains opts_y "${overridden_module}"
	assert_array_not_contains opts_n "${overridden_module}"
done

for builtin_symbol in MPLS_ROUTING VXLAN GENEVE NET_IPGRE IPV6_GRE NET_FOU \
	OPENVSWITCH OPENVSWITCH_GRE OPENVSWITCH_VXLAN OPENVSWITCH_GENEVE \
	NF_TABLES NFT_TPROXY NFT_SYNPROXY IP6_NF_TARGET_NPT TCP_CONG_BBR \
	SOUND SND SND_PCM SND_RAWMIDI USB_U_AUDIO USB_F_UAC1 USB_F_UAC2 \
	USB_F_MIDI USB_F_MIDI2 USB_AUDIO USB_MIDI_GADGET USB_CONFIGFS \
	USB_FUNCTIONFS; do
	assert_array_not_contains opts_m "${builtin_symbol}"
done
assert_contains "${KERNEL_ROOT}/.config" \
	'CONFIG_LSM="lockdown,yama,integrity,apparmor,bpf"'

CURRENT_KERNEL_CONFIG="${REPO_ROOT}/userpatches/config/kernel/linux-rockchip64-current.config"
assert_contains "${CURRENT_KERNEL_CONFIG}" 'CONFIG_TCP_CONG_BRUTAL=y'
assert_contains "${CURRENT_KERNEL_CONFIG}" 'CONFIG_AMNEZIAWG=y'
assert_contains "${CURRENT_KERNEL_CONFIG}" 'CONFIG_NETFILTER_DEAF=y'
assert_contains "${CURRENT_KERNEL_CONFIG}" '# CONFIG_WIREGUARD is not set'
for builtin_config in MPLS_ROUTING VXLAN GENEVE NET_IPGRE IPV6_GRE NET_FOU \
	OPENVSWITCH OPENVSWITCH_GRE OPENVSWITCH_VXLAN OPENVSWITCH_GENEVE \
	NF_CONNTRACK NF_DEFRAG_IPV6 NETFILTER_CONNCOUNT PSAMPLE NF_TABLES \
	NFT_TPROXY NFT_SYNPROXY IP6_NF_TARGET_NPT TCP_CONG_BBR BRIDGE SOUND SND \
	SND_PCM SND_RAWMIDI USB_U_AUDIO USB_F_UAC1 USB_F_UAC2 USB_F_MIDI \
	USB_AUDIO USB_MIDI_GADGET USB_GADGET USB_CONFIGFS USB_FUNCTIONFS PCI \
	FW_LOADER WIRELESS WLAN WLAN_VENDOR_MEDIATEK; do
	assert_contains "${CURRENT_KERNEL_CONFIG}" "CONFIG_${builtin_config}=y"
done
for module_config in 6LOWPAN BT BT_RFCOMM BT_BNEP BT_HIDP BT_6LOWPAN RFKILL \
	CFG80211 MAC80211 MT76_CORE MT76_CONNAC_LIB MT792x_LIB MT7921_COMMON MT7921E; do
	assert_contains "${CURRENT_KERNEL_CONFIG}" "CONFIG_${module_config}=m"
done

# Armbian calls this hook while the compiled source tree and final .config are
# still available. Its evidence must be embedded in the package staging tree,
# because Docker is allowed to discard the source tree after packaging.
mkdir -p "${KERNEL_ROOT}/scripts"
cat > "${KERNEL_ROOT}/Makefile" <<'SYNTHETIC_KERNEL_MAKEFILE'
.PHONY: defconfig kernelrelease
defconfig:
	@mkdir -p "$(O)"
	@printf 'CONFIG_SYNTHETIC_BASELINE=y\n' > "$(O)/.config"
kernelrelease:
	@printf '6.18.53-test\n'
SYNTHETIC_KERNEL_MAKEFILE
cat > "${KERNEL_ROOT}/scripts/diffconfig" <<'SYNTHETIC_DIFFCONFIG'
#!/usr/bin/env bash
diff -u "$1" "$2" || true
SYNTHETIC_DIFFCONFIG
chmod +x "${KERNEL_ROOT}/scripts/diffconfig"
PACKAGE_STAGE="${TEST_ROOT}/package-stage"
mkdir -p "${PACKAGE_STAGE}"
kernel_work_dir="${KERNEL_ROOT}"
package_directory="${PACKAGE_STAGE}"
kernel_version_family="6.18.53-test"
KERNEL_SRC_ARCH="arm64"
ARCH="arm64"
BRANCH="current"
BOARD="fake"
LINUXFAMILY="rockchip64"
LINUXCONFIG="linux-rockchip64-current"
KERNEL_MAJOR_MINOR="6.18"
SRC="${REPO_ROOT}"
WORKDIR="${TEST_ROOT}"
pre_package_kernel_image__kernel_inject_evidence
PACKAGED_EVIDENCE="${PACKAGE_STAGE}/usr/lib/armbian-kernel-build/6.18.53-test"
assert_file "${PACKAGED_EVIDENCE}/kernel.config"
assert_file "${PACKAGED_EVIDENCE}/defined-symbols.txt"
assert_file "${PACKAGED_EVIDENCE}/config-vs-arm64-defconfig.txt"
assert_file "${PACKAGED_EVIDENCE}/arm64-defconfig-build.log"
assert_contains "${PACKAGED_EVIDENCE}/source-manifest.env" 'evidence_format=1'
assert_contains "${PACKAGED_EVIDENCE}/source-manifest.env" \
	'tcp_brutal_commit=d2397ff8bca04a29fd2de01cf7d2d4b825224de8'

KCONFIG_SCAN_ROOT="${TEST_ROOT}/kconfig-scan"
mkdir -p "${KCONFIG_SCAN_ROOT}"
printf 'config DEBUG_INFO_BTF\n\tbool "btf"\nmenuconfig WIREGUARD\nconfig MT792x_LIB\n\ttristate "mt792x"\n' > "${KCONFIG_SCAN_ROOT}/Kconfig"
_kernel_inject_load_defined_symbols "${KCONFIG_SCAN_ROOT}"
_kernel_inject_symbol_is_defined DEBUG_INFO_BTF || \
	fail "symbol scanner missed a plain config symbol"
_kernel_inject_symbol_is_defined WIREGUARD || \
	fail "symbol scanner missed a menuconfig symbol"
_kernel_inject_symbol_is_defined MT792x_LIB || \
	fail "symbol scanner missed a Kconfig symbol containing lowercase characters"
if _kernel_inject_symbol_is_defined NOT_IN_THIS_TREE; then
	fail "symbol scanner invented a symbol that no Kconfig defines"
fi

VERIFY_TREE="${TEST_ROOT}/verify-tree"
mkdir -p "${VERIFY_TREE}"
: > "${VERIFY_TREE}/Kconfig"
# DEBUG_INFO_NONE / DEBUG_INFO_REDUCED are deliberately excluded here. They are
# force-disabled via _kernel_inject_force_mode, so they DO appear in opts_n and a
# naive loop over every opts_* entry would define them in the synthetic tree --
# making the "undefined legacy symbol" compatibility branch unreachable and
# silently voiding the only coverage it has. Newer kernels dropped both symbols.
for symbol in "${opts_y[@]}" "${opts_m[@]}" "${opts_n[@]}"; do
	case "${symbol}" in
		DEBUG_INFO_NONE | DEBUG_INFO_REDUCED) continue ;;
	esac
	printf 'config %s\n\tbool "synthetic"\n' "${symbol}" >> "${VERIFY_TREE}/Kconfig"
done
printf 'config HAVE_EBPF_JIT\n\tbool "synthetic"\n' >> "${VERIFY_TREE}/Kconfig"

EFFECTIVE_CONFIG="${VERIFY_TREE}/effective-ebpf.config"
{
	for symbol in "${opts_y[@]}"; do
		printf 'CONFIG_%s=y\n' "${symbol}"
	done
	for symbol in "${opts_m[@]}"; do
		printf 'CONFIG_%s=m\n' "${symbol}"
	done
	for symbol in "${opts_n[@]}"; do
		printf '# CONFIG_%s is not set\n' "${symbol}"
	done
	printf 'CONFIG_HAVE_EBPF_JIT=y\n'
	printf '# CONFIG_DEBUG_INFO_NONE is not set\n'
	printf '# CONFIG_DEBUG_INFO_REDUCED is not set\n'
	printf 'CONFIG_LSM="lockdown,yama,integrity,apparmor,bpf"\n'
} > "${EFFECTIVE_CONFIG}"
_kernel_inject_verify_full_ebpf_config "${EFFECTIVE_CONFIG}"
_kernel_inject_verify_full_network_config "${EFFECTIVE_CONFIG}"

# The undefined legacy debug symbols must be skipped rather than treated as a
# missing capability, and they must be reported so release notes can disclose it.
for legacy_symbol in DEBUG_INFO_NONE DEBUG_INFO_REDUCED; do
	printf '%s\n' "${_kernel_inject_skipped_symbols[@]:-}" | \
		grep -qx "${legacy_symbol}" || \
		fail "undefined legacy symbol ${legacy_symbol} was not recorded in _kernel_inject_skipped_symbols"
done
printf '%s\n' "${_kernel_inject_skipped_symbols[@]}" | \
	grep -qx DEBUG_INFO_NONE || \
	fail "skipping an undefined legacy symbol did not log a compatibility warning"

# Reverse direction: once the tree DOES define a legacy debug symbol it must be
# checked for real, and a config that leaves it enabled must fail. This guards
# against "fixing" the missing coverage by skipping unconditionally. The two
# symbols are excluded from the bulk loop and declared explicitly below so each
# Kconfig block appears exactly once.
LEGACY_TREE="${TEST_ROOT}/legacy-tree"
mkdir -p "${LEGACY_TREE}"
: > "${LEGACY_TREE}/Kconfig"
for symbol in "${opts_y[@]}" "${opts_m[@]}" "${opts_n[@]}"; do
	case "${symbol}" in
		DEBUG_INFO_NONE | DEBUG_INFO_REDUCED) continue ;;
	esac
	printf 'config %s\n\tbool "synthetic"\n' "${symbol}" >> "${LEGACY_TREE}/Kconfig"
done
printf 'config HAVE_EBPF_JIT\n\tbool "synthetic"\n' >> "${LEGACY_TREE}/Kconfig"
printf 'config DEBUG_INFO_NONE\n\tbool "synthetic"\n' >> "${LEGACY_TREE}/Kconfig"
printf 'config DEBUG_INFO_REDUCED\n\tbool "synthetic"\n' >> "${LEGACY_TREE}/Kconfig"
LEGACY_CONFIG="${LEGACY_TREE}/effective.config"
cp -- "${EFFECTIVE_CONFIG}" "${LEGACY_CONFIG}"
sed -i 's/^# CONFIG_DEBUG_INFO_NONE is not set$/CONFIG_DEBUG_INFO_NONE=y/' "${LEGACY_CONFIG}"
reset_hook_arrays
if _kernel_inject_verify_full_ebpf_config "${LEGACY_CONFIG}"; then
	fail "ebpf verifier accepted CONFIG_DEBUG_INFO_NONE=y when the tree defines it"
fi
if printf '%s\n' "${_kernel_inject_skipped_symbols[@]:-}" | grep -qx DEBUG_INFO_NONE; then
	fail "a defined legacy debug symbol must not be reported as skipped"
fi
# Restore the negative check and confirm the tree-defined case passes cleanly.
sed -i 's/^CONFIG_DEBUG_INFO_NONE=y$/# CONFIG_DEBUG_INFO_NONE is not set/' "${LEGACY_CONFIG}"
reset_hook_arrays
_kernel_inject_verify_full_ebpf_config "${LEGACY_CONFIG}"
# Point the symbol inventory back at the undefined-symbol tree for the checks below.
reset_hook_arrays
_kernel_inject_load_defined_symbols "${VERIFY_TREE}" || fail "symbol rescan failed"

# Complete networking is a built-in contract: a feature that survives merely
# as a loadable module must be rejected before a release is uploaded.
sed -i 's/^CONFIG_VXLAN=y$/CONFIG_VXLAN=m/' "${EFFECTIVE_CONFIG}"
if _kernel_inject_verify_full_network_config "${EFFECTIVE_CONFIG}"; then
	fail "network verifier accepted CONFIG_VXLAN=m for an all-built-in release"
fi
printf '%s\n' "${KERNEL_INJECT_MISSING_SYMBOLS[@]}" | \
	grep -q 'CONFIG_VXLAN=y(actual=m)' || \
	fail "built-in verifier did not report CONFIG_VXLAN=m precisely"
sed -i 's/^CONFIG_VXLAN=m$/CONFIG_VXLAN=y/' "${EFFECTIVE_CONFIG}"

sed -i 's/^CONFIG_MT7921E=m$/CONFIG_MT7921E=y/' "${EFFECTIVE_CONFIG}"
if _kernel_inject_verify_full_network_config "${EFFECTIVE_CONFIG}"; then
	fail "network verifier accepted built-in MT7921E instead of module mode"
fi
printf '%s\n' "${KERNEL_INJECT_MISSING_SYMBOLS[@]}" | \
	grep -q 'CONFIG_MT7921E=m(actual=y)' || \
	fail "module verifier did not report built-in MT7921E precisely"
sed -i 's/^CONFIG_MT7921E=y$/CONFIG_MT7921E=m/' "${EFFECTIVE_CONFIG}"

# Strict-y diagnostics must identify the actual module value instead of
# claiming that an enabled symbol is simply missing.
# shellcheck disable=SC2034
strict_builtin=(NF_CONNTRACK)
sed -i 's/^CONFIG_NF_CONNTRACK=y$/CONFIG_NF_CONNTRACK=m/' "${EFFECTIVE_CONFIG}"
if _kernel_inject_verify_symbol_list "${EFFECTIVE_CONFIG}" y strict_builtin; then
	fail "strict-y verifier accepted NF_CONNTRACK=m"
fi
printf '%s\n' "${KERNEL_INJECT_MISSING_SYMBOLS[@]}" | \
	grep -q 'CONFIG_NF_CONNTRACK=y(actual=m)' || \
	fail "strict-y verifier did not report the actual module value"
sed -i 's/^CONFIG_NF_CONNTRACK=m$/CONFIG_NF_CONNTRACK=y/' "${EFFECTIVE_CONFIG}"

# Consumed through a nameref in _kernel_inject_verify_symbol_list.
# shellcheck disable=SC2034
custom_required=(VXLAN A_SYMBOL_NO_KCONFIG_DEFINES)
if _kernel_inject_verify_symbol_list "${EFFECTIVE_CONFIG}" '[ym]' custom_required; then
	fail "verifier accepted a required symbol that the kernel tree does not define"
fi
printf '%s\n' "${KERNEL_INJECT_MISSING_SYMBOLS[@]}" | \
	grep -q 'A_SYMBOL_NO_KCONFIG_DEFINES.*undefined' || \
	fail "undefined required symbol was not reported precisely"

SELECT_ONLY_TREE="${TEST_ROOT}/select-only-tree"
mkdir -p "${SELECT_ONLY_TREE}"
printf 'config SELECT_ONLY_SYMBOL\n\ttristate\n' > "${SELECT_ONLY_TREE}/Kconfig"
cp "${EFFECTIVE_CONFIG}" "${SELECT_ONLY_TREE}/.config"
# Consumed through a nameref in _kernel_inject_verify_symbol_list.
# shellcheck disable=SC2034
select_required=(SELECT_ONLY_SYMBOL)
if _kernel_inject_verify_symbol_list "${SELECT_ONLY_TREE}/.config" y select_required; then
	fail "verifier accepted a missing prompt-less symbol"
fi
printf 'CONFIG_SELECT_ONLY_SYMBOL=y\n' >> "${SELECT_ONLY_TREE}/.config"
_kernel_inject_verify_symbol_list "${SELECT_ONLY_TREE}/.config" y select_required || \
	fail "verifier rejected a satisfied prompt-less symbol"

NO_KCONFIG_TREE="${TEST_ROOT}/no-kconfig-tree"
mkdir -p "${NO_KCONFIG_TREE}"
cp "${EFFECTIVE_CONFIG}" "${NO_KCONFIG_TREE}/.config"
sed -i 's/^CONFIG_VXLAN=y$/# CONFIG_VXLAN is not set/' "${NO_KCONFIG_TREE}/.config"
if _kernel_inject_verify_full_network_config "${NO_KCONFIG_TREE}/.config"; then
	fail "verifier must fall back to strict checking when no Kconfig file is present"
fi

sed -i 's/^CONFIG_DEBUG_INFO_BTF=y$/# CONFIG_DEBUG_INFO_BTF is not set/' "${EFFECTIVE_CONFIG}"
if _kernel_inject_verify_full_ebpf_config "${EFFECTIVE_CONFIG}"; then
	fail "eBPF verifier accepted a config without DEBUG_INFO_BTF"
fi
sed -i 's/^# CONFIG_DEBUG_INFO_BTF is not set$/CONFIG_DEBUG_INFO_BTF=y/' "${EFFECTIVE_CONFIG}"

sed -i 's/^CONFIG_VXLAN=y$/# CONFIG_VXLAN is not set/' "${EFFECTIVE_CONFIG}"
if _kernel_inject_verify_full_network_config "${EFFECTIVE_CONFIG}"; then
	fail "network verifier accepted a config without VXLAN"
fi
sed -i 's/^# CONFIG_VXLAN is not set$/CONFIG_VXLAN=y/' "${EFFECTIVE_CONFIG}"

RELEASE_TEST_ROOT="${TEST_ROOT}/release-notes"
RELEASE_METADATA="${RELEASE_TEST_ROOT}/build/output/release-metadata/edge"
RELEASE_DEBS="${RELEASE_TEST_ROOT}/build/output/debs"
mkdir -p "${RELEASE_METADATA}" "${RELEASE_DEBS}"
printf '# Dynamic build summary\n\neBPF validated.\n' > "${RELEASE_METADATA}/build-summary.md"
printf 'CONFIG_BPF=y\n' > "${RELEASE_METADATA}/edge-kernel.config"
printf 'evidence_format=1\nbranch=edge\n' > \
	"${RELEASE_METADATA}/edge-source-manifest.env"
printf '+BPF y\n' > "${RELEASE_METADATA}/edge-config-vs-arm64-defconfig.txt"
printf 'synthetic defconfig diagnostic\n' > "${RELEASE_METADATA}/arm64-defconfig-build.log"
printf 'synthetic module\n' > \
	"${RELEASE_METADATA}/edge-7.2.1-rockchip64-arm64-brutal.ko.zst"
printf 'module installation guide\n' > \
	"${RELEASE_METADATA}/edge-loadable-modules.md"
printf 'deadbeef  edge-7.2.1-rockchip64-arm64-brutal.ko.zst\n' > \
	"${RELEASE_METADATA}/edge-loadable-modules-SHA256SUMS"
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
	CAPTURED_LOG="${RELEASE_TEST_ROOT}/captured-gh-log.txt"
	# The publish path has three outcomes: create succeeds, create fails but the
	# release already exists (edit + upload --clobber), and create fails with no
	# existing release. A mock that always succeeds leaves the last two untested
	# even though the second one is the "half-finished release" risk: edit
	# publishes the notes before upload can fail.
	GH_MODE=create_ok
	: > "${CAPTURED_LOG}"
	gh() {
		local argument subcommand="${1:-} ${2:-}"
		local notes_next=no
		# Append, never truncate. The publish path issues several separate gh
		# invocations (create, or view + edit + upload on recovery, then view on
		# the dead end), and each assertion below is about the run as a whole:
		# a per-call overwrite would leave the transcript holding only the last
		# invocation, which is a bare `release view` with no files attached.
		printf '%s\n' "$@" >> "${CAPTURED_LOG}"
		printf '%s\n' "$@" >> "${CAPTURED_ARGS}"
		case "${GH_MODE}:${subcommand}" in
			create_fails:release\ create) return 1 ;;
			view_fails:release\ create) return 1 ;;
			view_fails:release\ view) return 1 ;;
		esac
		for argument in "$@"; do
			if [[ "${notes_next}" == yes ]]; then
				cp "${argument}" "${CAPTURED_NOTES}"
				notes_next=no
			elif [[ "${argument}" == --notes-file ]]; then
				notes_next=yes
			fi
		done
	}
	# Start each scenario from an empty transcript.
	reset_gh_log() { : > "${CAPTURED_LOG}"; : > "${CAPTURED_ARGS}"; }
	reset_gh_log
	export GITHUB_SHA=0123456789abcdef0123456789abcdef01234567
	upload_to_github_release edge-7.2.1 edge 7.2.1 7.2.0 \
		'./build/output/debs/*-edge-rockchip64_*__7.2.1-*.deb'

	# Recovery path: create fails, the release exists, notes are updated and every
	# asset is re-uploaded with --clobber.
	reset_gh_log
	GH_MODE=create_fails
	if ! upload_to_github_release edge-7.2.1 edge 7.2.1 7.2.0 \
		'./build/output/debs/*-edge-rockchip64_*__7.2.1-*.deb'; then
		fail "publishing must recover when the release already exists"
	fi
	[[ "$(grep -c '^release$' "${CAPTURED_LOG}")" -ge 1 ]] || \
		fail "recovery path did not retry 'gh release view'"
	grep -q -- '--clobber' "${CAPTURED_LOG}" || \
		fail "recovery path did not replace existing assets with --clobber"
	grep -q -- '--notes-file' "${CAPTURED_LOG}" || \
		fail "recovery path did not update the release notes"

	# Dead end: create fails and no release exists, so there is nothing to update.
	reset_gh_log
	GH_MODE=view_fails
	if upload_to_github_release edge-7.2.1 edge 7.2.1 7.2.0 \
		'./build/output/debs/*-edge-rockchip64_*__7.2.1-*.deb' 2>/dev/null; then
		fail "publishing must fail when the release cannot be created or found"
	fi
	if grep -q 'upload' "${CAPTURED_LOG}"; then
		fail "dead-end path must not attempt to upload assets to a missing release"
	fi
	GH_MODE=create_ok

	built_version="$(resolve_built_version edge)"
	[[ "${built_version}" == '7.2.1' ]] || \
		fail "resolve_built_version returned '${built_version}' instead of 7.2.1"
	if resolve_built_version current; then
		fail "resolve_built_version invented a version for a branch with no artifact"
	fi
	# Inside the sandboxed fixture root, not ./build: the EXIT trap only cleans
	# TEST_ROOT, so a marker created in the working tree would survive the run and
	# show up as untracked noise in git status.
	BUILD_MARKER="$(mktemp "${RELEASE_TEST_ROOT}/resolve-marker.XXXXXX")"
	if resolve_built_version edge "${BUILD_MARKER}"; then
		fail "resolve_built_version accepted a stale artifact from before this build"
	fi
	sleep 1
	touch "${RELEASE_DEBS}/linux-image-edge-rockchip64_test__7.2.1-build.deb"
	built_version="$(resolve_built_version edge "${BUILD_MARKER}")"
	[[ "${built_version}" == '7.2.1' ]] || \
		fail "fresh artifact resolution returned '${built_version}'"

	CWD_TEST_ROOT="${RELEASE_TEST_ROOT}/cwd-test"
	mkdir -p "${CWD_TEST_ROOT}/build"
	cat > "${CWD_TEST_ROOT}/build/build_with_diy.sh" <<'CWD_WRAPPER'
#!/usr/bin/env bash
pwd -P > ../wrapper-cwd.txt
CWD_WRAPPER
	chmod +x "${CWD_TEST_ROOT}/build/build_with_diy.sh"
	run_armbian_build "${CWD_TEST_ROOT}/build" kernel BOARD=fake
	[[ "$(cat "${CWD_TEST_ROOT}/wrapper-cwd.txt")" == "$(cd "${CWD_TEST_ROOT}/build" && pwd -P)" ]] || \
		fail "run_armbian_build did not execute the wrapper from the Armbian root"
)
assert_contains "${RELEASE_TEST_ROOT}/captured-notes.md" '# Dynamic build summary'
assert_contains "${RELEASE_TEST_ROOT}/captured-notes.md" 'linux-image-edge-rockchip64'
assert_contains "${RELEASE_TEST_ROOT}/captured-notes.md" \
	'0123456789abcdef0123456789abcdef01234567'
assert_contains "${RELEASE_TEST_ROOT}/captured-notes.md" 'Kernel version (artifact): `7.2.1`'
assert_contains "${RELEASE_TEST_ROOT}/captured-notes.md" 'kernel.org upstream version: `7.2.0`'
assert_not_contains "${RELEASE_TEST_ROOT}/captured-gh-args.txt" 'bleedingedge'
assert_contains "${RELEASE_TEST_ROOT}/captured-gh-args.txt" 'edge-kernel.config'
assert_contains "${RELEASE_TEST_ROOT}/captured-gh-args.txt" 'edge-source-manifest.env'
assert_contains "${RELEASE_TEST_ROOT}/captured-gh-args.txt" 'arm64-defconfig-build.log'
assert_contains "${RELEASE_TEST_ROOT}/captured-gh-args.txt" \
	'edge-7.2.1-rockchip64-arm64-brutal.ko.zst'
assert_contains "${RELEASE_TEST_ROOT}/captured-gh-args.txt" 'edge-loadable-modules.md'
assert_contains "${RELEASE_TEST_ROOT}/captured-gh-args.txt" \
	'edge-loadable-modules-SHA256SUMS'

WRAPPER_ROOT="${TEST_ROOT}/wrapper-root"
mkdir -p "${WRAPPER_ROOT}/userpatches/extensions"
cp "${REPO_ROOT}/overwrite/build_with_diy.sh" "${WRAPPER_ROOT}/build_with_diy.sh"
cp -R "${REPO_ROOT}/overwrite/lib" "${WRAPPER_ROOT}/lib"
cp "${REPO_ROOT}/userpatches/extensions/kernel-inject.sh" "${WRAPPER_ROOT}/userpatches/extensions/kernel-inject.sh"

# Git Bash on Windows has no dpkg-deb. Use an uncompressed tar as the fake deb
# payload so package listing, field lookup and extraction exercise the same
# wrapper paths as a real Debian package.
if ! command -v dpkg-deb >/dev/null 2>&1; then
	FAKE_DPKG_BIN="${TEST_ROOT}/fake-dpkg-bin"
	mkdir -p "${FAKE_DPKG_BIN}"
	cat > "${FAKE_DPKG_BIN}/dpkg-deb" <<'FAKE_DPKG_DEB'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1" in
	--build)
		stage="$2"
		destination="$3"
		tar -C "${stage}" -cf "${destination}" .
		;;
	-c)
		tar -tf "$2" | sed 's#^#-rw-r--r-- root/root 0 #'
		;;
	-x)
		mkdir -p "$3"
		tar -C "$3" -xf "$2"
		;;
	-f)
		field="$3"
		tar -xOf "$2" ./DEBIAN/control | awk -F': ' -v field="${field}" '$1 == field { print substr($0, length($1) + 3); exit }'
		;;
	*) exit 2 ;;
esac
FAKE_DPKG_DEB
	chmod +x "${FAKE_DPKG_BIN}/dpkg-deb"
	export PATH="${FAKE_DPKG_BIN}:${PATH}"
fi

# Every package case below stages its payload through dpkg-deb, so from here on a
# resolvable dpkg-deb is a precondition rather than a nicety: the block above
# guarantees it, either from the platform or from the shim. Stop loudly if it
# somehow does not hold. Silently continuing would run the packaging assertions
# against a stale .deb and report a pass that tested nothing.
command -v dpkg-deb >/dev/null 2>&1 \
	|| fail "dpkg-deb is unresolvable after the shim block; the packaging cases cannot run"

cat > "${WRAPPER_ROOT}/compile.sh" <<'FAKE_COMPILE'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "${ENABLE_EXTENSIONS:-}" > enabled-extensions.txt
printf '%s\n' "$@" > compile-arguments.txt
mkdir -p output/debs
cp "${FAKE_IMAGE_DEB_SOURCE}" \
	output/debs/linux-image-fake-rockchip64_1.0_arm64__6.18.53-S9a8b-D7c6-P5e4-C3H2.deb
FAKE_COMPILE
chmod +x "${WRAPPER_ROOT}/compile.sh" "${WRAPPER_ROOT}/build_with_diy.sh"

# The wrapper verifies the durable package and does not require a surviving
# kernel worktree. CI builds a real .deb; the Git Bash shim builds a tar-backed
# package with the same module, control-field and evidence layout.
FAKE_DEB_TEMPLATE="${WRAPPER_ROOT}/fake-linux-image.deb"
mkdir -p "${WRAPPER_ROOT}/output/debs"
DEB_STAGE="${WRAPPER_ROOT}/deb-stage"
DEB_EVIDENCE="${DEB_STAGE}/usr/lib/armbian-kernel-build/6.18.53-fake"
rm -rf -- "${DEB_STAGE}"
mkdir -p "${DEB_STAGE}/usr/lib/modules/fake" \
	"${DEB_EVIDENCE}" "${DEB_STAGE}/DEBIAN"
cat > "${DEB_STAGE}/usr/lib/modules/fake/modules.builtin" <<'BUILTIN_MODULES'
kernel/net/ipv4/tcp_brutal/brutal.ko
kernel/drivers/net/amneziawg/amneziawg.ko
kernel/net/netfilter/nf_deaf/nf_deaf.ko
BUILTIN_MODULES
FAKE_RADIO_MODULE_DIR="${DEB_STAGE}/usr/lib/modules/fake/kernel/radio"
mkdir -p "${FAKE_RADIO_MODULE_DIR}"
for radio_module in 6lowpan bluetooth rfcomm bnep hidp bluetooth_6lowpan \
	rfkill cfg80211 mac80211 mt76 mt76-connac-lib mt792x-lib \
	mt7921-common mt7921e; do
	printf 'synthetic %s module\n' "${radio_module}" > \
		"${FAKE_RADIO_MODULE_DIR}/${radio_module}.ko"
done
cp "${EFFECTIVE_CONFIG}" "${DEB_EVIDENCE}/kernel.config"
awk '/^(config|menuconfig) / { print $2 }' "${VERIFY_TREE}/Kconfig" | sort -u \
	> "${DEB_EVIDENCE}/defined-symbols.txt"
printf '+BPF y\n' > "${DEB_EVIDENCE}/config-vs-arm64-defconfig.txt"
printf 'synthetic arm64 defconfig build\n' > "${DEB_EVIDENCE}/arm64-defconfig-build.log"
cat > "${DEB_STAGE}/DEBIAN/control" <<'CONTROL'
Package: linux-image-fake
Version: 6.18.53-0-fake
Section: kernel
Priority: optional
Architecture: arm64
Maintainer: NNdroid <nn@users.noreply.github.com>
Description: fake modules package for wrapper verification
CONTROL

write_fake_evidence_manifest() {
	local tcp_commit="${1:-${TCP_BRUTAL_COMMIT}}"
	local config_sha256
	config_sha256="$(sha256sum "${DEB_EVIDENCE}/kernel.config" | awk '{print $1}')"
	cat > "${DEB_EVIDENCE}/source-manifest.env" <<EOF
evidence_format=1
branch=fake
board=fake
linuxfamily=rockchip64
debian_arch=arm64
kbuild_arch=arm64
linuxconfig=linux-rockchip64-fake
kernel_major_minor=6.18
kernel_release=6.18.53-fake
armbian_build_commit=0123456789abcdef0123456789abcdef01234567
kernel_source_commit=1111111111111111111111111111111111111111
tcp_brutal_commit=${tcp_commit}
amneziawg_commit=${AMNEZIAWG_COMMIT}
nf_deaf_commit=${NF_DEAF_COMMIT}
config_sha256=${config_sha256}
baseline_status=generated
diff_count=1
EOF
}

build_fake_image_deb() {
	write_fake_evidence_manifest "${1:-${TCP_BRUTAL_COMMIT}}"
	dpkg-deb --build "${DEB_STAGE}" "${FAKE_DEB_TEMPLATE}" >/dev/null
}

build_fake_image_deb

(
	cd "${WRAPPER_ROOT}"
	EFFECTIVE_CONFIG="${EFFECTIVE_CONFIG}" \
	FAKE_IMAGE_DEB_SOURCE="${FAKE_DEB_TEMPLATE}" \
	TCP_BRUTAL_COMMIT="${TCP_BRUTAL_COMMIT}" \
	AMNEZIAWG_COMMIT="${AMNEZIAWG_COMMIT}" \
	NF_DEAF_COMMIT="${NF_DEAF_COMMIT}" \
	./build_with_diy.sh kernel BOARD=fake \
		ENABLE_EXTENSIONS=sample-one,kernel-inject-evidence,sample-two
)
assert_contains "${WRAPPER_ROOT}/enabled-extensions.txt" \
	'sample-one,kernel-inject-evidence,sample-two,kernel-inject'
assert_contains "${WRAPPER_ROOT}/compile-arguments.txt" \
	'ENABLE_EXTENSIONS=sample-one,kernel-inject-evidence,sample-two,kernel-inject'

# Reused checkouts may retain ignored legacy configuration. Do not execute or
# remove it; fail before compile.sh, with an actionable migration diagnostic.
printf '# local customization\n' > "${WRAPPER_ROOT}/userpatches/lib.config"
cp "${WRAPPER_ROOT}/compile-arguments.txt" "${WRAPPER_ROOT}/before-legacy.txt"
if (cd "${WRAPPER_ROOT}"; ./build_with_diy.sh kernel BOARD=fake) >"${WRAPPER_ROOT}/legacy.log" 2>&1; then
	fail "wrapper accepted an unsupported legacy lib.config"
fi
assert_contains "${WRAPPER_ROOT}/legacy.log" 'Obsolete userpatches/lib.config detected'
assert_contains "${WRAPPER_ROOT}/userpatches/lib.config" '# local customization'
cmp "${WRAPPER_ROOT}/compile-arguments.txt" "${WRAPPER_ROOT}/before-legacy.txt" || fail "legacy check ran compile.sh"
rm -- "${WRAPPER_ROOT}/userpatches/lib.config"
assert_file "${WRAPPER_ROOT}/output/release-metadata/fake/fake-kernel.config"
assert_file "${WRAPPER_ROOT}/output/release-metadata/fake/fake-source-manifest.env"
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/fake-source-manifest.env" \
	"tcp_brutal_commit=${TCP_BRUTAL_COMMIT}"
assert_file "${WRAPPER_ROOT}/output/release-metadata/fake/fake-config-vs-arm64-defconfig.txt"
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/build-summary.md" \
	'eBPF / BTF / CO-RE'
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/build-summary.md" \
	'Full networking feature set'
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/build-summary.md" \
	'MPLS / SRv6'
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/build-summary.md" \
	'Armbian/build baseline commit'
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/build-summary.md" \
	'Kernel source baseline commit'
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/build-summary.md" \
	'| TCP-Brutal v2 | `y` |'
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/build-summary.md" \
	'| AmneziaWG | `y` |'
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/build-summary.md" \
	'| nf_deaf | `y` |'
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/build-summary.md" \
	'| Native WireGuard (replaced by AmneziaWG by default) | `n` |'
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/build-summary.md" \
	'`MT7921E=m`'
assert_file \
	"${WRAPPER_ROOT}/output/release-metadata/fake/fake-6.18.53-fake-arm64-mt7921e.ko"
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/fake-loadable-modules.md" \
	'MediaTek MT7921E PCIe'
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/fake-loadable-modules.md" \
	'linux-firmware'

# A component whose final packaged config is =m must be exported as the exact
# .ko payload from that package, with checksums and kernel/architecture-bound
# installation instructions. Restore the built-in fixture afterwards so the
# following negative built-in inventory checks retain their original scope.
MODULAR_BRUTAL_DIR="${DEB_STAGE}/usr/lib/modules/fake/kernel/net/ipv4/tcp_brutal"
mkdir -p "${MODULAR_BRUTAL_DIR}"
printf 'synthetic brutal module\n' > "${MODULAR_BRUTAL_DIR}/brutal.ko"
sed -i 's/^CONFIG_TCP_CONG_BRUTAL=y$/CONFIG_TCP_CONG_BRUTAL=m/' \
	"${DEB_EVIDENCE}/kernel.config"
sed -i '\#/brutal\.ko$#d' "${DEB_STAGE}/usr/lib/modules/fake/modules.builtin"
build_fake_image_deb
(
	cd "${WRAPPER_ROOT}"
	FAKE_IMAGE_DEB_SOURCE="${FAKE_DEB_TEMPLATE}" \
	TCP_BRUTAL_MODE=m \
	TCP_BRUTAL_COMMIT="${TCP_BRUTAL_COMMIT}" \
	AMNEZIAWG_COMMIT="${AMNEZIAWG_COMMIT}" \
	NF_DEAF_COMMIT="${NF_DEAF_COMMIT}" \
	./build_with_diy.sh kernel BOARD=fake
)
MODULAR_ASSET="${WRAPPER_ROOT}/output/release-metadata/fake/fake-6.18.53-fake-arm64-brutal.ko"
assert_file "${MODULAR_ASSET}"
assert_contains "${MODULAR_ASSET}" 'synthetic brutal module'
assert_file "${WRAPPER_ROOT}/output/release-metadata/fake/fake-loadable-modules.md"
assert_file "${WRAPPER_ROOT}/output/release-metadata/fake/fake-loadable-modules-SHA256SUMS"
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/fake-loadable-modules.md" \
	'CONFIG_TCP_CONG_BRUTAL=m'
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/fake-loadable-modules.md" \
	'sudo modprobe brutal'
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/fake-loadable-modules.md" \
	'sha256sum -c fake-loadable-modules-SHA256SUMS'
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/fake-loadable-modules.md" \
	'sudo install -m 0644 ./fake-6.18.53-fake-arm64-brutal.ko "/lib/modules/${KERNEL_RELEASE}/extra/brutal.ko"'
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/build-summary.md" \
	'Install standalone module attachments only'
assert_contains "${WRAPPER_ROOT}/output/release-metadata/fake/fake-loadable-modules-SHA256SUMS" \
	'fake-6.18.53-fake-arm64-brutal.ko'
(
	cd "${WRAPPER_ROOT}/output/release-metadata/fake"
	sha256sum -c fake-loadable-modules-SHA256SUMS >/dev/null
)

sed -i 's/^CONFIG_TCP_CONG_BRUTAL=m$/CONFIG_TCP_CONG_BRUTAL=y/' \
	"${DEB_EVIDENCE}/kernel.config"
printf 'kernel/net/ipv4/tcp_brutal/brutal.ko\n' >> \
	"${DEB_STAGE}/usr/lib/modules/fake/modules.builtin"
rm -rf -- "${MODULAR_BRUTAL_DIR}"
build_fake_image_deb

# TCP-Brutal v2's built-in inventory name is brutal.ko. An inventory containing
# only the old tcp_brutal.ko name must not pass merely because its directory
# contains the text "tcp_brutal". Unconditional: dpkg-deb is a precondition
# established above, so there is no environment in which this case is dropped.
sed -i 's#/brutal\.ko$#/tcp_brutal.ko#' \
	"${DEB_STAGE}/usr/lib/modules/fake/modules.builtin"
build_fake_image_deb
if (
	cd "${WRAPPER_ROOT}"
	EFFECTIVE_CONFIG="${EFFECTIVE_CONFIG}" \
	FAKE_IMAGE_DEB_SOURCE="${FAKE_DEB_TEMPLATE}" \
	TCP_BRUTAL_COMMIT="${TCP_BRUTAL_COMMIT}" \
	AMNEZIAWG_COMMIT="${AMNEZIAWG_COMMIT}" \
	NF_DEAF_COMMIT="${NF_DEAF_COMMIT}" \
	./build_with_diy.sh kernel BOARD=fake
); then
	fail "build wrapper accepted tcp_brutal.ko instead of built-in TCP-Brutal v2 brutal.ko"
fi
sed -i 's#/tcp_brutal\.ko$#/brutal.ko#' \
	"${DEB_STAGE}/usr/lib/modules/fake/modules.builtin"
build_fake_image_deb

sed -i 's/^CONFIG_DEBUG_INFO_BTF=y$/# CONFIG_DEBUG_INFO_BTF is not set/' \
	"${DEB_EVIDENCE}/kernel.config"
build_fake_image_deb
if (
	cd "${WRAPPER_ROOT}"
	FAKE_IMAGE_DEB_SOURCE="${FAKE_DEB_TEMPLATE}" \
	TCP_BRUTAL_COMMIT="${TCP_BRUTAL_COMMIT}" \
	AMNEZIAWG_COMMIT="${AMNEZIAWG_COMMIT}" \
	NF_DEAF_COMMIT="${NF_DEAF_COMMIT}" \
	./build_with_diy.sh kernel BOARD=fake
); then
	fail "build wrapper accepted a final config without DEBUG_INFO_BTF"
fi
sed -i 's/^# CONFIG_DEBUG_INFO_BTF is not set$/CONFIG_DEBUG_INFO_BTF=y/' \
	"${DEB_EVIDENCE}/kernel.config"
build_fake_image_deb

# The source-pin proof must come from the package produced by this build. A
# mismatched manifest must fail even though no kernel worktree exists anymore.
MISMATCH_ROOT="${TEST_ROOT}/wrapper-mismatch"
mkdir -p "${MISMATCH_ROOT}/userpatches/extensions"
cp "${REPO_ROOT}/overwrite/build_with_diy.sh" "${MISMATCH_ROOT}/build_with_diy.sh"
cp -R "${REPO_ROOT}/overwrite/lib" "${MISMATCH_ROOT}/lib"
cp "${REPO_ROOT}/userpatches/extensions/kernel-inject.sh" "${MISMATCH_ROOT}/userpatches/extensions/kernel-inject.sh"
BAD_PIN_DEB="${MISMATCH_ROOT}/bad-pin-linux-image.deb"
build_fake_image_deb 0000000000000000000000000000000000000000
cp "${FAKE_DEB_TEMPLATE}" "${BAD_PIN_DEB}"
build_fake_image_deb
cat > "${MISMATCH_ROOT}/compile.sh" <<'FAKE_COMPILE'
#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p output/debs
cp "${BAD_PIN_DEB_SOURCE}" \
	output/debs/linux-image-fake-rockchip64_1.0_arm64__6.18.53-S0.deb
FAKE_COMPILE
chmod +x "${MISMATCH_ROOT}/compile.sh" "${MISMATCH_ROOT}/build_with_diy.sh"
BAD_PIN_LOG="${MISMATCH_ROOT}/bad-pin.log"
if (
	cd "${MISMATCH_ROOT}"
	BAD_PIN_DEB_SOURCE="${BAD_PIN_DEB}" \
	TCP_BRUTAL_COMMIT="${TCP_BRUTAL_COMMIT}" \
	AMNEZIAWG_COMMIT="${AMNEZIAWG_COMMIT}" \
	NF_DEAF_COMMIT="${NF_DEAF_COMMIT}" \
	./build_with_diy.sh kernel BOARD=fake
) >"${BAD_PIN_LOG}" 2>&1; then
	fail "build wrapper accepted a package whose TCP-Brutal commit is not the pinned one"
fi
assert_contains "${BAD_PIN_LOG}" \
	'Pin validation failed: tcp_brutal_commit: expected d2397ff8bca0, got 0000000000000000000000000000000000000000'

# A deb produced for another branch (e.g. a stale artifact from a previous
# build in the same output/debs) must never satisfy this build's BRANCH.
BRANCH_MISMATCH_ROOT="${TEST_ROOT}/wrapper-branch-mismatch"
mkdir -p "${BRANCH_MISMATCH_ROOT}/userpatches/extensions"
cp "${REPO_ROOT}/overwrite/build_with_diy.sh" "${BRANCH_MISMATCH_ROOT}/build_with_diy.sh"
cp -R "${REPO_ROOT}/overwrite/lib" "${BRANCH_MISMATCH_ROOT}/lib"
cp "${REPO_ROOT}/userpatches/extensions/kernel-inject.sh" "${BRANCH_MISMATCH_ROOT}/userpatches/extensions/kernel-inject.sh"
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
	'commit=d2397ff8bca04a29fd2de01cf7d2d4b825224de8'
assert_contains "${KERNEL_ROOT}/net/ipv4/tcp_brutal/.source-revision" \
	'ref=d2397ff8bca04a29fd2de01cf7d2d4b825224de8'
assert_absent "${KERNEL_ROOT}/net/ipv4/tcp_brutal.c"
assert_not_contains "${KERNEL_ROOT}/net/ipv4/tcp.c" 'TCP_BRUTAL_PARAMS'
assert_contains "${KERNEL_ROOT}/net/ipv4/Kconfig" 'config TCP_AFTER_LEGACY'

assert_file "${KERNEL_ROOT}/drivers/net/amneziawg/Kbuild"
assert_file "${KERNEL_ROOT}/drivers/net/amneziawg/compat/Kbuild.include"
assert_absent "${KERNEL_ROOT}/drivers/net/amneziawg/stale.c"
assert_contains "${KERNEL_ROOT}/drivers/net/amneziawg/Kconfig" \
	'select CRYPTO_LIB_CURVE25519'
assert_contains "${KERNEL_ROOT}/drivers/net/amneziawg/Kconfig" \
	'select CRYPTO_LIB_CHACHA20POLY1305'
assert_contains "${KERNEL_ROOT}/drivers/net/amneziawg/uapi/wireguard.h" \
	'#define WG_GENL_NAME "amneziawg"'
assert_contains "${KERNEL_ROOT}/drivers/net/amneziawg/.source-revision" \
	'commit=1a735221a62c75ad788f8229623dd4d2098bbaa8'

assert_file "${KERNEL_ROOT}/net/netfilter/nf_deaf/nf_deaf.c"
assert_file "${KERNEL_ROOT}/net/netfilter/nf_deaf/Kconfig"
assert_absent "${KERNEL_ROOT}/net/netfilter/nf_deaf.c"
assert_contains "${KERNEL_ROOT}/net/netfilter/Kconfig" 'config NF_AFTER_LEGACY'
assert_contains "${KERNEL_ROOT}/net/netfilter/nf_deaf/.source-revision" \
	'commit=f62b5e6bda120ae4d7c614e9028185eb47418f7c'

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
custom_kernel_config__kernel_inject
cd "${original_pwd}"

after="$(sha256sum \
	"${KERNEL_ROOT}/net/ipv4/Kconfig" \
	"${KERNEL_ROOT}/net/ipv4/Makefile" \
	"${KERNEL_ROOT}/drivers/net/Kconfig" \
	"${KERNEL_ROOT}/drivers/net/Makefile" \
	"${KERNEL_ROOT}/net/netfilter/Kconfig" \
	"${KERNEL_ROOT}/net/netfilter/Makefile")"
[[ "${before}" == "${after}" ]] || fail "second injection changed parent Kconfig/Makefiles"

NEGATIVE_CASE_LOG="${TEST_ROOT}/negative-config-cases.log"
: > "${NEGATIVE_CASE_LOG}"

reset_hook_arrays
if AMNEZIAWG_MODE=y WIREGUARD_MODE=y custom_kernel_config__kernel_inject >>"${NEGATIVE_CASE_LOG}" 2>&1; then
	fail "unsafe built-in AmneziaWG/WireGuard combination was accepted"
fi
assert_contains "${NEGATIVE_CASE_LOG}" \
	"Invalid built-in combination: AMNEZIAWG_MODE=y and WIREGUARD_MODE=y can collide; disable native WireGuard or keep one implementation modular"

: > "${NEGATIVE_CASE_LOG}"
reset_hook_arrays
if WIREGUARD_MODE=invalid custom_kernel_config__kernel_inject >>"${NEGATIVE_CASE_LOG}" 2>&1; then
	fail "invalid WIREGUARD_MODE value was accepted"
fi
assert_contains "${NEGATIVE_CASE_LOG}" \
	"Invalid configuration: CONFIG_WIREGUARD: invalid mode 'invalid'"

: > "${NEGATIVE_CASE_LOG}"
reset_hook_arrays
if ENABLE_FULL_NETWORKING=invalid custom_kernel_config__kernel_inject >>"${NEGATIVE_CASE_LOG}" 2>&1; then
	fail "invalid ENABLE_FULL_NETWORKING value was accepted"
fi
assert_contains "${NEGATIVE_CASE_LOG}" \
	"Invalid configuration: ENABLE_FULL_NETWORKING must be yes or no, got 'invalid'"

# Each injector used to call _kernel_inject_require_files without acting on its
# return value, so a source tree missing a file was reported as an injection
# success. The defect was the missing check at the call site; the helper has
# always returned non-zero correctly. So these cases must get past the fetch --
# which is what fails first and would mask the layout check entirely -- and fail
# at the layout check instead.
#
# The upstream repos are real local git repositories rather than stubs: fetch
# clones into its destination, so a pre-populated plain directory would be
# destroyed by 'git init' before any layout check ran.
LAYOUT_LOG="${TEST_ROOT}/layout-check-cases.log"
: > "${LAYOUT_LOG}"

# Build an upstream whose pinned commit resolves, then delete one required file
# from the checkout so the layout check is what rejects it.
# $1 module tag. $2... files that should exist (a sentinel file is added).
make_upstream() {
	local tag="$1"
	shift
	local repo="${TEST_ROOT}/upstream-${tag}"
	local seed="${TEST_ROOT}/seed-${tag}"
	local name

	rm -rf -- "${repo}" "${seed}"
	mkdir -p "${seed}"
	for name in "$@"; do
		mkdir -p "${seed}/$(dirname "${name}")"
		printf 'placeholder for %s\n' "${name}" > "${seed}/${name}"
	done
	git -C "${seed}" init --quiet
	git -C "${seed}" -c commit.gpgsign=false -c user.name=test -c user.email=test@example.com \
		add -A
	git -C "${seed}" -c commit.gpgsign=false -c user.name=test -c user.email=test@example.com \
		commit --quiet -m "layout fixture"
	git clone --quiet "${seed}" "${repo}"
	printf '%s' "${repo}"
}

# Remove one file, leaving the rest of the layout intact.
drop_from_checkout() {
	local checkout="$1"
	shift
	local name
	for name in "$@"; do
		rm -f -- "${checkout:?}/${name}"
	done
}

run_injector_case() {
	local label="$1"
	local injector="$2"
	local repository="$3"
	local missing="$4"
	# Captured before the shift below.
	local marker="$5"

	shift 4
	local checkout="${TEST_ROOT}/checkout-${label}"
	local commit
	# A per-case kernel root, not the shared one. The positive cases above have
	# already injected real modules into KERNEL_ROOT, so asserting that
	# .source-revision is absent there would fail on their output rather than on
	# anything this case did. Each case needs somewhere the injector has never
	# run, otherwise "nothing was injected" cannot be observed.
	local kernel_root="${TEST_ROOT}/kernel-${label}"
	mkdir -p "${kernel_root}/net/ipv4" "${kernel_root}/drivers/net" \
		"${kernel_root}/net/netfilter"
	commit="$(git -C "${repository}" rev-parse HEAD)"
	# Fetch into a copy so each case starts from a pristine tree.
	rm -rf -- "${checkout}"
	git clone --quiet "${repository}" "${checkout}"
	drop_from_checkout "${checkout}" ${missing}

	if "${injector}" "${kernel_root}" "${checkout}" \
		"${repository}" "branch/x" "${commit}" >>"${LAYOUT_LOG}" 2>&1; then
		fail "${label} injection succeeded despite a missing ${missing}"
	fi
	assert_contains "${LAYOUT_LOG}" "Invalid upstream layout"
	# Checked here rather than by the caller so the path cannot drift from the
	# kernel root this case actually used.
	assert_absent "${kernel_root}/${marker}"
}

upstream="$(make_upstream tcp-brutal brutal.h brutal_cc.c brutal_sockopt.c brutal_rules.c Makefile LICENSE)"
run_injector_case tcp-brutal _kernel_inject_tcp_brutal "${upstream}" brutal.h \
	'net/ipv4/tcp_brutal/.source-revision'

# COPYING is copied into the module directory but used to sit outside the
# required-file check, so its absence passed unnoticed.
upstream="$(make_upstream amneziawg src/Kbuild src/Kconfig src/main.c src/compat/Kbuild.include COPYING)"
run_injector_case amneziawg _kernel_inject_amneziawg "${upstream}" COPYING \
	'drivers/net/amneziawg/.source-revision'

upstream="$(make_upstream nf-deaf nf_deaf.c LICENSE)"
run_injector_case nf-deaf _kernel_inject_nf_deaf "${upstream}" LICENSE \
	'net/netfilter/nf_deaf/.source-revision'

# The directory each injector logs on success must never appear for a rejected
# layout. "Injected <sha>" is the line release notes are built from, so a failed
# injection must not be able to print it.
assert_not_contains "${LAYOUT_LOG}" "Injected"

printf '[PASS] kernel injection is pinned/idempotent; full eBPF and networking are enforced\n'
