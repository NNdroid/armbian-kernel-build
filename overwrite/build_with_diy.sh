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

wrapper_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
for wrapper_library in common module-assets release-metadata; do
    source "${wrapper_root}/lib/kernel-build/${wrapper_library}.sh"
done
unset wrapper_library

# Remove the obsolete v1 patch if it remains in a reused/ignored userpatches
# directory. TCP-Brutal v2 owns its socket-option routing.
rm -f -- userpatches/90_patch_brutal.sh

requested_branch="$(argument_value BRANCH "$@" || true)"
requested_board="$(argument_value BOARD "$@" || true)"
expected_family="${BUILD_FAMILY:-rockchip64}"
[[ "${expected_family}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    _kernel_inject_log err "Unsafe artifact family" "${expected_family}"; exit 1
}
if [[ -n "${BUILD_TARGET:-}" ]]; then
    BUILD_PROJECT_ROOT="$PWD"
    BUILD_LIBRARY_ROOT="$PWD/kernel-build/lib"
    source "${BUILD_LIBRARY_ROOT}/targets.sh"
    load_build_target
    [[ "${requested_board}" == "${TARGET_BOARD}" ]] || {
        _kernel_inject_log err "Target board mismatch" "${requested_board} != ${TARGET_BOARD}"; exit 1
    }
    [[ "${expected_family}" == "${TARGET_FAMILY}" ]] || {
        _kernel_inject_log err "Target family mismatch" "${expected_family} != ${TARGET_FAMILY}"; exit 1
    }
fi
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
			"linux-image-${requested_branch}-${expected_family}_"*)
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

built_branch="$(basename "${image_deb}" | sed -n "s/^linux-image-\([A-Za-z0-9._-]*\)-${expected_family}_.*/\1/p")"
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
if [[ -n "${BUILD_TARGET:-}" ]]; then
    source "${BUILD_LIBRARY_ROOT}/board-contract.sh"
    validate_board_contract "${evidence_dir}" "${package_extract_root}" "${final_config}" || exit 1
fi
manifest_arch="$(require_manifest_value "${evidence_manifest}" debian_arch)" || exit 1
if [[ -n "${BUILD_TARGET:-}" ]]; then
	manifest_kbuild_arch="$(require_manifest_value "${evidence_manifest}" kbuild_arch)" || exit 1
	[[ "${manifest_kbuild_arch}" == "${TARGET_KBUILD_ARCH}" ]] || {
		_kernel_inject_log err "Kbuild architecture mismatch" "${manifest_kbuild_arch} != ${TARGET_KBUILD_ARCH}"
		exit 1
	}
fi
manifest_kernel_major_minor="$(require_manifest_value "${evidence_manifest}" kernel_major_minor)" || exit 1
package_arch="$(dpkg-deb -f "${image_deb}" Architecture 2>/dev/null || true)"
if [[ "${manifest_format}" != 1 || "${manifest_branch}" != "${built_branch}" || \
	"${manifest_family}" != "${expected_family}" || "${manifest_arch}" != "${package_arch}" || \
	( -n "${BUILD_ARCH:-}" && "${manifest_arch}" != "${BUILD_ARCH}" ) || \
	"${manifest_kernel_major_minor}" != "${kernel_major_minor}" ]]; then
	_kernel_inject_log err "Build evidence mismatch" \
		"manifest(format=${manifest_format}, branch=${manifest_branch}, family=${manifest_family}, arch=${manifest_arch}, kernel=${manifest_kernel_major_minor})"
	_kernel_inject_log err "Build evidence mismatch" \
		"artifact(branch=${built_branch}, family=${expected_family}, arch=${package_arch:-unknown}, kernel=${kernel_major_minor})"
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
