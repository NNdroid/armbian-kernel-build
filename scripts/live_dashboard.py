#!/usr/bin/env python3
"""Read-only build evidence analysis for the live build dashboard."""

from __future__ import annotations

import hashlib
import re
import shutil
import subprocess
import threading
from collections import deque
from pathlib import Path
from typing import Any


ANSI_RE = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|[@-_])")
STAGE_END_RE = re.compile(r"────\s*(.+?)\s+完成\s*\(耗时\s*(\d+)s\)\s*────")
STAGE_BEGIN_RE = re.compile(r"────\s*(.+?)\s*────")
ERROR_RE = re.compile(
    r"(?:\[ERROR\]|\[💥\]|\[kernel-inject\]\[(?:err|error)\]|\berror(?:\s+\d+|\s*:)|\bfailed\b)",
    re.IGNORECASE,
)
WARNING_RE = re.compile(
    r"(?:\[WARN(?:ING)?\]|\[kernel-inject\]\[warn\]|\bwarning:)",
    re.IGNORECASE,
)
MAX_ANALYSIS_READ = 8 * 1024 * 1024
MAX_DIAGNOSTICS = 120
MAX_PACKAGE_LIST = 100
MAX_PACKAGE_OUTPUT = 4 * 1024 * 1024
MAX_PACKAGE_FILES = 6000

SOURCE_REPOSITORIES = {
    "tcp_brutal_commit": ("TCP-Brutal v2", "https://github.com/HyNetworks/tcp-brutal"),
    "amneziawg_commit": (
        "AmneziaWG",
        "https://github.com/NNdroid/amneziawg-linux-kernel-module",
    ),
    "nf_deaf_commit": ("nf_deaf", "https://github.com/NNdroid/nf_deaf"),
}

FEATURE_GROUPS: tuple[tuple[str, tuple[str, ...]], ...] = (
    (
        "custom",
        ("TCP_CONG_BRUTAL", "AMNEZIAWG", "NETFILTER_DEAF", "WIREGUARD"),
    ),
    (
        "ebpf",
        (
            "BPF",
            "BPF_SYSCALL",
            "BPF_JIT",
            "DEBUG_INFO_BTF",
            "DEBUG_INFO_BTF_MODULES",
            "BPF_LSM",
            "XDP_SOCKETS",
        ),
    ),
    ("mplsSrv6", ("MPLS_ROUTING", "MPLS_IPTUNNEL", "IPV6_SEG6_LWTUNNEL")),
    ("overlay", ("VXLAN", "GENEVE", "NET_IPGRE", "IPV6_GRE", "NET_FOU")),
    (
        "netfilter",
        ("NF_TABLES", "NFT_TPROXY", "NFT_SYNPROXY", "IP6_NF_TARGET_NPT"),
    ),
    ("transport", ("TCP_CONG_BBR", "DEFAULT_FQ", "BRIDGE")),
    ("usbGadget", ("USB_GADGET", "USB_CONFIGFS", "USB_FUNCTIONFS")),
    ("bluetooth", ("BT", "BT_RFCOMM", "BT_BNEP", "BT_HIDP")),
    (
        "wifi",
        ("CFG80211", "MAC80211", "MT76_CORE", "MT792x_LIB", "MT7921E"),
    ),
)


def _read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            key, separator, value = raw_line.partition("=")
            if separator and re.fullmatch(r"[A-Za-z0-9_]+", key):
                values[key] = value.strip()
    except OSError:
        pass
    return values


def _read_config(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    enabled = re.compile(r"^CONFIG_([A-Za-z0-9_]+)=(.*)$")
    disabled = re.compile(r"^# CONFIG_([A-Za-z0-9_]+) is not set$")
    try:
        for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            match = enabled.match(raw_line)
            if match:
                values[match.group(1)] = match.group(2).strip().strip('"')
                continue
            match = disabled.match(raw_line)
            if match:
                values[match.group(1)] = "n"
    except OSError:
        pass
    return values


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(64 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _relative(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def _safe_regular_file(path: Path, root: Path) -> bool:
    try:
        relative = path.relative_to(root)
        current = root
        for part in relative.parts:
            current = current / part
            if current.is_symlink():
                return False
        return path.is_file() and path.resolve().is_relative_to(root)
    except (OSError, RuntimeError, ValueError):
        return False


class DashboardAnalyzer:
    """Incrementally analyzes build logs and durable output evidence."""

    def __init__(self, log_path: Path, files_root: Path | None, repository_root: Path):
        self.log_path = log_path
        self.files_root = files_root
        self.repository_root = repository_root
        self._lock = threading.Lock()
        self._log_offset = 0
        self._partial = b""
        self._line_number = 0
        self._stages: list[dict[str, Any]] = []
        self._diagnostics: deque[dict[str, Any]] = deque(maxlen=MAX_DIAGNOSTICS)
        self._resources: deque[dict[str, Any]] = deque(maxlen=360)
        self._last_resource_timestamp = 0
        self._hash_cache: dict[tuple[str, int, int], str] = {}

    def record_metrics(self, metrics: dict[str, Any]) -> None:
        timestamp = int(metrics.get("generated_at", 0) or 0)
        usage = metrics.get("usage")
        if not timestamp or not isinstance(usage, dict):
            return
        sample = {
            "timestamp": timestamp,
            "load": usage.get("load_percent", 0),
            "memory": usage.get("memory_percent", 0),
            "disk": usage.get("disk_percent", 0),
        }
        with self._lock:
            if timestamp <= self._last_resource_timestamp:
                return
            self._last_resource_timestamp = timestamp
            self._resources.append(sample)

    def _reset_log_analysis(self) -> None:
        self._log_offset = 0
        self._partial = b""
        self._line_number = 0
        self._stages.clear()
        self._diagnostics.clear()

    def _process_line(self, raw_line: bytes) -> None:
        self._line_number += 1
        line = ANSI_RE.sub("", raw_line.decode("utf-8", errors="replace")).strip()
        if not line:
            return

        end_match = STAGE_END_RE.search(line)
        if end_match:
            label = end_match.group(1).strip()
            for stage in reversed(self._stages):
                if stage["status"] == "running" and (
                    str(stage["label"]).startswith(label)
                    or label.startswith(str(stage["label"]))
                ):
                    stage["status"] = "success"
                    stage["end_line"] = self._line_number
                    stage["duration_seconds"] = int(end_match.group(2))
                    break
        else:
            begin_match = STAGE_BEGIN_RE.search(line)
            if begin_match:
                label = begin_match.group(1).strip()
                self._stages.append(
                    {
                        "id": len(self._stages) + 1,
                        "label": label,
                        "status": "running",
                        "start_line": self._line_number,
                        "end_line": None,
                        "duration_seconds": None,
                    }
                )

        severity = "error" if ERROR_RE.search(line) else "warning" if WARNING_RE.search(line) else ""
        if severity:
            diagnostic = {
                "severity": severity,
                "line": self._line_number,
                "message": line[:800],
            }
            if not self._diagnostics or self._diagnostics[-1] != diagnostic:
                self._diagnostics.append(diagnostic)

    def _consume_log(self) -> None:
        try:
            size = self.log_path.stat().st_size
        except OSError:
            return
        if size < self._log_offset:
            self._reset_log_analysis()
        try:
            with self.log_path.open("rb") as source:
                source.seek(self._log_offset)
                data = source.read(MAX_ANALYSIS_READ)
        except OSError:
            return
        if not data:
            return
        self._log_offset += len(data)
        lines = (self._partial + data).split(b"\n")
        self._partial = lines.pop()
        for line in lines:
            self._process_line(line.rstrip(b"\r"))

    def _configured_sources(self) -> list[dict[str, Any]]:
        config_path = self.repository_root / "userpatches" / "lib.config"
        try:
            source = config_path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            source = ""
        keys = {
            "tcp_brutal_commit": "TCP_BRUTAL_COMMIT",
            "amneziawg_commit": "AMNEZIAWG_COMMIT",
            "nf_deaf_commit": "NF_DEAF_COMMIT",
        }
        result = []
        for manifest_key, variable in keys.items():
            match = re.search(rf"{variable}:=([0-9a-f]{{40}})", source)
            name, repository = SOURCE_REPOSITORIES[manifest_key]
            result.append(
                {
                    "branch": "configured",
                    "component": name,
                    "repository": repository,
                    "commit": match.group(1) if match else "",
                    "origin": "configured",
                }
            )
        return result

    def _cached_sha256(self, path: Path) -> str:
        stat_result = path.stat()
        key = (str(path), stat_result.st_size, stat_result.st_mtime_ns)
        if key not in self._hash_cache:
            self._hash_cache[key] = _sha256(path)
        return self._hash_cache[key]

    def _metadata(self) -> dict[str, Any]:
        root = self.files_root
        empty = {
            "features": [],
            "sources": self._configured_sources(),
            "integrity": [],
            "config_diffs": [],
        }
        if root is None or not root.is_dir():
            return empty
        metadata_root = root / "release-metadata"
        if not metadata_root.is_dir() or metadata_root.is_symlink():
            return empty

        manifests: dict[str, dict[str, str]] = {}
        for path in metadata_root.glob("*/*-source-manifest.env"):
            if _safe_regular_file(path, root):
                manifests[path.parent.name] = _read_env(path)

        sources: list[dict[str, Any]] = []
        for branch, manifest in sorted(manifests.items()):
            for key, (name, repository) in SOURCE_REPOSITORIES.items():
                sources.append(
                    {
                        "branch": branch,
                        "component": name,
                        "repository": repository,
                        "commit": manifest.get(key, ""),
                        "origin": "packaged",
                    }
                )
        if not sources:
            sources = self._configured_sources()

        features: list[dict[str, Any]] = []
        integrity: list[dict[str, Any]] = []
        config_diffs: list[dict[str, Any]] = []
        for config_path in sorted(metadata_root.glob("*/*-kernel.config")):
            if not _safe_regular_file(config_path, root):
                continue
            branch = config_path.parent.name
            manifest = manifests.get(branch, {})
            config = _read_config(config_path)
            groups = []
            for group_id, symbols in FEATURE_GROUPS:
                groups.append(
                    {
                        "id": group_id,
                        "items": [
                            {"symbol": symbol, "value": config.get(symbol, "unknown")}
                            for symbol in symbols
                        ],
                    }
                )
            features.append(
                {
                    "branch": branch,
                    "kernel_release": manifest.get("kernel_release", ""),
                    "path": _relative(config_path, root),
                    "groups": groups,
                }
            )

            actual_hash = self._cached_sha256(config_path)
            expected_hash = manifest.get("config_sha256", "")
            integrity.append(
                {
                    "branch": branch,
                    "kind": "config",
                    "name": config_path.name,
                    "status": (
                        "verified"
                        if expected_hash and actual_hash == expected_hash
                        else "mismatch" if expected_hash else "unavailable"
                    ),
                    "expected": expected_hash,
                    "actual": actual_hash,
                    "path": _relative(config_path, root),
                }
            )
            commits = [manifest.get(key, "") for key in SOURCE_REPOSITORIES]
            integrity.append(
                {
                    "branch": branch,
                    "kind": "sources",
                    "name": f"{branch}-source-manifest.env",
                    "status": (
                        "verified"
                        if commits and all(re.fullmatch(r"[0-9a-f]{40}", item or "") for item in commits)
                        else "unavailable"
                    ),
                    "expected": "3",
                    "actual": str(sum(bool(item) for item in commits)),
                    "path": f"release-metadata/{branch}/{branch}-source-manifest.env",
                }
            )

        for diff_path in sorted(metadata_root.glob("*/*-config-vs-*-defconfig.txt")):
            if not _safe_regular_file(diff_path, root):
                continue
            try:
                content = diff_path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            lines = content.splitlines()
            config_diffs.append(
                {
                    "branch": diff_path.parent.name,
                    "name": diff_path.name,
                    "path": _relative(diff_path, root),
                    "lines": len(lines),
                    "added": sum(line.startswith("+") and not line.startswith("+++") for line in lines),
                    "removed": sum(line.startswith("-") and not line.startswith("---") for line in lines),
                }
            )

        for sums_path in sorted(metadata_root.glob("*/*-SHA256SUMS")):
            if not _safe_regular_file(sums_path, root):
                continue
            verified = 0
            total = 0
            try:
                lines = sums_path.read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                lines = []
            for line in lines[:200]:
                match = re.fullmatch(r"([0-9a-f]{64})\s+\*?(.+)", line.strip())
                if not match or Path(match.group(2)).name != match.group(2):
                    continue
                total += 1
                referenced = sums_path.parent / match.group(2)
                if _safe_regular_file(referenced, root):
                    try:
                        verified += self._cached_sha256(referenced) == match.group(1)
                    except OSError:
                        pass
            integrity.append(
                {
                    "branch": sums_path.parent.name,
                    "kind": "modules",
                    "name": sums_path.name,
                    "status": "verified" if total and verified == total else "mismatch",
                    "expected": str(total),
                    "actual": str(verified),
                    "path": _relative(sums_path, root),
                }
            )

        return {
            "features": features,
            "sources": sources,
            "integrity": integrity,
            "config_diffs": config_diffs,
        }

    def snapshot(self, build_state: str) -> dict[str, Any]:
        with self._lock:
            self._consume_log()
            if build_state == "failure":
                for stage in reversed(self._stages):
                    if stage["status"] == "running":
                        stage["status"] = "failure"
                        break
            timeline = [dict(stage) for stage in self._stages]
            diagnostics = list(self._diagnostics)
            resources = list(self._resources)
        metadata = self._metadata()
        return {
            "state": build_state,
            "timeline": timeline,
            "diagnostics": diagnostics,
            "resources": resources,
            **metadata,
        }


def _parse_control(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    current = ""
    for line in text.splitlines():
        if line[:1].isspace() and current:
            values[current] = f"{values[current]} {line.strip()}".strip()
            continue
        key, separator, value = line.partition(":")
        if separator:
            current = key.strip().lower().replace("-", "_")
            values[current] = value.strip()
    return values


def list_deb_packages(files_root: Path | None) -> dict[str, Any]:
    if files_root is None:
        return {"available": False, "tool_available": False, "packages": []}
    debs_root = files_root / "debs"
    if not debs_root.is_dir() or debs_root.is_symlink():
        return {"available": False, "tool_available": bool(shutil.which("dpkg-deb")), "packages": []}
    tool = shutil.which("dpkg-deb")
    packages = []
    paths = sorted(
        (
            path
            for path in debs_root.glob("*.deb")
            if _safe_regular_file(path, files_root)
        ),
        key=lambda item: item.stat().st_mtime_ns,
        reverse=True,
    )[:MAX_PACKAGE_LIST]
    for path in paths:
        stat_result = path.stat()
        control: dict[str, str] = {}
        inspection = "unavailable"
        if tool:
            try:
                completed = subprocess.run(
                    [tool, "-f", str(path)],
                    check=True,
                    capture_output=True,
                    timeout=10,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                )
                control = _parse_control(completed.stdout[:MAX_PACKAGE_OUTPUT])
                inspection = "ready"
            except (OSError, subprocess.SubprocessError):
                inspection = "invalid"
        packages.append(
            {
                "name": path.name,
                "path": _relative(path, files_root),
                "size": stat_result.st_size,
                "modified": int(stat_result.st_mtime),
                "inspection": inspection,
                "control": {
                    key: control.get(key, "")
                    for key in (
                        "package",
                        "version",
                        "architecture",
                        "installed_size",
                        "depends",
                        "description",
                    )
                },
            }
        )
    return {"available": True, "tool_available": bool(tool), "packages": packages}


def inspect_deb(path: Path) -> dict[str, Any]:
    tool = shutil.which("dpkg-deb")
    if not tool:
        return {"inspection": "unavailable", "files": [], "truncated": False}
    try:
        completed = subprocess.run(
            [tool, "-c", str(path)],
            check=True,
            capture_output=True,
            timeout=20,
        )
    except (OSError, subprocess.SubprocessError):
        return {"inspection": "invalid", "files": [], "truncated": False}
    raw = completed.stdout
    truncated = len(raw) > MAX_PACKAGE_OUTPUT
    text = raw[:MAX_PACKAGE_OUTPUT].decode("utf-8", errors="replace")
    lines = text.splitlines()
    if len(lines) > MAX_PACKAGE_FILES:
        lines = lines[:MAX_PACKAGE_FILES]
        truncated = True
    return {"inspection": "ready", "files": lines, "truncated": truncated}
