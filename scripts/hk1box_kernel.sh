#!/usr/bin/env bash
# Container-only native arm64 builder using ophub's Meson/SM1 source and config.
set -Eeuo pipefail
hk_finish_stage() {
    if [[ -n "${HK_STAGE_LABEL:-}" ]]; then
        printf '[INFO] %s ──── %s completed (elapsed %ss) ────\n' \
            "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "${HK_STAGE_LABEL}" "$((SECONDS - HK_STAGE_START))"
        HK_STAGE_LABEL=''
    fi
}
hk_stage() {
    hk_finish_stage
    HK_STAGE_LABEL="$1"; HK_STAGE_START=$SECONDS
    printf '[INFO] %s ──── %s ────\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$1"
}
hk_fail() { printf '[ERROR] %s\n' "$*" >&2; return 1; }

hk_prepare_config() {
    local symbol
    local -a opts_y=() opts_m=() opts_n=() kernel_config_modifying_hashes=()
    custom_kernel_config
    # These board foundations must survive the template and olddefconfig.
    for symbol in ARCH_MESON MMC MMC_BLOCK MMC_MESON_GX EXT4_FS DEVTMPFS \
        DEVTMPFS_MOUNT BLK_DEV_INITRD SERIAL_MESON SERIAL_MESON_CONSOLE \
        STMMAC_ETH STMMAC_PLATFORM DWMAC_MESON MESON_GXL_PHY \
        PINCTRL_MESON PINCTRL_MESON_G12A \
        CRYPTO_LIB_CURVE25519 CRYPTO_LIB_CHACHA20POLY1305; do
        _kernel_inject_force_mode "${symbol}" y
    done
    for symbol in "${opts_n[@]}"; do ./scripts/config --disable "${symbol}"; done
    for symbol in "${opts_y[@]}"; do ./scripts/config --enable "${symbol}"; done
    for symbol in "${opts_m[@]}"; do ./scripts/config --module "${symbol}"; done
    ./scripts/config --disable LOCALVERSION_AUTO --set-str LOCALVERSION '-hk1box'
    # Ubuntu's distro certificate paths are not present in this source tree.
    ./scripts/config --set-str SYSTEM_TRUSTED_KEYS '' --set-str SYSTEM_REVOCATION_KEYS ''
    make ARCH=arm64 olddefconfig
    _kernel_inject_verify_full_ebpf_config .config
    _kernel_inject_verify_full_network_config .config
    for symbol in ARCH_MESON MMC MMC_BLOCK MMC_MESON_GX EXT4_FS BLK_DEV_INITRD \
        SERIAL_MESON SERIAL_MESON_CONSOLE DWMAC_MESON; do
        grep -qx "CONFIG_${symbol}=y" .config || hk_fail "HK1 Box boot requirement: CONFIG_${symbol}=y"
    done
}

hk_verify_custom_modules() {
    local config="$1" module_root="$2" pair symbol module
    # Default modes are built-in; prove Kbuild actually included each component.
    for pair in TCP_CONG_BRUTAL:brutal AMNEZIAWG:amneziawg NETFILTER_DEAF:nf_deaf; do
        symbol="${pair%%:*}"; module="${pair#*:}"
        grep -qx "CONFIG_${symbol}=y" "${config}" || hk_fail "CONFIG_${symbol} must be built in"
        grep -Eq "(^|/)${module}\.ko$" "${module_root}/modules.builtin" || hk_fail "Missing built-in ${module}"
    done
    # Wi-Fi must remain modular even on boards without a connected PCIe card.
    find "${module_root}" -type f -name 'mt7921e.ko*' | grep -q . || hk_fail 'Missing modular MT7921E'
}

hk_pack() {
    local release="$1" stage="$2" destination="$3"
    local dtb=meson-sm1-hk1box-vontar-x3.dtb component
    [[ -s "${stage}/dtb-amlogic/${dtb}" ]] || hk_fail "Missing HK1 Box DTB: ${dtb}"
    for component in "vmlinuz-${release}" "config-${release}" "System.map-${release}" \
        "initrd.img-${release}" "uInitrd-${release}"; do
        [[ -s "${stage}/boot/${component}" ]] || hk_fail "Missing boot file: ${component}"
    done
    hk_verify_custom_modules "${stage}/boot/config-${release}" "${stage}/modules/lib/modules/${release}"
    [[ -s "${stage}/header/Module.symvers" && -s "${stage}/header/Makefile" ]] || hk_fail 'Missing built headers'
    mkdir -p "${destination}"
    for component in boot dtb-amlogic modules header; do
        tar -czf "${destination}/${component}-${release}.tar.gz" -C "${stage}/${component}" .
    done
    (cd "${destination}"; sha256sum "boot-${release}.tar.gz" "dtb-amlogic-${release}.tar.gz" \
        "modules-${release}.tar.gz" "header-${release}.tar.gz" > sha256sums; sha256sum -c sha256sums)
}

hk_main() {
    [[ -f /.dockerenv && "$(uname -m)" == aarch64 && "$PWD" != /boot ]] || hk_fail 'Run scripts/build_hk1box.sh: builder requires an arm64 Docker container'
    hk_stage '1. HK1 Box build dependencies'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends git ca-certificates build-essential bc bison flex \
        libssl-dev libelf-dev dwarves python3 rsync kmod cpio gzip xz-utils zstd \
        initramfs-tools u-boot-tools file
    git config --global --add safe.directory /repo
    cd /builder
    for pair in "kernel:https://github.com/ophub/linux-${HK1BOX_KERNEL_SERIES}.y.git:${HK1BOX_KERNEL_COMMIT}" \
        "config:https://github.com/ophub/kernel.git:${HK1BOX_CONFIG_COMMIT}"; do
        local name="${pair%%:*}" rest="${pair#*:}" commit="${pair##*:}"
        local repository="${rest%:*}"
        git init "${name}"
        git -C "${name}" remote add origin "${repository}"
        git -C "${name}" fetch --depth 1 origin "${commit}"
        git -C "${name}" checkout --detach FETCH_HEAD
        [[ "$(git -C "${name}" rev-parse HEAD)" == "${commit}" ]] || hk_fail 'Fetched source SHA mismatch'
    done
    cd /builder/kernel
    local source_version release stage=/builder/stage bundle=/builder/bundle
    source_version="$(make -s ARCH=arm64 kernelversion)"
    [[ "${source_version}" =~ ^${HK1BOX_KERNEL_SERIES//./\.}\.[0-9]+$ ]] || hk_fail "Unexpected kernel version: ${source_version}"
    cp "/builder/config/kernel-config/release/stable/config-${HK1BOX_KERNEL_SERIES}" .config
    local template_sha
    template_sha="$(sha256sum .config | awk '{print $1}')"
    source /repo/userpatches/lib.config
    source /repo/userpatches/extensions/kernel-inject-evidence.sh
    hk_stage '2. HK1 Box source injection and final configuration'
    hk_prepare_config
    release="$(make -s ARCH=arm64 kernelrelease)"
    [[ "${release}" == "${source_version}-hk1box" ]] || hk_fail "Unexpected release: ${release}"
    hk_stage '3. HK1 Box Image modules and device trees'
    make ARCH=arm64 -j"${HK1BOX_JOBS}" Image modules dtbs
    _kernel_inject_verify_full_ebpf_config .config
    _kernel_inject_verify_full_network_config .config
    mkdir -p "${stage}"/{boot,dtb-amlogic,modules,header,evidence}
    make ARCH=arm64 INSTALL_MOD_PATH="${stage}/modules" INSTALL_MOD_STRIP=1 modules_install
    local modules="${stage}/modules/lib/modules/${release}"
    # Remove build-machine links; ophub's installer creates its own header link.
    rm -f -- "${modules}/build" "${modules}/source"
    depmod -b "${stage}/modules" "${release}"
    cp .config "${stage}/boot/config-${release}"
    cp System.map "${stage}/boot/System.map-${release}"
    cp arch/arm64/boot/Image "${stage}/boot/vmlinuz-${release}"
    cp arch/arm64/boot/dts/amlogic/*.dtb "${stage}/dtb-amlogic/"
    # Retain prepared headers and native Kbuild tools, without all kernel objects.
    cp -a include scripts "${stage}/header/"
    mkdir -p "${stage}/header/arch/arm64"
    cp -a arch/arm64/include "${stage}/header/arch/arm64/"
    cp -a arch/arm64/tools "${stage}/header/arch/arm64/"
    cp Makefile .config Module.symvers "${stage}/header/"
    cp COPYING "${stage}/header/"
    find arch/arm64 -name 'Makefile*' -o -name 'Kbuild*' | while IFS= read -r path; do
        mkdir -p "${stage}/header/$(dirname "${path}")"; cp "${path}" "${stage}/header/${path}"
    done
    if [[ -x tools/objtool/objtool ]]; then
        mkdir -p "${stage}/header/tools/objtool"; cp tools/objtool/objtool "${stage}/header/tools/objtool/"
    fi
    hk_verify_custom_modules .config "${modules}"
    hk_stage '4. HK1 Box initramfs and package evidence'
    # /lib/modules exists only inside this disposable container.
    mkdir -p /lib/modules /boot
    cp -a "${modules}" "/lib/modules/${release}"
    cp .config "/boot/config-${release}"
    mkinitramfs -o "${stage}/boot/initrd.img-${release}" "${release}"
    mkimage -A arm -O linux -T ramdisk -C none -n uInitrd \
        -d "${stage}/boot/initrd.img-${release}" "${stage}/boot/uInitrd-${release}"
    # Reuse the evidence producer with explicit platform metadata.
    local kernel_work_dir=/builder/kernel package_directory="${stage}/evidence"
    local kernel_version_family="${release}" KERNEL_SRC_ARCH=arm64 ARCH=arm64
    local BOARD=hk1box BRANCH=hk1box LINUXFAMILY=meson64 KERNEL_MAJOR_MINOR="${HK1BOX_KERNEL_SERIES}"
    local LINUXCONFIG="ophub-config-${HK1BOX_KERNEL_SERIES}" SRC=/repo WORKDIR=/builder
    pre_package_kernel_image__kernel_inject_evidence
    local evidence="${stage}/evidence/usr/lib/armbian-kernel-build/${release}"
    cp -a "${stage}/evidence/usr" "${stage}/modules/"
    {
        printf 'build_repository_commit=%s\n' "${BUILD_REPOSITORY_COMMIT}"
        printf 'ophub_config_commit=%s\n' "${HK1BOX_CONFIG_COMMIT}"
        printf 'ophub_template_sha256=%s\n' "${template_sha}"
        printf 'builder_image_id=%s\n' "${HK1BOX_IMAGE_ID}"
        printf 'dtb=%s\n' meson-sm1-hk1box-vontar-x3.dtb
    } >> "${evidence}/source-manifest.env"
    cp "${evidence}/source-manifest.env" "${stage}/modules/usr/lib/armbian-kernel-build/${release}/source-manifest.env"
    hk_pack "${release}" "${stage}" "${bundle}"
    # Verify evidence by reading the actual installation archive.
    tar -xOf "${bundle}/modules-${release}.tar.gz" \
        "./usr/lib/armbian-kernel-build/${release}/kernel.config" | cmp - .config
    local output=/output/hk1box metadata=/builder/metadata
    mkdir -p "${output}" "${metadata}"
    # Build in a fresh directory and replace only the completed bundle atomically.
    tar -czf "/builder/${release}.tar.gz" -C "${bundle}" .
    cp "/builder/${release}.tar.gz" "${output}/.${release}.tar.gz.tmp"
    mv "${output}/.${release}.tar.gz.tmp" "${output}/${release}.tar.gz"
    (cd "${output}"; sha256sum "${release}.tar.gz" > "${release}.tar.gz.sha256")
    cp "${evidence}/kernel.config" "${metadata}/hk1box-kernel.config"
    cp "${evidence}/source-manifest.env" "${metadata}/hk1box-source-manifest.env"
    cp "${evidence}/config-vs-arm64-defconfig.txt" "${metadata}/hk1box-config-vs-arm64-defconfig.txt"
    cp "${evidence}/arm64-defconfig-build.log" "${metadata}/hk1box-defconfig-build.log"
    # Show the actual changes from the ophub template, not just arm64 defconfig.
    scripts/diffconfig "/builder/config/kernel-config/release/stable/config-${HK1BOX_KERNEL_SERIES}" \
        .config > "${metadata}/hk1box-config-vs-ophub-template.txt"
    local module path asset
    local -a radio_modules=(6lowpan bluetooth rfcomm bnep hidp bluetooth_6lowpan \
        rfkill cfg80211 mac80211 mt76 mt76-connac-lib mt792x-lib mt7921-common mt7921e)
    : > "${metadata}/hk1box-loadable-modules-SHA256SUMS"
    for module in "${radio_modules[@]}"; do
        local -a matches=()
        mapfile -d '' -t matches < <(find "${modules}" -type f -name "${module}.ko" -print0)
        ((${#matches[@]} == 1)) || hk_fail "Expected one ${module}.ko, got ${#matches[@]}"
        path="${matches[0]}"
        asset="hk1box-${release}-arm64-${module}.ko"
        cp "${path}" "${metadata}/${asset}"
        (cd "${metadata}"; sha256sum "${asset}" >> hk1box-loadable-modules-SHA256SUMS)
    done
    cat > "${metadata}/hk1box-loadable-modules.md" <<EOF
Install the complete HK1 Box kernel bundle first; it includes these modules and dependencies.
Then boot into \`${release}\` and run \`sudo modprobe mt7921e\` or \`sudo modprobe bnep\`.
MT7921E requires a connected compatible PCIe device and MediaTek firmware.

Standalone attachments require exactly \`${release}\` on arm64. In an empty directory:

\`\`\`bash
sha256sum -c hk1box-loadable-modules-SHA256SUMS
test "\$(uname -r)" = '${release}'
test "\$(dpkg --print-architecture)" = arm64
sudo install -d -m 0755 /lib/modules/${release}/extra
for attachment in hk1box-${release}-arm64-*.ko; do
    sudo install -m 0644 "\$attachment" "/lib/modules/${release}/extra/\${attachment#hk1box-${release}-arm64-}"
done
sudo depmod -a ${release}
sudo modprobe mt7921e
\`\`\`

Standalone modules do not supply the device's firmware or all possible distribution dependencies.
Use the full installation bundle on a fresh system.
EOF
    cat > "${metadata}/build-summary.md" <<EOF
HK1 Box / S905X3 custom kernel: \`${release}\` (arm64 / meson64).

- Source: ophub/linux-${HK1BOX_KERNEL_SERIES}.y @ ${HK1BOX_KERNEL_COMMIT}
- Config template: ophub/kernel @ ${HK1BOX_CONFIG_COMMIT}
- Build repository: ${BUILD_REPOSITORY_COMMIT}
- DTB: \`meson-sm1-hk1box-vontar-x3.dtb\` (standard, not overclocked)
- TCP-Brutal: built-in @ ${TCP_BRUTAL_COMMIT}
- AmneziaWG: built-in @ ${AMNEZIAWG_COMMIT}; native WireGuard disabled
- nf_deaf: built-in @ ${NF_DEAF_COMMIT}
- Full eBPF/BTF/CO-RE and networking verified after olddefconfig.
- Wi-Fi/MT7921E and Bluetooth remain modules; existing device firmware is needed.
- Final config, source pins and defconfig diff are embedded in the modules archive.
- Actual changes from the ophub template are attached as hk1box-config-vs-ophub-template.txt.
- Bluetooth/Wi-Fi standalone modules and their checksum/install guide are attached.

Installation on an existing ophub Armbian system:

1. Extract \`${release}.tar.gz\` into an empty directory on the HK1 Box.
2. Run \`sha256sum -c sha256sums\` there.
3. Run \`sudo armbian-update -k ${release} -d tar\` there.
4. Retain your existing uEnv.txt root UUID and FDT; reboot and check \`uname -r\`.

Keep a backup and recovery SD/USB available for the first boot. No U-Boot, uEnv.txt,
root UUID or overclock settings are included in this kernel bundle.
EOF
    cp "${metadata}/build-summary.md" "${metadata}/hk1box-install.md"
    mkdir -p /output/release-metadata
    local ready_metadata
    ready_metadata="$(mktemp -d /output/release-metadata/.hk1box-ready.XXXXXX)"
    cp -a "${metadata}/." "${ready_metadata}/"
    if [[ -e /output/release-metadata/hk1box ]]; then
        local previous_metadata
        previous_metadata="$(mktemp -d "${output}/metadata-history.XXXXXX")"
        mv /output/release-metadata/hk1box "${previous_metadata}/hk1box"
    fi
    mv "${ready_metadata}" /output/release-metadata/hk1box
    printf '%s\n' "${release}" > /builder/kernel-release
    hk_stage '5. HK1 Box installation bundle verified'
    hk_finish_stage
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then hk_main "$@"; fi
