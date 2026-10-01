#!/usr/bin/env bash
# Convert verified Armbian DEBs to the TAR layout used by ophub armbian-update.
# No kernel compilation, source download, credentials or device /boot writes here.
set -Eeuo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

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
    printf '\n## HK1 Box installation bundle\n\nBundle: `%s.tar.gz`. Extract into an empty directory, verify `sha256sum -c sha256sums`, then run `sudo armbian-update -k %s -d tar`. Keep the existing uEnv.txt root UUID, HK1 Box FDT and vendor U-Boot. Back up the old kernel and prepare bootable recovery media. Hardware boot validation is still required.\n' \
        "${release}" "${release}" >> "${repo}/build/output/release-metadata/${branch}/build-summary.md"
    printf '[INFO] HK1 Box TAR bundle generated from verified Armbian DEBs: %s\n' "${output}"
)

package_worker() {
    [[ "$(uname -m)" == aarch64 ]] || return 1
    [[ "${PACKAGE_OWNER:-}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    trap 'chown -R "${PACKAGE_OWNER}" /package' EXIT
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends initramfs-tools u-boot-tools kmod
    local root=/package/root stage=/package/stage release image dtb
    local -a releases=()
    mapfile -t releases < <(find "${root}/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
    ((${#releases[@]} == 1)) || return 1
    release="${releases[0]}"
    [[ "${release}" =~ ^7\.2\.[0-9]+-[-A-Za-z0-9._+]+$ ]] || return 1
    image="${root}/boot/vmlinuz-${release}"
    dtb="${root}/boot/dtb-${release}/amlogic/meson-sm1-hk1box-vontar-x3.dtb"
    [[ -s "${image}" && -s "${dtb}" && -d "${root}/usr/src/linux-headers-${release}" ]] || return 1
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
    mkdir -p /lib/modules /boot
    cp -a "${root}/lib/modules/${release}" /lib/modules/
    cp "${root}/boot/config-${release}" /boot/
    depmod -a "${release}"
    mkinitramfs -o "${stage}/boot/initrd.img-${release}" "${release}"
    mkimage -A arm -O linux -T ramdisk -C none -n uInitrd \
        -d "${stage}/boot/initrd.img-${release}" "${stage}/boot/uInitrd-${release}"
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
