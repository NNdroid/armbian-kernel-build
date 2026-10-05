#!/usr/bin/env bash
# Integration contract against the real Armbian extension manager supplied by
# the caller. No network or kernel compilation is performed by this test.
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
manager_source="${1:?Usage: test_armbian_extensions.sh /path/to/armbian/extensions.sh}"
source "${manager_source}"
display_alert() { :; }
add_cleanup_handler() { :; }
get_extension_hook_stracktrace() { printf 'integration-test'; }
extension_manager_declare_globals
# The manager's built-in housekeeping hook normally receives its metadata
# through the framework. Keep that unrelated hook out of this isolated test, but
# fail loudly if the name ever changes: a silent `unset` of a function that no
# longer exists would let the real finisher run and mutate this fixture.
if declare -F run_after_build__999_finish_extension_manager >/dev/null; then
	unset -f run_after_build__999_finish_extension_manager
else
	printf '[WARN] upstream no longer defines run_after_build__999_finish_extension_manager; update this test\n' >&2
fi
USERPATCHES_PATH="${REPO_ROOT}/userpatches"
source "${USERPATCHES_PATH}/config/boards/hk1box.conf"
extension_function_info[custom_kernel_config__999_hk1box_storage_and_network]='EXTENSION="hk1box-board"'
extension_function_info[post_family_config__hk1box_kernel_only]='EXTENSION="hk1box-board"'
SRC="${REPO_ROOT}"
ENABLE_EXTENSIONS=kernel-inject,kernel-inject-evidence
EXT=''
SHOW_DEBUG=yes
SHOW_EXTENSIONS=no
ENABLE_EXTENSION_TRACE_HINT='integration test: '
WRITE_EXTENSIONS_METADATA=no
EXTENSION_MANAGER_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kernel-extension-test.XXXXXX")"
trap 'rm -rf -- "${EXTENSION_MANAGER_TMP_DIR}"' EXIT
initialize_extension_manager
declare -F custom_kernel_config >/dev/null
declare -F pre_package_kernel_image >/dev/null
[[ "${defined_hook_point_functions[custom_kernel_config__kernel_inject]}" == *'EXTENSION="kernel-inject"'* ]]
[[ "${defined_hook_point_functions[pre_package_kernel_image__kernel_inject_evidence]}" == *'EXTENSION="kernel-inject-evidence"'* ]]
declare -a opts_y=() opts_m=(DWMAC_MESON CONFIG_MMC_MESON_GX) opts_n=(CONFIG_DWMAC_MESON) kernel_config_modifying_hashes=()
# Exercise the manager-generated wrapper in the artifact hashing phase (no
# .config / source tree): all modes must survive registration and invocation.
cd "${EXTENSION_MANAGER_TMP_DIR}"
custom_kernel_config
[[ " ${opts_y[*]} " == *' TCP_CONG_BRUTAL '* ]]
[[ " ${opts_y[*]} " == *' AMNEZIAWG '* ]]
[[ " ${opts_y[*]} " == *' NETFILTER_DEAF '* ]]
[[ " ${opts_m[*]} " == *' MT7921E '* ]]
[[ " ${opts_y[*]} " == *' DWMAC_MESON '* ]]
[[ " ${opts_m[*]} " != *'DWMAC_MESON'* ]]
[[ " ${opts_m[*]} " != *'MMC_MESON_GX'* ]]
[[ " ${opts_n[*]} " != *'DWMAC_MESON'* ]]
[[ " ${kernel_config_modifying_hashes[*]} " == *' kernel-injector-v8-extension-entrypoint '* ]]

# ---------------------------------------------------------------------------
# The evidence hook is the start of the whole provenance chain: it is what
# embeds kernel.config / defined-symbols.txt / source-manifest.env into the
# linux-image package. Checking that the function merely exists proves nothing,
# so drive the manager-generated wrapper the way Armbian does and assert the
# artifacts really land in the package staging tree.
# ---------------------------------------------------------------------------
EVIDENCE_KERNEL_ROOT="${EXTENSION_MANAGER_TMP_DIR}/synthetic-kernel"
mkdir -p "${EVIDENCE_KERNEL_ROOT}/scripts" \
	"${EVIDENCE_KERNEL_ROOT}/net/ipv4/tcp_brutal" \
	"${EVIDENCE_KERNEL_ROOT}/drivers/net/amneziawg" \
	"${EVIDENCE_KERNEL_ROOT}/net/netfilter/nf_deaf"
printf 'CONFIG_SYNTHETIC=y\nCONFIG_TCP_CONG_BRUTAL=y\n' > "${EVIDENCE_KERNEL_ROOT}/.config"
printf 'config SYNTHETIC\n\tbool "synthetic"\nmenuconfig AMNEZIAWG\n\ttristate "awg"\n' \
	> "${EVIDENCE_KERNEL_ROOT}/Kconfig"
# The evidence hook refuses to run unless the injected tree carries revision
# markers matching the pinned commits, so the fixture has to pin them too.
printf 'commit=%s\n' "${TCP_BRUTAL_COMMIT}" > "${EVIDENCE_KERNEL_ROOT}/net/ipv4/tcp_brutal/.source-revision"
printf 'commit=%s\n' "${AMNEZIAWG_COMMIT}" > "${EVIDENCE_KERNEL_ROOT}/drivers/net/amneziawg/.source-revision"
printf 'commit=%s\n' "${NF_DEAF_COMMIT}" > "${EVIDENCE_KERNEL_ROOT}/net/netfilter/nf_deaf/.source-revision"
# `make defconfig` / `make kernelrelease` are best-effort inside the hook, but
# scripts/diffconfig is only used when the baseline succeeded, so provide a
# stub for it to keep this fixture independent of the host toolchain.
cat > "${EVIDENCE_KERNEL_ROOT}/scripts/diffconfig" <<'SYNTHETIC_DIFFCONFIG'
#!/usr/bin/env bash
diff -u "$1" "$2" || true
SYNTHETIC_DIFFCONFIG
chmod +x "${EVIDENCE_KERNEL_ROOT}/scripts/diffconfig"

EVIDENCE_PACKAGE_STAGE="${EXTENSION_MANAGER_TMP_DIR}/synthetic-package"
mkdir -p "${EVIDENCE_PACKAGE_STAGE}"
kernel_work_dir="${EVIDENCE_KERNEL_ROOT}"
package_directory="${EVIDENCE_PACKAGE_STAGE}"
kernel_version_family="6.18.53-evidence-test"
KERNEL_SRC_ARCH="arm64"
ARCH="arm64"
BRANCH="current"
BOARD="fake"
LINUXFAMILY="rockchip64"
LINUXCONFIG="linux-rockchip64-current"
KERNEL_MAJOR_MINOR="6.18"
WORKDIR="${EXTENSION_MANAGER_TMP_DIR}"
pre_package_kernel_image

EVIDENCE_DIR="${EVIDENCE_PACKAGE_STAGE}/usr/lib/armbian-kernel-build/6.18.53-evidence-test"
for artifact in kernel.config defined-symbols.txt source-manifest.env \
	config-vs-arm64-defconfig.txt arm64-defconfig-build.log; do
	[[ -s "${EVIDENCE_DIR}/${artifact}" ]] || {
		printf '[FAIL] pre_package_kernel_image did not produce %s\n' "${artifact}" >&2
		exit 1
	}
done
grep -q '^evidence_format=1$' "${EVIDENCE_DIR}/source-manifest.env"
grep -q "^tcp_brutal_commit=${TCP_BRUTAL_COMMIT}$" "${EVIDENCE_DIR}/source-manifest.env"
grep -q "^amneziawg_commit=${AMNEZIAWG_COMMIT}$" "${EVIDENCE_DIR}/source-manifest.env"
grep -q "^nf_deaf_commit=${NF_DEAF_COMMIT}$" "${EVIDENCE_DIR}/source-manifest.env"
# The Kconfig inventory must be a real symbol list, not an empty file that only
# satisfies the non-empty check above.
grep -qx 'SYNTHETIC' "${EVIDENCE_DIR}/defined-symbols.txt"
grep -qx 'AMNEZIAWG' "${EVIDENCE_DIR}/defined-symbols.txt"

# A tree whose revision markers disagree with the pins must abort the hook: an
# unprovenanced kernel image is worse than a failed build.
#
# Assert this on the implementation function, not on the wrapper. The upstream
# manager generates the wrapper with a trailing display_alert, so the hook's
# return value never reaches the caller; that gap is covered by the independent
# re-validation in overwrite/build_with_diy.sh, which refuses any linux-image
# package that does not contain exactly one source-manifest.env.
printf 'commit=%s\n' 0000000000000000000000000000000000000000 \
	>"${EVIDENCE_KERNEL_ROOT}/net/ipv4/tcp_brutal/.source-revision"
if pre_package_kernel_image__kernel_inject_evidence 2>/dev/null; then
	printf '[FAIL] evidence hook ignored mismatched source pins; a kernel image without provenance would ship\n' >&2
	exit 1
fi
printf 'commit=%s\n' "${TCP_BRUTAL_COMMIT}" > "${EVIDENCE_KERNEL_ROOT}/net/ipv4/tcp_brutal/.source-revision"

printf '[PASS] Armbian extension discovery, hook registration and configuration dispatch\n'
printf '[PASS] pre_package_kernel_image evidence dispatch produces a complete provenance chain\n'
