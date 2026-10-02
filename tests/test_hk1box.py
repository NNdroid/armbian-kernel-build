"""Contracts for shared Armbian target profiles and the HK1 Box DTB adaptation."""
import os
import hashlib
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

    def test_device_tree_patch_applies_without_overclock(self):
        patch = ROOT / 'userpatches/kernel/archive/meson64-7.2/0001-hk1box-mainline-dtb.patch'
        with tempfile.TemporaryDirectory() as temporary:
            tree = Path(temporary)
            dts_dir = tree / 'arch/arm64/boot/dts/amlogic'
            dts_dir.mkdir(parents=True)
            (dts_dir / 'Makefile').write_text('dtb-$(CONFIG_ARCH_MESON) += meson-sm1-sei610.dtb\n')
            result = subprocess.run(['git', 'apply', str(patch)], cwd=tree, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            dts = (dts_dir / 'meson-sm1-hk1box-vontar-x3.dts').read_text()
            self.assertIn('#include "meson-sm1-ac2xx.dtsi"', dts)
            self.assertNotIn('opp-hz =', dts)
            self.assertIn('/delete-node/ opp-2100000000;', dts)
            self.assertNotIn('0xFFFFFFFF', dts)
            self.assertIn('/delete-property/ sd-uhs-sdr104;', dts)
            self.assertIn('max-frequency = <25000000>', dts)

    def test_tar_payload_matches_ophub_installer(self):
        release = '7.2.8-edge-meson64'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'root'
            stage = Path(temporary) / 'stage'
            for name in [f'boot/vmlinuz-{release}', f'boot/config-{release}',
                         f'boot/System.map-{release}',
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
