#!/usr/bin/env bash
# Convert verified Armbian DEBs to the TAR layout used by ophub armbian-update.
# No kernel compilation, source download, credentials or device /boot writes here.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# HK1 Box uses a legacy Amlogic boot flow. Ophub/unifreq kernels advertise
# 0x01080000 in the ARM64 Image header so vendor U-Boot can boot the Image
# without requiring a u-boot.ext overload solely to compensate for offset 0.
HK1BOX_TEXT_OFFSET_LE_HEX="0000080100000000"
HK1BOX_ARM64_MAGIC_HEX="41524d64"

binary_hex() {
    local file="$1" offset="$2" size="$3"
    LC_ALL=C od -An -v -tx1 -j "${offset}" -N "${size}" "${file}" | tr -d '[:space:]'
}

validate_hk1box_kernel_image() {
    local image="$1" text_offset magic
    [[ -s "${image}" ]] || {
        printf '[ERROR] HK1 Box kernel Image is missing or empty: %s\n' "${image}" >&2
        return 1
    }
    text_offset="$(binary_hex "${image}" 8 8)" || return 1
    magic="$(binary_hex "${image}" 56 4)" || return 1
    [[ "${magic}" == "${HK1BOX_ARM64_MAGIC_HEX}" ]] || {
        printf '[ERROR] HK1 Box kernel is not a raw ARM64 Image: magic=%s\n' "${magic:-missing}" >&2
        return 1
    }
    [[ "${text_offset}" == "${HK1BOX_TEXT_OFFSET_LE_HEX}" ]] || {
        printf '[ERROR] HK1 Box kernel lacks legacy Amlogic TEXT_OFFSET 0x01080000: header=%s\n' \
            "${text_offset:-missing}" >&2
        return 1
    }
}

build_hk1box_initramfs() {
    local stage="$1" release="$2"
    local initrd="${stage}/boot/initrd.img-${release}"
    local uinitrd="${stage}/boot/uInitrd-${release}"
    # Keep the payload and the U-Boot metadata in sync. Ophub's Amlogic flow
    # expects an ARM64 uImage header describing a gzip-compressed initramfs.
    mkinitramfs -c gzip -o "${initrd}" "${release}"
    mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd \
        -d "${initrd}" "${uinitrd}"
}

package_hk1box() (
    local branch="$1" marker="$2" version="$3"
    [[ "${branch}" == edge && "${version}" == 7.2.* && -f "${marker}" ]] || return 1
    local debs="${repo}/build/output/debs" work package kind
    work="$(mktemp -d "${repo}/build/hk1box-package.XXXXXX")"
    trap 'rm -rf -- "${work}"' EXIT
    mkdir -p "${work}/root" "${work}/bundle" "${repo}/build/output/hk1box"
    local -a matches=()
    for kind in image dtb headers; do
        mapfile -d '' -t matches < <(find "${debs}" -maxdepth 1 -type f \
            -name "linux-${kind}-${branch}-meson64_*__${version}-*.deb" -newer "${marker}" -print0)
        if ((${#matches[@]} != 1)); then
            printf '[ERROR] Expected one fresh HK1 Box %s DEB, got %s\n' "${kind}" "${#matches[@]}" >&2
            return 1
        fi
        package="${matches[0]}"
        [[ "$(dpkg-deb -f "${package}" Architecture)" == arm64 ]] || return 1
        dpkg-deb -x "${package}" "${work}/root"
    done
    # mkinitramfs uses /lib/modules. Contain it in a disposable native ARM64
    # container, never install build packages into the host or target system.
    docker run --rm --platform linux/arm64 \
        --env "PACKAGE_OWNER=$(id -u):$(id -g)" \
        --mount "type=bind,src=${work},dst=/package" \
        --mount "type=bind,src=${repo}/scripts/package_hk1box.sh,dst=/package-worker.sh,readonly" \
        ubuntu:24.04 bash /package-worker.sh --worker
    local release
    release="$(< "${work}/kernel-release")"
    [[ "${release}" == "${version}-"* && "${release}" =~ ^[A-Za-z0-9._+-]+$ ]] || return 1
    local output="${repo}/build/output/hk1box/${release}.tar.gz"
    tar -czf "${work}/complete.tar.gz" -C "${work}/bundle" .
    mv -- "${work}/complete.tar.gz" "${output}"
    (cd "${repo}/build/output/hk1box"; sha256sum "${release}.tar.gz" > "${release}.tar.gz.sha256")
    # Extend the existing, package-derived Release notes rather than inventing
    # a second metadata generator for Meson.
    printf '\n## HK1 Box installation bundle\n\nBundle: `%s.tar.gz`. Extract into an empty directory, verify `sha256sum -c sha256sums`, then run `sudo armbian-update -k %s -d tar`. The bundle is validated for the legacy Amlogic ARM64 Image TEXT_OFFSET 0x01080000 and contains an ARM64/gzip uInitrd. Keep the existing uEnv.txt root UUID, HK1 Box FDT and bootloader. Back up the old kernel and prepare bootable recovery media. Hardware boot validation is still required.\n' \
        "${release}" "${release}" >> "${repo}/build/output/release-metadata/${branch}/build-summary.md"
    printf '[INFO] HK1 Box TAR bundle generated from verified Armbian DEBs: %s\n' "${output}"
)

stage_hk1box_payload() {
    local root="$1" stage="$2" release="$3"
    local image="${root}/boot/vmlinuz-${release}"
    local dtb="${root}/boot/dtb-${release}/amlogic/meson-sm1-hk1box-vontar-x3.dtb"
    [[ -s "${image}" && -s "${dtb}" && -d "${root}/usr/src/linux-headers-${release}" ]] || return 1
    validate_hk1box_kernel_image "${image}" || return 1
    mkdir -p "${stage}/boot" "${stage}/dtb" "${stage}/modules" "${stage}/header"
    cp "${image}" "${stage}/boot/vmlinuz-${release}"
    cp "${root}/boot/config-${release}" "${stage}/boot/"
    cp "${root}/boot/System.map-${release}" "${stage}/boot/"
    cp -a "${root}/boot/dtb-${release}/amlogic/." "${stage}/dtb/"
    # ophub's installer requires <uname-r>/ at the archive root, not lib/modules/.
    cp -a "${root}/lib/modules/${release}" "${stage}/modules/"
    cp -a "${root}/usr/lib/armbian-kernel-build/${release}" \
        "${stage}/modules/${release}/armbian-kernel-build"
    cp -a "${root}/usr/src/linux-headers-${release}/." "${stage}/header/"
}

package_worker() {
    [[ "$(uname -m)" == aarch64 ]] || return 1
    [[ "${PACKAGE_OWNER:-}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    trap 'chown -R "${PACKAGE_OWNER}" /package' EXIT
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends initramfs-tools u-boot-tools kmod
    local root=/package/root stage=/package/stage release
    local -a releases=()
    mapfile -t releases < <(find "${root}/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
    ((${#releases[@]} == 1)) || return 1
    release="${releases[0]}"
    [[ "${release}" =~ ^7\.2\.[0-9]+-[-A-Za-z0-9._+]+$ ]] || return 1
    stage_hk1box_payload "${root}" "${stage}" "${release}"
    mkdir -p /lib/modules /boot
    cp -a "${root}/lib/modules/${release}" /lib/modules/
    cp "${root}/boot/config-${release}" /boot/
    depmod -a "${release}"
    build_hk1box_initramfs "${stage}" "${release}"
    local kind name
    for kind in boot dtb modules header; do
        name="${kind}-${release}.tar.gz"
        [[ "${kind}" != dtb ]] || name="dtb-amlogic-${release}.tar.gz"
        tar -czf "/package/bundle/${name}" -C "${stage}/${kind}" .
    done
    (cd /package/bundle; sha256sum ./*.tar.gz > sha256sums)
    printf '%s\n' "${release}" > /package/kernel-release
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ "${1:-}" == --worker ]]; then package_worker; else package_hk1box "$@"; fi
fi
