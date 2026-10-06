#!/usr/bin/env bash
# Convert verified Armbian DEBs into the TAR bundle layout used by
# ophub armbian-update. No kernel compilation, source download, credentials or
# device /boot writes happen here.
#
# This script is intentionally board-agnostic. The board/family/series/DTB
# contract and the boot checks (ARM64 Image text_offset, mmc aliases, memory
# reg) are read from the target profile, so a new board that needs the same
# ophub-tar treatment is a profile change and not a new script. Anything this
# script still hard-codes would be a bug: a board difference belongs in the
# profile.
set -Eeuo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Single source of truth for the board/family/series/DTB contract is the target
# profile, never a literal repeated here.
target_profile="${repo}/userpatches/config/build-targets/${BUILD_TARGET:?BUILD_TARGET is required}.conf"
if [[ ! -f "${target_profile}" ]]; then
    printf '[ERROR] ophub-tar packaging requires a target profile: %s\n' "${target_profile}" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "${target_profile}"

# The series lock is optional. When the profile declares one it is authoritative
# and an unlocked branch is impossible; when it does not, the series is derived
# from the version that was actually built, so an unlocked target tracks Armbian
# instead of failing for want of a lock. Either way the boot contract below is
# checked against real artifact bytes, which is the check that actually protects
# the board -- the series only decides which kernel release string is acceptable.
ophub_tar_series() {
    local series="${TARGET_SERIES[${1}]:-}"
    [[ -n "${series}" ]] || return 0
    printf '%s\n' "${series}"
}

ARM64_IMAGE_MAGIC_HEX="41524d64"

binary_hex() {
    local file="$1" offset="$2" size="$3"
    LC_ALL=C od -An -v -tx1 -j "${offset}" -N "${size}" "${file}" | tr -d '[:space:]'
}

# A raw ARM64 Image is required whenever the profile pins a text_offset. Boards
# that boot whatever Armbian produced declare nothing and skip this entirely.
validate_kernel_image_header() {
    local image="$1"
    [[ -s "${image}" ]] || {
        printf '[ERROR] %s kernel Image is missing or empty: %s\n' "${BUILD_TARGET}" "${image}" >&2
        return 1
    }
    local magic
    magic="$(binary_hex "${image}" 56 4)" || return 1
    [[ "${magic}" == "${ARM64_IMAGE_MAGIC_HEX}" ]] || {
        printf '[ERROR] %s kernel is not a raw ARM64 Image: magic=%s\n' \
            "${BUILD_TARGET}" "${magic:-missing}" >&2
        return 1
    }
    [[ -n "${TARGET_BOOT_TEXT_OFFSET:-}" ]] || return 0
    # The profile states the offset the way it is written in prose (0x01080000).
    # The ARM64 Image header stores text_offset as a little-endian u64, so the
    # comparison value is that value zero-extended to 8 bytes and byte-swapped.
    local declared expected actual reversed
    declared="${TARGET_BOOT_TEXT_OFFSET,,}"
    # Normalize to exactly 16 hex digits (u64), rejecting anything too large to
    # be an offset rather than silently truncating it.
    (( ${#declared} <= 16 )) || {
        printf '[ERROR] %s TEXT_OFFSET is too large for a u64: %s\n' "${BUILD_TARGET}" "${TARGET_BOOT_TEXT_OFFSET}" >&2
        return 1
    }
    printf -v declared '%016s' "${declared}"
    declared="${declared// /0}"
    # The header holds the offset little-endian, so reverse the 8 big-endian
    # digit pairs to get the byte sequence od will print.
    expected=""
    reversed=""
    local index
    for (( index = 0; index < 16; index += 2 )); do
        expected+="${declared:index:2}"
    done
    for (( index = 14; index >= 0; index -= 2 )); do
        reversed+="${expected:index:2}"
    done
    actual="$(binary_hex "${image}" 8 8)" || return 1
    [[ "${actual}" == "${reversed}" ]] || {
        printf '[ERROR] %s kernel lacks the required TEXT_OFFSET 0x%s: header=%s\n' \
            "${BUILD_TARGET}" "${TARGET_BOOT_TEXT_OFFSET}" "${actual:-missing}" >&2
        return 1
    }
}

build_arm64_uinitrd() {
    local stage="$1" release="$2"
    local initrd="${stage}/boot/initrd.img-${release}"
    local uinitrd="${stage}/boot/uInitrd-${release}"
    # Keep the payload and the U-Boot metadata in sync. Ophub's Amlogic flow
    # expects an ARM64 uImage header describing a gzip-compressed initramfs.
    mkinitramfs -c gzip -o "${initrd}" "${release}"
    mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd \
        -d "${initrd}" "${uinitrd}"
}

# Validate the compiled DTB against whatever the profile declares. Properties
# are read from the flattened tree (including inherited ones) rather than
# assuming a successfully applied board patch produced the right aliases.
validate_board_dtb() {
    local dtb="$1" alias path memory
    local index=0
    local -a cells=()
    if [[ "${#TARGET_DTB_MMC_ALIASES[@]}" -gt 0 ]]; then
        for controller in "${TARGET_DTB_MMC_ALIASES[@]}"; do
            path="$(fdtget -t s "${dtb}" /aliases "mmc${index}")" || return 1
            [[ "${path}" =~ /(mmc|sd)@${controller}$ ]] || {
                printf '[ERROR] %s DTB mmc%s must identify controller %s, got %s\n' \
                    "${BUILD_TARGET}" "${index}" "${controller}" "${path}" >&2
                return 1
            }
            index=$((index + 1))
        done
    fi
    [[ -n "${TARGET_DTB_MEMORY_REG:-}" ]] || return 0
    memory="$(fdtget -t x "${dtb}" /memory@0 reg)" || return 1
    read -r -a cells <<< "${memory}"
    [[ "${cells[*]}" == "${TARGET_DTB_MEMORY_REG}" ]] || {
        printf '[ERROR] %s DTB memory declaration mismatch: expected %s, got %s\n' \
            "${BUILD_TARGET}" "${TARGET_DTB_MEMORY_REG}" "${memory}" >&2
        return 1
    }
}

package_ophub_tar() (
    local branch="$1" marker="$2" version="$3"
    local series
    series="$(ophub_tar_series "${branch}")"
    # A declared series is a promise the profile makes about this board, so a
    # version outside it means the branch moved and the promise is stale. With no
    # declaration, take the series from the version just built: the build already
    # resolved it from the artifact, so re-deriving it here keeps the release
    # string and the series regex in agreement without inventing a constraint the
    # profile never asked for.
    if [[ -n "${series}" ]]; then
        [[ "${version}" == "${series}."* ]] || {
            printf '[ERROR] %s expects branch %s at series %s.x, got %s\n' \
                "${BUILD_TARGET}" "${branch}" "${series}" "${version:-missing}" >&2
            return 1
        }
    else
        series="${version%%.*}"
        [[ "${series}" =~ ^[0-9]+\.[0-9]+$ ]] || {
            printf '[ERROR] Cannot derive a major.minor series from built version %s for %s / %s\n' \
                "${version:-missing}" "${BUILD_TARGET}" "${branch}" >&2
            return 1
        }
    fi
    [[ -f "${marker}" ]] || {
        printf '[ERROR] Build marker %s is missing for %s / %s\n' \
            "${marker}" "${BUILD_TARGET}" "${branch}" >&2
        return 1
    }
    local debs="${repo}/build/output/debs" work package kind
    work="$(mktemp -d "${repo}/build/ophub-tar-package.XXXXXX")"
    trap 'rm -rf -- "${work}"' EXIT
    mkdir -p "${work}/root" "${work}/bundle" "${repo}/build/output/${BUILD_TARGET}"
    local -a matches=()
    for kind in image dtb headers; do
        mapfile -d '' -t matches < <(find "${debs}" -maxdepth 1 -type f \
            -name "linux-${kind}-${branch}-${TARGET_FAMILY}_*__${version}-*.deb" \
            -newer "${marker}" -print0)
        if ((${#matches[@]} != 1)); then
            printf '[ERROR] Expected one fresh %s %s DEB, got %s\n' \
                "${BUILD_TARGET}" "${kind}" "${#matches[@]}" >&2
            return 1
        fi
        package="${matches[0]}"
        [[ "$(dpkg-deb -f "${package}" Architecture)" == "${TARGET_ARCH}" ]] || {
            printf '[ERROR] %s DEB has architecture %s, expected %s\n' \
                "${kind}" "$(dpkg-deb -f "${package}" Architecture)" "${TARGET_ARCH}" >&2
            return 1
        }
        dpkg-deb -x "${package}" "${work}/root"
    done
    # mkinitramfs uses /lib/modules. Contain it in a disposable native container
    # of the target architecture, never install build packages into the host or
    # the target system. The container has no access to the target profile, so
    # every authoritative value is passed in explicitly instead of re-read there.
    [[ -n "${TARGET_BOARD_DTB:-}" ]] || {
        printf '[ERROR] Target profile must declare TARGET_BOARD_DTB for ophub-tar packaging\n' >&2
        return 1
    }
    docker run --rm --platform "linux/${TARGET_ARCH}" \
        --env "PACKAGE_OWNER=$(id -u):$(id -g)" \
        --env "PACKAGE_TARGET=${BUILD_TARGET}" \
        --env "PACKAGE_ARCH=${TARGET_ARCH}" \
        --env "PACKAGE_SERIES=${series}" \
        --env "PACKAGE_DTB=${TARGET_BOARD_DTB}" \
        --env "PACKAGE_BOOT_TEXT_OFFSET=${TARGET_BOOT_TEXT_OFFSET:-}" \
        --env "PACKAGE_DTB_MMC_ALIASES=${TARGET_DTB_MMC_ALIASES[*]:-}" \
        --env "PACKAGE_DTB_MEMORY_REG=${TARGET_DTB_MEMORY_REG:-}" \
        --mount "type=bind,src=${work},dst=/package" \
        --mount "type=bind,src=${repo}/scripts/package_ophub_tar.sh,dst=/package-worker.sh,readonly" \
        ubuntu:24.04 bash /package-worker.sh --worker
    local release
    release="$(< "${work}/kernel-release")"
    [[ "${release}" == "${version}-"* && "${release}" =~ ^[A-Za-z0-9._+-]+$ ]] || return 1
    local output="${repo}/build/output/${BUILD_TARGET}/${release}.tar.gz"
    tar -czf "${work}/complete.tar.gz" -C "${work}/bundle" .
    mv -- "${work}/complete.tar.gz" "${output}"
    (cd "${repo}/build/output/${BUILD_TARGET}"; sha256sum "${release}.tar.gz" > "${release}.tar.gz.sha256")
    # Extend the existing, package-derived Release notes rather than inventing
    # a second metadata generator.
    {
        printf '\n## %s installation bundle\n\n' "${BOARD_NAME:-${BUILD_TARGET}}"
        printf 'Bundle: `%s.tar.gz`. Extract into an empty directory, verify `sha256sum -c sha256sums`, then run `sudo armbian-update -k %s -d tar`. ' "${release}" "${release}"
        [[ -n "${TARGET_BOOT_TEXT_OFFSET:-}" ]] && \
            printf 'The bundle is validated for the required ARM64 Image TEXT_OFFSET 0x%s. ' "${TARGET_BOOT_TEXT_OFFSET}"
        printf 'It contains an ARM64/gzip uInitrd. Keep the existing root UUID, FDT and bootloader. Back up the old kernel and prepare bootable recovery media. Hardware boot validation is still required.\n'
    } >> "${repo}/build/output/release-metadata/${branch}/build-summary.md"
    printf '[INFO] %s TAR bundle generated from verified Armbian DEBs: %s\n' "${BUILD_TARGET}" "${output}"
)

stage_bundle_payload() {
    local root="$1" stage="$2" release="$3"
    local image="${root}/boot/vmlinuz-${release}"
    # The DTB location comes from the profile (passed in by the host) rather than
    # a literal, so renaming the board DTB cannot desynchronize this step.
    local dtb_rel="${PACKAGE_DTB:?PACKAGE_DTB must be provided by the host}"
    local dtb="${root}/boot/dtb-${release}/${dtb_rel}"
    [[ -s "${image}" && -s "${dtb}" && -d "${root}/usr/src/linux-headers-${release}" ]] || {
        printf '[ERROR] %s payload incomplete for release %s\n' "${PACKAGE_TARGET:-target}" "${release}" >&2
        return 1
    }
    validate_kernel_image_header "${image}" || return 1
    validate_board_dtb "${dtb}" || return 1
    mkdir -p "${stage}/boot" "${stage}/dtb" "${stage}/modules" "${stage}/header"
    cp "${image}" "${stage}/boot/vmlinuz-${release}"
    cp "${root}/boot/config-${release}" "${stage}/boot/"
    cp "${root}/boot/System.map-${release}" "${stage}/boot/"
    cp -a "${root}/boot/dtb-${release}/${dtb_rel%/*}/." "${stage}/dtb/"
    # ophub's installer requires <uname-r>/ at the archive root, not lib/modules/.
    cp -a "${root}/lib/modules/${release}" "${stage}/modules/"
    cp -a "${root}/usr/lib/armbian-kernel-build/${release}" \
        "${stage}/modules/${release}/armbian-kernel-build"
    cp -a "${root}/usr/src/linux-headers-${release}/." "${stage}/header/"
}

# Rehydrate the profile-derived knobs inside the container. The worker is a
# native target binary and cannot source the profile, so the values arrive as
# environment variables and are validated here, once, before any use.
_package_load_knobs() {
    PACKAGE_TARGET="${PACKAGE_TARGET:?PACKAGE_TARGET must be provided by the host}"
    PACKAGE_ARCH="${PACKAGE_ARCH:?PACKAGE_ARCH must be provided by the host}"
    TARGET_BOARD_DTB="${PACKAGE_DTB:?PACKAGE_DTB must be provided by the host}"
    TARGET_BOOT_TEXT_OFFSET="${PACKAGE_BOOT_TEXT_OFFSET:-}"
    TARGET_DTB_MEMORY_REG="${PACKAGE_DTB_MEMORY_REG:-}"
    declare -ga TARGET_DTB_MMC_ALIASES=()
    if [[ -n "${PACKAGE_DTB_MMC_ALIASES:-}" ]]; then
        read -r -a TARGET_DTB_MMC_ALIASES <<< "${PACKAGE_DTB_MMC_ALIASES}"
    fi
    # ARCH must be the container's own architecture; a mismatch would silently
    # produce a bundle for the wrong machine.
    [[ "${PACKAGE_ARCH}" == "$(uname -m)" ]] || {
        printf '[ERROR] Container architecture %s does not match target arch %s\n' \
            "$(uname -m)" "${PACKAGE_ARCH}" >&2
        return 1
    }
}

package_worker() {
    _package_load_knobs || return 1
    [[ "${PACKAGE_OWNER:-}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    trap 'chown -R "${PACKAGE_OWNER}" /package' EXIT
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends initramfs-tools u-boot-tools kmod device-tree-compiler
    local root=/package/root stage=/package/stage release
    local -a releases=()
    mapfile -t releases < <(find "${root}/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
    ((${#releases[@]} == 1)) || return 1
    release="${releases[0]}"
    # Validate against the series the host resolved. With a declared lock that
    # series is the profile's promise; without one the host derived it from the
    # version it built, which makes this a consistency check between the release
    # directory and the DEBs it came from rather than a second policy. The bare
    # `return 1` this replaces gave no diagnostic at all.
    local series="${PACKAGE_SERIES:?PACKAGE_SERIES must be provided by the host}"
    [[ "${release}" =~ ^${series//./\.}\.[0-9]+-[-A-Za-z0-9._+]+$ ]] || {
        printf '[ERROR] %s kernel release %s does not match series %s\n' \
            "${PACKAGE_TARGET}" "${release}" "${series}" >&2
        return 1
    }
    stage_bundle_payload "${root}" "${stage}" "${release}"
    mkdir -p /lib/modules /boot
    cp -a "${root}/lib/modules/${release}" /lib/modules/
    cp "${root}/boot/config-${release}" /boot/
    depmod -a "${release}"
    build_arm64_uinitrd "${stage}" "${release}"
    local kind name vendor="${TARGET_BOARD_DTB%%/*}"
    for kind in boot dtb modules header; do
        name="${kind}-${release}.tar.gz"
        # ophub expects the vendor subdirectory name in the DTB bundle name.
        [[ "${kind}" != dtb ]] || name="dtb-${vendor}-${release}.tar.gz"
        tar -czf "/package/bundle/${name}" -C "/package/stage/${kind}" .
    done
    (cd /package/bundle; sha256sum ./*.tar.gz > sha256sums)
    printf '%s\n' "${release}" > /package/kernel-release
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --worker) package_worker ;;
        *) package_ophub_tar "$@" ;;
    esac
fi
