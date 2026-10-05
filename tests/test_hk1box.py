"""Contracts for shared Armbian target profiles and the HK1 Box adaptation."""
import gzip
import hashlib
import os
from pathlib import Path
import shutil
import shlex
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt" else shutil.which("bash")


class TargetTests(unittest.TestCase):
    def run_bash(self, script, **variables):
        env = os.environ.copy()
        # Strip every variable the scripts under test may read, not just the
        # target selector. A stray GITHUB_* or ACTIONS_* value inherited from the
        # host would silently flip a publish/dry-run code path and make the
        # result depend on where the suite happens to run.
        for key in list(env):
            if key.startswith(("GITHUB_", "ACTIONS_", "RUNNER_")):
                env.pop(key, None)
        for key in ("BUILD_TARGET", "BUILD_BRANCH", "BUILD_FAMILY", "BUILD_FORCE",
                    "BUILD_PUBLISH", "BUILD_TARGETS_DIR"):
            env.pop(key, None)
        env.update(variables)
        return subprocess.run([BASH, "-c", script], cwd=ROOT, env=env,
                              text=True, capture_output=True)

    @staticmethod
    def write_arm64_image(path, text_offset=0x01080000, magic=b"ARM\x64"):
        image = bytearray(64)
        image[8:16] = text_offset.to_bytes(8, "little")
        image[56:60] = magic
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(image)

    def profile_board_dtb(self, target="hk1box"):
        """Read TARGET_BOARD_DTB straight out of the target profile.

        Tests must not restate a value the profile already owns, otherwise a
        profile rename silently leaves the fixtures pointing at a stale path and
        the suite keeps passing against a contract that no longer exists.
        """
        import re
        profile = (ROOT / "userpatches" / "config" / "build-targets" / f"{target}.conf").read_text()
        match = re.search(r'^TARGET_BOARD_DTB="?([^"\s]+)"?', profile, re.M)
        self.assertIsNotNone(match, f"{target}.conf declares no TARGET_BOARD_DTB")
        return match.group(1)

    @staticmethod
    def source_packaging(target="hk1box"):
        """Source the packaging script with its target profile already loaded.

        The packaging script is board-agnostic and refuses to run without a
        target, so tests must name the target whose profile supplies the boot
        contract. Building the prefix here keeps every fixture honest about
        which profile it exercises.

        The load is wrapped in an explicit if: `load_build_target` returning
        non-zero does not abort a plain `bash -c` script, so without this a
        broken profile would let the test continue against unset fields and
        produce a confusing failure far from the real cause.
        """
        return (f'BUILD_TARGET={target}; source scripts/build_targets.sh; '
                f'load_build_target || exit 1; source scripts/package_ophub_tar.sh')

    def test_rockchip_defaults_unchanged(self):
        result = self.run_bash('source scripts/build_targets.sh; load_build_target; '
                               'printf "%s|%s|%s" "$BUILD_BOARD" "$BUILD_FAMILY" "${branch_list[*]}"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'nanopi-r5s|rockchip64|current edge bleedingedge')

    def test_hk1box_uses_meson_edge(self):
        result = self.run_bash('source scripts/build_targets.sh; load_build_target; '
                               'printf "%s|%s|%s|%s" "$BUILD_BOARD" "$BUILD_FAMILY" '
                               '"${branch_list[*]}" "$RELEASE_PREFIX"', BUILD_TARGET='hk1box')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'hk1box|meson64|edge|hk1box-')

    def test_invalid_profile_fails_before_dependencies(self):
        for target, branch in [('unknown', 'auto'), ('hk1box', 'current'), ('hk1box', 'bleedingedge')]:
            result = self.run_bash('bash build.sh', BUILD_TARGET=target, BUILD_BRANCH=branch)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('Environment initialization', result.stdout)

    def test_library_loading_does_not_build(self):
        result = self.run_bash('BUILD_SCRIPT_LIB_ONLY=yes source build.sh; echo loaded',
                               BUILD_TARGET='hk1box')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'loaded')

    def test_target_cli_is_read_only_and_cwd_independent(self):
        result = self.run_bash('cd /tmp; bash "$ENTRY" --describe-target hk1box', ENTRY=str(ROOT / 'build.sh').replace('\\', '/'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('arch=arm64\n', result.stdout)
        self.assertIn('runner=ubuntu-24.04-arm\n', result.stdout)
        self.assertNotIn('Environment initialization', result.stdout)

    def test_new_architecture_profile_requires_no_pipeline_edit(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            for arch, kbuild in [('armhf', 'arm'), ('amd64', 'x86'), ('riscv64', 'riscv')]:
                (path / f'test-{arch}.conf').write_text(
                    f'TARGET_BOARD=test-board\nTARGET_FAMILY=test-family\nTARGET_ARCH={arch}\n'
                    f'TARGET_KBUILD_ARCH={kbuild}\nTARGET_RUNNER=ubuntu-24.04\n'
                    'TARGET_VERSION_CONFIG=include/test-family_common.inc\n'
                    'TARGET_RELEASE_PREFIX=test-\nTARGET_ADAPTER=deb\n'
                    'TARGET_BRANCHES=(edge)\nTARGET_SERIES=()\nTARGET_BOARD_DTB=""\nTARGET_REQUIRED_Y=()\n')
                result = self.run_bash(f'bash build.sh --describe-target test-{arch}', BUILD_TARGETS_DIR=path.as_posix())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f'arch={arch}\n', result.stdout)
                self.assertIn(f'kbuild_arch={kbuild}\n', result.stdout)
            result = self.run_bash('bash build.sh --list-targets', BUILD_TARGETS_DIR=path.as_posix())
            self.assertEqual(set(result.stdout.splitlines()), {'test-armhf', 'test-amd64', 'test-riscv64'})

    def test_target_loads_do_not_leak_prior_adapter_or_restrictions(self):
        result = self.run_bash('source scripts/build_targets.sh; BUILD_TARGET=hk1box; load_build_target; '
                               'BUILD_TARGET=rockchip64; load_build_target; validate_target_series edge 8.0; '
                               '[[ ${#TARGET_REQUIRED_Y[@]} == 0 ]] || exit 1; '
                               'target_extra_release_assets 8.0; printf "%s" "${branch_list[*]}"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'current edge bleedingedge')

    def test_unsafe_target_identifiers_are_rejected(self):
        for target in ['../hk1box', 'hk1box;echo', '/tmp/target', 'hk1box\nrunner=evil']:
            self.assertNotEqual(self.run_bash('bash build.sh --describe-target "$NAME"', NAME=target).returncode, 0)

    def test_kernel_series_guard_is_profile_driven(self):
        result = self.run_bash('source scripts/build_targets.sh; load_build_target; validate_target_series edge 7.3',
                               BUILD_TARGET='hk1box')
        self.assertNotEqual(result.returncode, 0)
        # The diagnostic must name both series and hand back a concrete way out,
        # otherwise a version bump leaves the maintainer with no next step.
        self.assertIn('pinned to kernel series 7.2', result.stderr)
        self.assertIn('Armbian now configures 7.3', result.stderr)
        self.assertIn('userpatches/config/build-targets/hk1box.conf', result.stderr)

    def test_hk1box_board_is_registered_in_armbian_search_path(self):
        result = self.run_bash('BUILD_SCRIPT_LIB_ONLY=yes source build.sh; '
                               'validate_armbian_board_registration . hk1box')
        self.assertEqual(result.returncode, 0, result.stderr)
        # Diagnostics go to stderr: the whole log shares one stream so a piped
        # build keeps its ordering instead of interleaving by stdio buffering.
        self.assertIn('userpatches/config/boards/hk1box.conf', result.stderr)
        self.assertEqual(result.stdout, '')
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            wrong_path = tree / 'userpatches/boards/hk1box.conf'
            wrong_path.parent.mkdir(parents=True)
            wrong_path.write_text('KERNEL_TARGET=edge\n')
            script = ('BUILD_SCRIPT_LIB_ONLY=yes source build.sh; '
                      'validate_armbian_board_registration "$CASE_DIR" hk1box')
            self.assertNotEqual(self.run_bash(script, CASE_DIR=tree.as_posix()).returncode, 0)
            correct_path = tree / 'userpatches/config/boards/hk1box.conf'
            correct_path.parent.mkdir(parents=True)
            wrong_path.rename(correct_path)
            self.assertEqual(self.run_bash(script, CASE_DIR=tree.as_posix()).returncode, 0)

    def test_hk1box_boot_modes_override_module_requests(self):
        result = self.run_bash('''
set -e
USERPATCHES_PATH="$PWD/userpatches"
source userpatches/extensions/kernel-inject.sh
source userpatches/config/boards/hk1box.conf
declare -a opts_y=() opts_m=(DWMAC_MESON CONFIG_MMC_MESON_GX COMMON_CLK_G12A SERIAL_MESON) opts_n=(CONFIG_DWMAC_MESON CONFIG_PINCTRL_MESON_G12A) kernel_config_modifying_hashes=()
custom_kernel_config__999_hk1box_storage_and_network
[[ " ${opts_y[*]} " == *" DWMAC_MESON "* ]]
[[ " ${opts_m[*]} " != *"DWMAC_MESON"* ]]
[[ " ${opts_m[*]} " != *"MMC_MESON_GX"* ]]
[[ " ${opts_n[*]} " != *"DWMAC_MESON"* ]]
[[ " ${opts_y[*]} " != *"DWMAC_MESON8B"* ]]
[[ " ${opts_y[*]} " == *" COMMON_CLK_G12A "* && " ${opts_m[*]} " != *"COMMON_CLK_G12A"* ]]
[[ " ${opts_y[*]} " == *" SERIAL_MESON "* && " ${opts_m[*]} " != *"SERIAL_MESON"* ]]
[[ " ${opts_y[*]} " == *" SERIAL_MESON_CONSOLE "* ]]
[[ " ${opts_y[*]} " == *" PINCTRL_MESON_G12A "* && " ${opts_n[*]} " != *"PINCTRL_MESON_G12A"* ]]
[[ " ${kernel_config_modifying_hashes[*]} " == *"hk1box-required=DWMAC_MESON=y"* ]]
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_hk1box_unknown_driver_fails_before_compilation(self):
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            (tree / '.config').touch()
            (tree / 'Kconfig').write_text('config MMC\n    bool "fixture"\n')
            result = self.run_bash('''
USERPATCHES_PATH="$PWD/userpatches"
source userpatches/extensions/kernel-inject.sh
source userpatches/config/boards/hk1box.conf
declare -a opts_y=() opts_m=() opts_n=() kernel_config_modifying_hashes=()
cd "$CASE_DIR"
custom_kernel_config__999_hk1box_storage_and_network
''', CASE_DIR=tree.as_posix())
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Unknown board Kconfig symbol', result.stderr)
            self.assertIn('CONFIG_ARCH_MESON', result.stderr)

    def test_generic_board_contract_checks_packaged_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            evidence = tree / 'evidence'
            evidence.mkdir()
            (evidence / 'board.dts').write_bytes(b'fixture')
            (evidence / 'source-manifest.env').write_text(
                'board=test-board\nboard_dtb=vendor/test-board.dtb\n'
                f'board_dts_sha256={hashlib.sha256(b"fixture").hexdigest()}\n')
            (evidence / 'kernel.config').write_text('CONFIG_MMC=y\n')
            dtb = tree / 'image/usr/lib/linux-image-test/vendor/test-board.dtb'
            dtb.parent.mkdir(parents=True)
            dtb.write_bytes(b'fixture')
            script = '''source scripts/lib/board-contract.sh
require_manifest_value() { sed -n "s/^$2=//p" "$1"; }
_kernel_inject_log() { printf '%s\\n' "$*" >&2; }
TARGET_BOARD=test-board
TARGET_BOARD_DTB=vendor/test-board.dtb
TARGET_REQUIRED_Y=(MMC)
validate_board_contract "$CASE_DIR/evidence" "$CASE_DIR/image" "$CASE_DIR/evidence/kernel.config"
'''
            self.assertEqual(self.run_bash(script, CASE_DIR=tree.as_posix()).returncode, 0)
            (evidence / 'kernel.config').write_text('CONFIG_MMC=m\n')
            self.assertNotEqual(self.run_bash(script, CASE_DIR=tree.as_posix()).returncode, 0)
            (evidence / 'kernel.config').write_text('CONFIG_MMC=y\n')
            (evidence / 'board.dts').write_bytes(b'wrong source')
            self.assertNotEqual(self.run_bash(script, CASE_DIR=tree.as_posix()).returncode, 0)
            (evidence / 'board.dts').write_bytes(b'fixture')
            dtb.unlink()
            self.assertNotEqual(self.run_bash(script, CASE_DIR=tree.as_posix()).returncode, 0)

    def test_wrong_package_version_fails_without_docker(self):
        result = self.run_bash('bash scripts/package_ophub_tar.sh edge /does-not-exist 6.12.111')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('docker', result.stderr)

    def test_device_tree_patches_match_hk1box_boot_contract(self):
        patches = [
            ROOT / 'userpatches/kernel/archive/meson64-7.2/0001-hk1box-mainline-dtb.patch',
            ROOT / 'userpatches/kernel/archive/meson64-7.2/0002-hk1box-memory-map.patch',
            ROOT / 'userpatches/kernel/archive/meson64-7.2/0004-hk1box-mmc-aliases.patch',
        ]
        with tempfile.TemporaryDirectory() as temporary:
            tree = Path(temporary)
            dts_dir = tree / 'arch/arm64/boot/dts/amlogic'
            dts_dir.mkdir(parents=True)
            (dts_dir / 'Makefile').write_text(''.join(
                f'dtb-$(CONFIG_ARCH_MESON) += {board}.dtb\n' for board in [
                    'meson-sm1-odroid-c4', 'meson-sm1-odroid-hc4', 'meson-sm1-sei610',
                    'meson-sm1-x96-air-gbit', 'meson-sm1-x96-air']))
            shared = dts_dir / 'meson-g12-common.dtsi'
            shared.write_text('/ { aliases { mmc0 = &sd_emmc_b; mmc1 = &sd_emmc_c; mmc2 = &sd_emmc_a; }; };\n')
            original_shared = shared.read_bytes()
            for patch in patches:
                result = subprocess.run(['git', 'apply', str(patch)], cwd=tree, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            dts = (dts_dir / 'meson-sm1-hk1box-vontar-x3.dts').read_text()
            self.assertIn('#include "meson-sm1-ac2xx.dtsi"', dts)
            self.assertNotIn('opp-hz =', dts)
            self.assertIn('/delete-node/ opp-2100000000;', dts)
            self.assertIn('reg = <0x0 0x0 0x0 0xFFFFFFFF>;', dts)
            self.assertIn('/delete-property/ sd-uhs-sdr104;', dts)
            self.assertIn('max-frequency = <25000000>', dts)
            self.assertIn('mmc0 = &sd_emmc_a;', dts)
            self.assertIn('mmc1 = &sd_emmc_b;', dts)
            self.assertIn('mmc2 = &sd_emmc_c;', dts)
            self.assertEqual(shared.read_bytes(), original_shared)

    def test_legacy_amlogic_text_offset_patch_applies_to_linux_7_2_layout(self):
        patch = ROOT / 'userpatches/kernel/archive/meson64-7.2/0003-amlogic-legacy-text-offset.patch'
        with tempfile.TemporaryDirectory() as temporary:
            tree = Path(temporary)
            kernel = tree / 'arch/arm64/kernel'
            kernel.mkdir(parents=True)
            (kernel / 'head.S').write_text(
                '\t/*\n\t * DO NOT MODIFY. Image header expected by Linux boot-loaders.\n\t */\n'
                '\tefi_signature_nop\t\t\t// special NOP to identity as PE/COFF executable\n'
                '\tb\tprimary_entry\t\t\t// branch to kernel start, magic\n'
                '\t.quad\t0\t\t\t\t// Image load offset from start of RAM, little-endian\n'
                '\tle64sym\t_kernel_size_le\t\t\t// Effective size of kernel image, little-endian\n'
                '\tle64sym\t_kernel_flags_le\t\t// Informative flags, little-endian\n'
                '\t.quad\t0\t\t\t\t// reserved\n')
            (kernel / 'image.h').write_text(
                '/* regardless of the endianness of the kernel. While constant values could be\n'
                ' * endian swapped in head.S, all are done here for consistency.\n */\n'
                '#define HEAD_SYMBOLS\t\t\t\t\t\t\\\n'
                '\tDEFINE_IMAGE_LE64(_kernel_size_le, _end - _text);\t\\\n'
                '\tDEFINE_IMAGE_LE64(_kernel_flags_le, __HEAD_FLAGS);\n\n'
                '#endif /* __ARM64_KERNEL_IMAGE_H */\n')
            (kernel / 'setup.c').write_text(
                '\tefi_init();\n\n\tif (!efi_enabled(EFI_BOOT)) {\n'
                '\t\tif ((u64)_text % MIN_KIMG_ALIGN)\n'
                '\t\t\tpr_warn(FW_BUG "Kernel image misaligned at boot, please fix your bootloader!");\n'
                '\t\tWARN_TAINT(mmu_enabled_at_boot, TAINT_FIRMWARE_WORKAROUND,\n'
                '\t\t\t   FW_BUG "Booted with MMU enabled!");\n\t}\n')
            result = subprocess.run(['git', 'apply', str(patch)], cwd=tree, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('le64sym\t_kernel_offset_le', (kernel / 'head.S').read_text())
            self.assertIn('#define TEXT_OFFSET 0x01080000', (kernel / 'image.h').read_text())
            self.assertIn('DEFINE_IMAGE_LE64(_kernel_offset_le, TEXT_OFFSET)', (kernel / 'image.h').read_text())
            self.assertNotIn('pr_warn(FW_BUG "Kernel image misaligned', (kernel / 'setup.c').read_text())

    def test_hk1box_kernel_image_header_is_mandatory(self):
        with tempfile.TemporaryDirectory() as temporary:
            tree = Path(temporary)
            good = tree / 'Image.good'
            zero_offset = tree / 'Image.zero-offset'
            bad_magic = tree / 'Image.bad-magic'
            self.write_arm64_image(good)
            self.write_arm64_image(zero_offset, text_offset=0)
            self.write_arm64_image(bad_magic, magic=b'BAD!')
            command = self.source_packaging() + '; validate_kernel_image_header "$IMAGE"'
            self.assertEqual(self.run_bash(command, IMAGE=good.as_posix()).returncode, 0)
            result = self.run_bash(command, IMAGE=zero_offset.as_posix())
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('TEXT_OFFSET 0x01080000', result.stderr)
            result = self.run_bash(command, IMAGE=bad_magic.as_posix())
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('not a raw ARM64 Image', result.stderr)

    def test_hk1box_uinitrd_is_arm64_gzip(self):
        release = '7.2.8-edge-meson64'
        with tempfile.TemporaryDirectory() as temporary:
            tree = Path(temporary)
            stage = tree / 'stage'
            bindir = tree / 'bin'
            call_log = tree / 'calls.log'
            (stage / 'boot').mkdir(parents=True)
            bindir.mkdir()
            # The stubs must emit real container bytes. Asserting only on the
            # recorded command line proves nothing about the artifacts: an empty
            # file satisfies every previous assertion here, which is exactly the
            # kind of fake pass this test is meant to prevent. Both stubs stay in
            # POSIX shell + coreutils so they do not depend on python being on
            # PATH inside the harness. mkimage writes the 64-byte big-endian
            # uImage header that U-Boot actually parses, with type=ramdisk(4).
            mkinitramfs = bindir / 'mkinitramfs'
            mkinitramfs.write_text(
                '#!/usr/bin/env bash\nset -eu\nprintf "mkinitramfs %s\\n" "$*" >> "$CALL_LOG"\n'
                'out=""\nversion=""\nprev=""\n'
                'for arg in "$@"; do\n'
                '  if [[ "$prev" == "-o" ]]; then out="$arg"; prev=""; continue; fi\n'
                '  prev="$arg"\n'
                # The compressor name after -c is a positional too, so take the
                # last one rather than the first: that is the VERSION Armbian
                # passes to mkinitramfs.
                '  [[ "$arg" == -* ]] || version="$arg"\n'
                'done\n'
                'printf "initramfs payload for %s" "$version" | gzip -c > "$out"\n')
            mkimage = bindir / 'mkimage'
            mkimage.write_text(
                '#!/usr/bin/env bash\nset -eu\nprintf "mkimage %s\\n" "$*" >> "$CALL_LOG"\n'
                'data=""\nprev=""\nfor arg in "$@"; do\n'
                '  if [[ "$prev" == -d ]]; then data="$arg"; fi\n  prev="$arg"\n'
                'done\n'
                'out="${@: -1}"\n'
                # magic 0x27051956, hcrc/time/size/data_crc/os = 0, type = 4, then
                # zero padding out to the 64-byte fixed header.
                '{ printf "\\x27\\x05\\x19\\x56"; printf "\\0%.0s" {1..20};'
                ' printf "\\0\\0\\0\\x04"; printf "\\0%.0s" {1..36}; } > "$out"\n'
                'cat "$data" >> "$out"\n')
            mkinitramfs.chmod(0o755)
            mkimage.chmod(0o755)
            result = self.run_bash(
                self.source_packaging() + '; build_arm64_uinitrd "$STAGE" "$RELEASE"',
                STAGE=stage.as_posix(), RELEASE=release,
                PATH=f'{bindir}{os.pathsep}{os.environ.get("PATH", "")}', CALL_LOG=call_log.as_posix())
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = call_log.read_text()
            self.assertIn('mkinitramfs -c gzip -o ', calls)
            self.assertIn(f' {release}', calls)
            self.assertIn('mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd', calls)

            initrd = stage / f'boot/initrd.img-{release}'
            uinitrd = stage / f'boot/uInitrd-{release}'
            self.assertTrue(initrd.is_file())
            self.assertTrue(uinitrd.is_file())

            # The initramfs must be a real gzip stream that inflates back to the
            # payload, not merely a file with the right name.
            self.assertEqual(initrd.read_bytes()[:2], b'\x1f\x8b')
            with gzip.open(initrd, 'rb') as handle:
                payload = handle.read()
            self.assertEqual(payload, b'initramfs payload for ' + release.encode())

            # The uImage must carry the ARM64 ramdisk header U-Boot reads, and its
            # embedded payload must be byte-identical to the initramfs.
            blob = uinitrd.read_bytes()
            self.assertGreaterEqual(len(blob), 64, 'uImage is shorter than its fixed header')
            magic, hcrc, _time, _size, data_crc, os_id, type_id = struct.unpack('>7I', blob[:28])
            self.assertEqual(magic, 0x27051956)
            self.assertEqual(hcrc, 0)
            self.assertEqual(data_crc, 0)
            self.assertEqual(os_id, 0, 'uImage OS field must be Linux (0)')
            self.assertEqual(type_id, 4, 'uImage type must be ramdisk (4)')
            self.assertEqual(blob[64:], initrd.read_bytes(),
                             'uImage payload must be the exact initramfs it wraps')

    def test_compiled_dtb_contract_rejects_wrong_or_missing_properties(self):
        command = self.source_packaging() + '''
fdtget() {
    [[ "$5" != "${FAIL_PROPERTY:-}" ]] || return 1
    case "$5" in
        mmc0) printf '%s\\n' "$MMC0";;
        mmc1) echo /soc/mmc@ffe05000;;
        mmc2) echo /soc/mmc@ffe07000;;
        reg) printf '%s\\n' "$MEMORY";;
        *) return 1;;
    esac
}
validate_board_dtb fixture.dtb
'''
        good = {'MMC0': '/soc/mmc@ffe03000', 'MEMORY': '0 0 0 ffffffff'}
        self.assertEqual(self.run_bash(command, **good).returncode, 0)
        for override, diagnostic in [
            ({'MMC0': '/soc/mmc@ffe05000'}, 'mmc0 must identify controller'),
            ({'MEMORY': '0 0 0 40000000'}, 'DTB memory declaration mismatch'),
            ({'MEMORY': '0 0 0 ffffffff 0 0'}, 'DTB memory declaration mismatch'),
        ]:
            with self.subTest(override=override):
                result = self.run_bash(command, **dict(good, **override))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)
        for property_name in ['mmc1', 'reg']:
            self.assertNotEqual(self.run_bash(command, **good, FAIL_PROPERTY=property_name).returncode, 0)

    def test_tar_payload_matches_ophub_installer(self):
        release = '7.2.8-edge-meson64'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'root'
            stage = Path(temporary) / 'stage'
            image = root / f'boot/vmlinuz-{release}'
            self.write_arm64_image(image)
            dtb_rel = self.profile_board_dtb()
            for name in [f'boot/config-{release}', f'boot/System.map-{release}',
                         f'boot/dtb-{release}/{dtb_rel}',
                         f'lib/modules/{release}/modules.builtin',
                         f'usr/lib/armbian-kernel-build/{release}/source-manifest.env',
                         f'usr/src/linux-headers-{release}/include/test.h']:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('fixture')
            script = (self.source_packaging() + '; '
                      'fdtget() { case "$5" in '
                      'mmc0) echo /soc/mmc@ffe03000;; mmc1) echo /soc/mmc@ffe05000;; '
                      'mmc2) echo /soc/mmc@ffe07000;; reg) echo "0 0 0 ffffffff";; '
                      '*) return 1;; esac; }; stage_bundle_payload '
                      f'{shlex.quote(root.as_posix())} {shlex.quote(stage.as_posix())} {release}')
            # The DTB path is profile-driven (P0-2): the host passes it in
            # instead of the worker hardcoding amlogic/. Deriving it from the
            # profile here keeps the test honest about that contract.
            result = self.run_bash(script, PACKAGE_DTB=dtb_rel)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((stage / f'modules/{release}/modules.builtin').is_file())
            self.assertFalse((stage / 'modules/lib/modules').exists())
            self.assertTrue((stage / f'modules/{release}/armbian-kernel-build/source-manifest.env').is_file())
            self.assertTrue((stage / f'dtb/{Path(dtb_rel).name}').is_file())
            self.assertTrue((stage / 'header/include/test.h').is_file())

            # Without the profile-provided DTB location the step must refuse to
            # guess rather than fall back to a hardcoded vendor path.
            missing = self.run_bash(script, PACKAGE_DTB='')
            self.assertNotEqual(missing.returncode, 0)
            (root / f'boot/dtb-{release}/{dtb_rel}').unlink()
            self.assertNotEqual(self.run_bash(script, PACKAGE_DTB=dtb_rel).returncode, 0)


class TargetExtensibilityTests(unittest.TestCase):
    """Adding a target must be a config change, not a code change.

    These are the regression tests for that claim. If any of them needs an edit
    outside userpatches/config/, the "add a target by adding a file" contract has
    been broken again.
    """

    def setUp(self):
        # A throwaway copy of the repo skeleton, so scaffolding writes into a
        # temporary tree instead of the real working copy.
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        (self.root / 'scripts' / 'lib' / 'adapters').mkdir(parents=True)
        (self.root / 'userpatches' / 'config' / 'build-targets').mkdir(parents=True)
        (self.root / 'userpatches' / 'config' / 'boards').mkdir(parents=True)
        # The loader resolves the profile, the adapters and the packaging script
        # from BUILD_PROJECT_ROOT, so all of them have to exist in the fake tree.
        # logging.sh is not optional: targets.sh sources it itself, because the
        # regression tests source targets.sh directly and the Docker wrapper
        # sources it without the rest of the library set.
        shutil.copy(ROOT / 'scripts' / 'lib' / 'targets.sh', self.root / 'scripts' / 'lib')
        shutil.copy(ROOT / 'scripts' / 'lib' / 'logging.sh', self.root / 'scripts' / 'lib')
        shutil.copy(ROOT / 'scripts' / 'package_ophub_tar.sh', self.root / 'scripts')
        for adapter in (ROOT / 'scripts' / 'lib' / 'adapters').glob('*.sh'):
            shutil.copy(adapter, self.root / 'scripts' / 'lib' / 'adapters' / adapter.name)
        self.addCleanup(self.directory.cleanup)

    def run_bash(self, script, **variables):
        env = os.environ.copy()
        for key in list(env):
            if key.startswith(("GITHUB_", "ACTIONS_", "RUNNER_")):
                env.pop(key, None)
        for key in ("BUILD_TARGET", "BUILD_BRANCH", "BUILD_FAMILY", "BUILD_TARGETS_DIR"):
            env.pop(key, None)
        env.update(variables)
        env['BUILD_PROJECT_ROOT'] = self.root.as_posix()
        # Run inside the fake tree: the scaffolded shims resolve USERPATCHES_PATH
        # relative to wherever they are sourced from.
        return subprocess.run([BASH, '-c', script], cwd=self.root, env=env,
                              text=True, capture_output=True)

    def test_new_target_needs_one_file_and_no_code_edit(self):
        """A scaffolded target must load, and nothing outside config/ may change."""
        created = self.run_bash('source scripts/lib/targets.sh; new_build_target fresh-board')
        self.assertEqual(created.returncode, 0, created.stderr)
        profile = self.root / 'userpatches' / 'config' / 'build-targets' / 'fresh-board.conf'
        board = self.root / 'userpatches' / 'config' / 'boards' / 'fresh-board.conf'
        self.assertTrue(profile.is_file())
        self.assertTrue(board.is_file())

        # The scaffolded profile must resolve through the real loader.
        loaded = self.run_bash(
            'source scripts/lib/targets.sh; BUILD_TARGET=fresh-board; load_build_target; '
            'describe_build_target')
        self.assertEqual(loaded.returncode, 0, loaded.stderr)
        self.assertIn('target=fresh-board\n', loaded.stdout)
        self.assertIn('board=fresh-board\n', loaded.stdout)
        self.assertIn('branches=current\n', loaded.stdout)

    def test_scaffolded_board_shim_delegates_to_the_profile(self):
        """The shim must source the profile, so board config cannot drift."""
        self.run_bash('source scripts/lib/targets.sh; new_build_target shim-board')
        script = '''
USERPATCHES_PATH="$PWD/userpatches"
source userpatches/config/boards/shim-board.conf
printf 'board=%s family=%s serial=%s\\n' "$TARGET_BOARD" "$TARGET_FAMILY" "$SERIALCON"
'''
        result = self.run_bash(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('board=shim-board family=rockchip64', result.stdout)

    def test_scaffolded_profile_documents_every_schema_field(self):
        """A new board author must be able to see the schema in the scaffold."""
        self.run_bash('source scripts/lib/targets.sh; new_build_target doc-board')
        text = (self.root / 'userpatches' / 'config' / 'build-targets' / 'doc-board.conf').read_text()
        for field in ('TARGET_BOARD', 'TARGET_FAMILY', 'TARGET_ARCH', 'TARGET_KBUILD_ARCH',
                      'TARGET_RUNNER', 'TARGET_VERSION_CONFIG', 'TARGET_ADAPTER',
                      'TARGET_BRANCHES', 'TARGET_SERIES', 'TARGET_BOARD_DTB',
                      'TARGET_BOOT_TEXT_OFFSET', 'TARGET_DTB_MMC_ALIASES',
                      'TARGET_DTB_MEMORY_REG', 'TARGET_REQUIRED_Y'):
            self.assertIn(field, text, f'{field} is undocumented in the scaffold')

    def test_scaffolding_refuses_to_clobber_an_existing_target(self):
        first = self.run_bash('source scripts/lib/targets.sh; new_build_target twice')
        self.assertEqual(first.returncode, 0, first.stderr)
        again = self.run_bash('source scripts/lib/targets.sh; new_build_target twice')
        self.assertNotEqual(again.returncode, 0)
        self.assertIn('already exists', again.stderr)

    def test_scaffolding_rejects_unsafe_target_ids(self):
        for bad in ('../escape', 'Uppercase', 'has space', 'semi;colon'):
            with self.subTest(target=bad):
                result = self.run_bash('source scripts/lib/targets.sh; new_build_target "$NAME"', NAME=bad)
                self.assertNotEqual(result.returncode, 0)

    def test_check_targets_reports_every_profile_not_just_the_selected_one(self):
        """A broken profile must be visible before it is ever built."""
        self.run_bash('source scripts/lib/targets.sh; new_build_target good-board')
        # A profile missing a required field, next to a healthy one.
        (self.root / 'userpatches' / 'config' / 'build-targets' / 'broken-board.conf').write_text(
            'TARGET_BOARD=broken-board\nTARGET_ADAPTER=deb\n')
        result = self.run_bash('source scripts/lib/targets.sh; check_all_targets')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('[OK]   good-board', result.stdout)
        self.assertIn('[FAIL] broken-board', result.stdout)
        # The diagnostic must say which field, not just that loading failed.
        self.assertIn('TARGET_FAMILY is required', result.stdout)

    def test_boot_contract_is_data_so_a_second_board_needs_no_script(self):
        """The point of the ophub-tar split: a different board, same code."""
        self.run_bash('source scripts/lib/targets.sh; new_build_target second-board')
        profile = self.root / 'userpatches' / 'config' / 'build-targets' / 'second-board.conf'
        profile.write_text(
            'TARGET_BOARD=second-board\n'
            'TARGET_FAMILY=meson64\n'
            'TARGET_ARCH=arm64\n'
            'TARGET_KBUILD_ARCH=arm64\n'
            'TARGET_RUNNER=ubuntu-24.04-arm\n'
            'TARGET_VERSION_CONFIG=include/meson64_common.inc\n'
            'TARGET_ADAPTER=ophub-tar\n'
            'TARGET_BRANCHES=(edge)\n'
            'declare -gA TARGET_SERIES=()\n'
            'TARGET_SERIES["edge"]=7.2\n'
            'TARGET_BOARD_DTB=amlogic/meson-sm1-other-board.dtb\n'
            'TARGET_BOOT_TEXT_OFFSET=00000000\n'
            'TARGET_DTB_MMC_ALIASES=(ffe03000)\n'
            "TARGET_DTB_MEMORY_REG='0 0 0 3fffffff'\n")
        result = self.run_bash(
            'source scripts/lib/targets.sh; BUILD_TARGET=second-board; load_build_target; '
            'describe_build_target')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('boot_text_offset=00000000\n', result.stdout)
        self.assertIn('dtb_memory_reg=0 0 0 3fffffff\n', result.stdout)
        # And the shared packaging script validates the new board's contract.
        check = self.run_bash(
            'BUILD_TARGET=second-board; source scripts/lib/targets.sh; load_build_target; '
            'source scripts/package_ophub_tar.sh; declare -F validate_board_dtb validate_kernel_image_header')
        self.assertEqual(check.returncode, 0, check.stderr)

    def test_profile_without_a_boot_contract_skips_those_checks(self):
        """Optional fields must be genuinely optional, not silently empty."""
        self.run_bash('source scripts/lib/targets.sh; new_build_target plain-board')
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / 'Image'
            # A plain image with no text_offset set: the magic check still runs.
            TargetTests.write_arm64_image(image, text_offset=0x12345678)
            result = self.run_bash(
                'BUILD_TARGET=plain-board; source scripts/lib/targets.sh; load_build_target; '
                'source scripts/package_ophub_tar.sh; validate_kernel_image_header "$IMAGE"',
                IMAGE=image.as_posix(),
                USERPATCHES_PATH=(self.root / 'userpatches').as_posix())
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_ophub_tar_adapter_rejects_a_target_that_cannot_be_packaged(self):
        """Fail at load time, not after an hour of compiling."""
        (self.root / 'userpatches' / 'config' / 'build-targets' / 'tar-nodtb.conf').write_text(
            'TARGET_BOARD=tar-nodtb\nTARGET_FAMILY=meson64\nTARGET_ARCH=arm64\n'
            'TARGET_KBUILD_ARCH=arm64\nTARGET_RUNNER=ubuntu-24.04-arm\n'
            'TARGET_VERSION_CONFIG=include/meson64_common.inc\n'
            'TARGET_ADAPTER=ophub-tar\nTARGET_BRANCHES=(edge)\n')
        result = self.run_bash(
            'source scripts/lib/targets.sh; BUILD_TARGET=tar-nodtb; load_build_target')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('declares no TARGET_BOARD_DTB', result.stderr)

        # With a DTB declared, the missing series lock is the next hard stop:
        # the container validates the built release against it.
        (self.root / 'userpatches' / 'config' / 'build-targets' / 'tar-nodtb.conf').write_text(
            'TARGET_BOARD=tar-nodtb\nTARGET_FAMILY=meson64\nTARGET_ARCH=arm64\n'
            'TARGET_KBUILD_ARCH=arm64\nTARGET_RUNNER=ubuntu-24.04-arm\n'
            'TARGET_VERSION_CONFIG=include/meson64_common.inc\n'
            'TARGET_ADAPTER=ophub-tar\nTARGET_BRANCHES=(edge)\n'
            'TARGET_BOARD_DTB=amlogic/meson-sm1-other.dtb\n')
        result = self.run_bash(
            'source scripts/lib/targets.sh; BUILD_TARGET=tar-nodtb; load_build_target')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('TARGET_SERIES lock', result.stderr)

    def test_series_lock_for_an_unbuilt_branch_is_rejected(self):
        """A lock on a branch the target never builds is a silent no-op otherwise."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'odd.conf').write_text(
                'TARGET_BOARD=odd\nTARGET_FAMILY=rockchip64\nTARGET_ARCH=arm64\n'
                'TARGET_KBUILD_ARCH=arm64\nTARGET_RUNNER=ubuntu-24.04\n'
                'TARGET_VERSION_CONFIG=include/rockchip64_common.inc\n'
                'TARGET_ADAPTER=deb\nTARGET_BRANCHES=(current)\n'
                'declare -gA TARGET_SERIES=()\nTARGET_SERIES["edge"]=7.2\n')
            result = self.run_bash(
                'source scripts/lib/targets.sh; BUILD_TARGET=odd; '
                'if load_build_target; then describe_build_target; else exit 1; fi',
                BUILD_TARGETS_DIR=path.as_posix())
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('does not build that branch', result.stderr)

    def test_schema_is_the_single_source_for_reset_and_validation(self):
        """A field added to the schema must be reset and validated automatically."""
        result = self.run_bash('''
source scripts/lib/targets.sh
# Every schema field must be resettable, otherwise a second load in the same
# shell would inherit the first target's value.
seen=()
for entry in "${TARGET_SCHEMA[@]}"; do
    name="${entry%%|*}"
    _target_reset_schema
    if declare -p "${name}" > /dev/null 2>&1; then
        if [[ "${name}" == TARGET_BRANCHES || "${name}" == TARGET_SERIES || "${name}" == TARGET_REQUIRED_Y \\
           || "${name}" == TARGET_DTB_MMC_ALIASES ]]; then
            seen+=("array:${name}")
        else
            seen+=("LEAK:${name}")
        fi
    fi
done
printf '%s\\n' "${seen[@]}"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('LEAK:', result.stdout)
        # Every declared array field must be a real array, never the string "()".
        for entry in result.stdout.splitlines():
            self.assertTrue(entry.startswith('array:'), f'{entry} was not re-typed as an array')


if __name__ == '__main__':
    unittest.main()
