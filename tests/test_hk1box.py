#!/usr/bin/env python3
"""Verify the installation bundle contract used by ophub armbian-update."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
if os.name == "nt":
    BASH = r"C:\Program Files\Git\bin\bash.exe"


def shell_path(path):
    value = Path(path).as_posix()
    return f"/{value[0].lower()}{value[2:]}" if os.name == "nt" else value


class HK1BoxPackages(unittest.TestCase):
    release = "6.12.78-hk1box"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.stage = self.root / "stage"
        self.output = self.root / "output"
        self.modules = self.stage / "modules/lib/modules" / self.release
        files = {
            f"boot/config-{self.release}": (
                "CONFIG_TCP_CONG_BRUTAL=y\nCONFIG_AMNEZIAWG=y\nCONFIG_NETFILTER_DEAF=y\n"
            ),
            f"modules/lib/modules/{self.release}/modules.builtin": (
                "kernel/net/ipv4/tcp_brutal/brutal.ko\n"
                "kernel/drivers/net/amneziawg/amneziawg.ko\n"
                "kernel/net/netfilter/nf_deaf/nf_deaf.ko\n"
            ),
            f"modules/lib/modules/{self.release}/kernel/drivers/net/wireless/mt7921e.ko": "wifi module",
            "dtb-amlogic/meson-sm1-hk1box-vontar-x3.dtb": "dtb",
            "header/Module.symvers": "symbol versions",
            "header/Makefile": "headers makefile",
            f"modules/usr/lib/armbian-kernel-build/{self.release}/source-manifest.env": "board=hk1box\n",
        }
        for name in ("vmlinuz", "System.map", "initrd.img", "uInitrd"):
            files[f"boot/{name}-{self.release}"] = f"fixture {name}"
        for name, content in files.items():
            path = self.stage / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")

    def package(self):
        env = dict(os.environ, HK_TEST_SCRIPT=shell_path(ROOT / "scripts/hk1box_kernel.sh"),
                   HK_TEST_RELEASE=self.release, HK_TEST_STAGE=shell_path(self.stage),
                   HK_TEST_OUTPUT=shell_path(self.output))
        return subprocess.run(
            [BASH, "-c", 'set -Eeuo pipefail; source "$HK_TEST_SCRIPT"; '
             'hk_pack "$HK_TEST_RELEASE" "$HK_TEST_STAGE" "$HK_TEST_OUTPUT"'],
            env=env, text=True, encoding="utf-8", errors="replace", capture_output=True,
        )

    def test_bundle_matches_updater_and_contains_evidence(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        prefixes = {"boot", "dtb-amlogic", "modules", "header"}
        sums = (self.output / "sha256sums").read_text().splitlines()
        self.assertEqual(len(sums), 4)
        for line in sums:
            digest, name = line.split(None, 1)
            name = name.lstrip("*")
            self.assertEqual(digest, hashlib.sha256((self.output / name).read_bytes()).hexdigest())
            prefixes.remove(name.removesuffix(f"-{self.release}.tar.gz"))
        self.assertFalse(prefixes)
        with tarfile.open(self.output / f"dtb-amlogic-{self.release}.tar.gz") as archive:
            self.assertIn("./meson-sm1-hk1box-vontar-x3.dtb", archive.getnames())
            self.assertNotIn("./uEnv.txt", archive.getnames())
        with tarfile.open(self.output / f"modules-{self.release}.tar.gz") as archive:
            self.assertIn(f"./lib/modules/{self.release}/modules.builtin", archive.getnames())
            self.assertIn(f"./usr/lib/armbian-kernel-build/{self.release}/source-manifest.env", archive.getnames())

    def test_missing_board_dtb_rejects_package(self):
        (self.stage / "dtb-amlogic/meson-sm1-hk1box-vontar-x3.dtb").unlink()
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing HK1 Box DTB", result.stderr)
        self.assertFalse(self.output.exists())

    def test_config_without_real_builtin_rejects_package(self):
        (self.modules / "modules.builtin").write_text("kernel/net/ipv4/tcp_brutal/brutal.ko\n")
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing built-in amneziawg", result.stderr)
        self.assertFalse(self.output.exists())

    def test_missing_initramfs_rejects_package(self):
        (self.stage / f"boot/uInitrd-{self.release}").unlink()
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing boot file", result.stderr)

    def test_missing_wifi_module_rejects_package(self):
        (self.modules / "kernel/drivers/net/wireless/mt7921e.ko").unlink()
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing modular MT7921E", result.stderr)

    def test_invalid_platform_fails_before_host_setup(self):
        result = subprocess.run([BASH, str(ROOT / "build.sh")],
                                env=dict(os.environ, BUILD_TARGET="unsupported"),
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown BUILD_TARGET", result.stderr)

    def test_stage_output_is_understood_by_dashboard(self):
        env = dict(os.environ, HK_TEST_SCRIPT=shell_path(ROOT / "scripts/hk1box_kernel.sh"))
        result = subprocess.run(
            [BASH, "-c", 'set -Eeuo pipefail; source "$HK_TEST_SCRIPT"; '
             'hk_stage "1. HK1 Box dependencies"; hk_stage "2. HK1 Box configuration"; hk_finish_stage'],
            env=env, text=True, encoding="utf-8", capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        sys.path.insert(0, str(ROOT / "scripts"))
        from live_dashboard import DashboardAnalyzer
        analyzer = DashboardAnalyzer(self.root / "log", None, ROOT)
        for line in result.stdout.splitlines():
            analyzer._process_line(line.encode())
        self.assertEqual(len(analyzer._stages), 2)
        self.assertTrue(all(stage["status"] == "success" for stage in analyzer._stages))


if __name__ == "__main__":
    unittest.main()
