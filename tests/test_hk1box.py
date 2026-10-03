"""Contracts for shared Armbian target profiles and the HK1 Box adaptation."""
import hashlib
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt" else shutil.which("bash")


class TargetTests(unittest.TestCase):
    def run_bash(self, script, **variables):
        env = os.environ.copy()
        for key in ("BUILD_TARGET", "BUILD_BRANCH", "BUILD_FAMILY", "BUILD_FORCE", "BUILD_PUBLISH", "BUILD_TARGETS_DIR"):
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
        self.assertIn('requires kernel series 7.2', result.stderr)

    def test_hk1box_board_is_registered_in_armbian_search_path(self):
        result = self.run_bash('BUILD_SCRIPT_LIB_ONLY=yes source build.sh; '
                               'validate_armbian_board_registration . hk1box')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('userpatches/config/boards/hk1box.conf', result.stdout)
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
source userpatches/extensions/kernel-inject.sh
source userpatches/config/boards/hk1box.conf
USERPATCHES_PATH="$PWD/userpatches"
declare -a opts_y=() opts_m=(DWMAC_MESON CONFIG_MMC_MESON_GX) opts_n=(CONFIG_DWMAC_MESON) kernel_config_modifying_hashes=()
custom_kernel_config__999_hk1box_storage_and_network
[[ " ${opts_y[*]} " == *" DWMAC_MESON "* ]]
[[ " ${opts_m[*]} " != *"DWMAC_MESON"* ]]
[[ " ${opts_m[*]} " != *"MMC_MESON_GX"* ]]
[[ " ${opts_n[*]} " != *"DWMAC_MESON"* ]]
[[ " ${opts_y[*]} " != *"DWMAC_MESON8B"* ]]
[[ " ${kernel_config_modifying_hashes[*]} " == *"hk1box-required=DWMAC_MESON=y"* ]]
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_hk1box_unknown_driver_fails_before_compilation(self):
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            (tree / '.config').touch()
            (tree / 'Kconfig').write_text('config MMC\n    bool "fixture"\n')
            result = self.run_bash('''
source userpatches/extensions/kernel-inject.sh
source userpatches/config/boards/hk1box.conf
USERPATCHES_PATH="$PWD/userpatches"
declare -a opts_y=() opts_m=() opts_n=() kernel_config_modifying_hashes=()
cd "$CASE_DIR"
custom_kernel_config__999_hk1box_storage_and_network
''', CASE_DIR=tree.as_posix())
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Unknown board Kconfig symbol', result.stderr)
            self.assertIn('CONFIG_MMC_BLOCK', result.stderr)

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
        result = self.run_bash('bash scripts/package_hk1box.sh edge /does-not-exist 6.12.111')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('docker', result.stderr)

    def test_device_tree_patches_match_hk1box_boot_contract(self):
        patches = [
            ROOT / 'userpatches/kernel/archive/meson64-7.2/0001-hk1box-mainline-dtb.patch',
            ROOT / 'userpatches/kernel/archive/meson64-7.2/0002-hk1box-memory-map.patch',
        ]
        with tempfile.TemporaryDirectory() as temporary:
            tree = Path(temporary)
            dts_dir = tree / 'arch/arm64/boot/dts/amlogic'
            dts_dir.mkdir(parents=True)
            (dts_dir / 'Makefile').write_text('dtb-$(CONFIG_ARCH_MESON) += meson-sm1-sei610.dtb\n')
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
            command = 'source scripts/package_hk1box.sh; validate_hk1box_kernel_image "$IMAGE"'
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
            mkinitramfs = bindir / 'mkinitramfs'
            mkinitramfs.write_text(
                '#!/usr/bin/env bash\nset -eu\nprintf "mkinitramfs %s\\n" "$*" >> "$CALL_LOG"\n'
                'out=""\nwhile (($#)); do\n  if [[ "$1" == -o ]]; then out="$2"; shift 2; else shift; fi\ndone\n'
                ': > "$out"\n')
            mkimage = bindir / 'mkimage'
            mkimage.write_text(
                '#!/usr/bin/env bash\nset -eu\nprintf "mkimage %s\\n" "$*" >> "$CALL_LOG"\n'
                'out="${@: -1}"\n: > "$out"\n')
            mkinitramfs.chmod(0o755)
            mkimage.chmod(0o755)
            result = self.run_bash(
                'source scripts/package_hk1box.sh; build_hk1box_initramfs "$STAGE" "$RELEASE"',
                STAGE=stage.as_posix(), RELEASE=release,
                PATH=f'{bindir}{os.pathsep}{os.environ.get("PATH", "")}', CALL_LOG=call_log.as_posix())
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = call_log.read_text()
            self.assertIn('mkinitramfs -c gzip -o ', calls)
            self.assertIn(f' {release}', calls)
            self.assertIn('mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd', calls)
            self.assertTrue((stage / f'boot/initrd.img-{release}').is_file())
            self.assertTrue((stage / f'boot/uInitrd-{release}').is_file())

    def test_tar_payload_matches_ophub_installer(self):
        release = '7.2.8-edge-meson64'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'root'
            stage = Path(temporary) / 'stage'
            image = root / f'boot/vmlinuz-{release}'
            self.write_arm64_image(image)
            for name in [f'boot/config-{release}', f'boot/System.map-{release}',
                         f'boot/dtb-{release}/amlogic/meson-sm1-hk1box-vontar-x3.dtb',
                         f'lib/modules/{release}/modules.builtin',
                         f'usr/lib/armbian-kernel-build/{release}/source-manifest.env',
                         f'usr/src/linux-headers-{release}/include/test.h']:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('fixture')
            script = ('source scripts/package_hk1box.sh; stage_hk1box_payload '
                      f'{shlex.quote(root.as_posix())} {shlex.quote(stage.as_posix())} {release}')
            result = self.run_bash(script)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((stage / f'modules/{release}/modules.builtin').is_file())
            self.assertFalse((stage / 'modules/lib/modules').exists())
            self.assertTrue((stage / f'modules/{release}/armbian-kernel-build/source-manifest.env').is_file())
            self.assertTrue((stage / 'dtb/meson-sm1-hk1box-vontar-x3.dtb').is_file())
            self.assertTrue((stage / 'header/include/test.h').is_file())
            (root / f'boot/dtb-{release}/amlogic/meson-sm1-hk1box-vontar-x3.dtb').unlink()
            self.assertNotEqual(self.run_bash(script).returncode, 0)


if __name__ == '__main__':
    unittest.main()
