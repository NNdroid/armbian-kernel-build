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
# through the framework. Keep that unrelated hook out of this isolated test.
unset -f run_after_build__999_finish_extension_manager
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
printf '[PASS] Armbian extension discovery, hook registration and configuration dispatch\n'
