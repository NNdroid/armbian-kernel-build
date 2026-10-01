"""Contracts for shared Armbian target profiles and the HK1 Box DTB adaptation."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt" else shutil.which("bash")


class TargetTests(unittest.TestCase):
    def run_bash(self, script, **variables):
        env = os.environ.copy()
        for key in ("BUILD_TARGET", "BUILD_BRANCH", "BUILD_FAMILY", "BUILD_FORCE", "BUILD_PUBLISH"):
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
            self.assertNotIn('&cpu_opp_table', dts)
            self.assertNotIn('0xFFFFFFFF', dts)
            self.assertIn('/delete-property/ sd-uhs-sdr104;', dts)
            self.assertIn('max-frequency = <25000000>', dts)


if __name__ == '__main__':
    unittest.main()
