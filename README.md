# armbian-kernel-build

Automatically tracks Armbian Rockchip64 kernel versions and reproducibly integrates the following third-party networking components into the kernel build:

- TCP-Brutal v2 (the pinned `HyNetworks/tcp-brutal` `exp/xan-fix` revision)
- AmneziaWG
- nf_deaf

## Injection design

The injection logic lives in `userpatches/lib.config` and uses Armbian's `custom_kernel_config` hook:

- immutable commit SHAs are used by default and the fetched revision is verified;
- upstream file layouts are validated before kernel source directories are replaced;
- Kconfig/Makefile integration uses marked idempotent blocks, so repeated runs do not duplicate entries;
- legacy single-file TCP-Brutal, the old `tcp.c` patch, and the old nf_deaf layout are removed automatically;
- Armbian remains responsible for `scripts/config` and `olddefconfig`; the injector does not hard-code the CPU architecture;
- before final `.config` validation, the actual Kconfig symbols defined by the target kernel tree are scanned. Any required capability that is missing or disabled by dependencies fails the build instead of publishing a reduced-feature kernel;
- TCP-Brutal, AmneziaWG, and nf_deaf are built in by default. Native WireGuard is disabled by default when AmneziaWG is used as the WireGuard-compatible implementation, avoiding static-link symbol conflicts.

## Full eBPF / BTF / CO-RE

`ENABLE_FULL_EBPF=yes` and `KERNEL_BTF=yes` are enabled by default. The hook enables and verifies the final `.config` after kernel configuration, including:

- eBPF syscall support, ARM64 JIT, always-on JIT, and unprivileged eBPF disabled by default;
- kernel/module BTF, DWARF5, and type information required for CO-RE;
- cgroup BPF and BPF LSM, including `bpf` in the ordered `CONFIG_LSM` list;
- XDP/AF_XDP, tc classifier/action, netfilter BPF, and lightweight-tunnel BPF;
- kprobe, uprobe, ftrace, and BPF events.

If a required option is disabled by dependencies after `olddefconfig`, the build wrapper fails rather than uploading an incomplete kernel. `CONFIG_BPF_UNPRIV_DEFAULT_OFF=y` only changes the default for unprivileged users; eBPF used by root/CAP_BPF remains available. Native XDP still depends on the specific NIC driver, while generic kernel XDP/AF_XDP support is enabled.

On resource-constrained builds that explicitly do not require BTF/CO-RE, set both `ENABLE_FULL_EBPF=no KERNEL_BTF=no`. This is not recommended for normal release builds.

## Full networking feature set

`ENABLE_FULL_NETWORKING=yes` is enabled by default. Protocols, tunnels, netfilter, BBR, bridge, USB Gadget features, and their dependencies are forced built-in (`=y`). Bluetooth and Wi-Fi driver stacks are forced to modules (`=m`). Both modes are verified after `olddefconfig` and again against the packaged kernel configuration.

The enforced feature set includes:

- MPLS routing, LWT/IP tunneling, GSO, and tc MPLS actions;
- SRv6 LWT, HMAC, BPF, and IPv4/IPv6 policy routing;
- VXLAN, Geneve, IPv4 GRE, IPv6 GRE, FOU, and Open vSwitch tunnel ports;
- built-in AmneziaWG, BBR, and FQ qdisc; native WireGuard is disabled by default;
- nftables protocol families and common expressions, TPROXY, SYNPROXY, NPTv6, and xtables compatibility;
- Linux bridge, VLAN filtering, MRP/CFM, bridge netfilter/ebtables, plus modular Bluetooth core/RFCOMM/BNEP/HIDP;
- modular `cfg80211`, `mac80211`, MediaTek `mt76`/Connac/MT792x/MT7921 common layers, and the `mt7921e` PCIe driver;
- USB Gadget dual-role infrastructure and ConfigFS/FunctionFS serial, networking, storage, HID, audio, MIDI, UVC, printer, and target functions.

"Supported" means built-in networking features pass strict `=y` validation and the Bluetooth/Wi-Fi stack passes strict `=m` validation. Modular components must be auto-loaded by udev or loaded with `modprobe`. Actual USB device-role support, native XDP, Wi-Fi firmware, and hardware offload still depend on the board controller, PCIe/device tree, firmware packages, and NIC hardware.

`NF_CONNTRACK`, `VLAN_8021Q`, nftables/NAT, tunnels, BBR, bridge netfilter, and USB composite/function dependencies must remain `=y`. `BT`, `BT_BNEP`, `RFKILL`, `CFG80211`, `MAC80211`, `MT76_CORE`, and the `MT7921E` dependency chain must remain `=m`. Any mode mismatch fails validation.

Sources and build modes can be overridden with environment variables:

```bash
TCP_BRUTAL_REPOSITORY=https://github.com/HyNetworks/tcp-brutal.git
TCP_BRUTAL_REF=<commit-or-ref>
TCP_BRUTAL_COMMIT=<expected-full-sha>
TCP_BRUTAL_MODE=y

AMNEZIAWG_REPOSITORY=https://github.com/NNdroid/amneziawg-linux-kernel-module.git
AMNEZIAWG_REF=<commit-or-ref>
AMNEZIAWG_COMMIT=<expected-full-sha>
AMNEZIAWG_MODE=y

NF_DEAF_REPOSITORY=https://github.com/NNdroid/nf_deaf.git
NF_DEAF_REF=<commit-or-ref>
NF_DEAF_COMMIT=<expected-full-sha>
NF_DEAF_MODE=y

WIREGUARD_MODE=n
ENABLE_FULL_EBPF=yes
ENABLE_FULL_NETWORKING=yes
KERNEL_BTF=yes
```

Third-party component modes are `y` (built in), `m` (loadable module), or `n` (disabled). With the defaults, `brutal`, `amneziawg`, and `nf_deaf` are available at boot without `modprobe`. Bluetooth/Wi-Fi remain modular. The release flow extracts the complete MT7921E dependency chain and required Bluetooth `.ko` files from the final `linux-image` package, preserving `.gz`, `.xz`, or `.zst` compression, and uploads them as standalone release assets with SHA256 checksums and kernel-release/architecture-specific installation instructions.

When updating an upstream dependency, setting the immutable `*_COMMIT` is sufficient; an omitted `*_REF` defaults to the same commit. Set `*_REF` separately only for Git servers that require a fetch hint. Moving branches are not recommended as expected revisions. AmneziaWG replaces native WireGuard by default; if native WireGuard is re-enabled, both implementations may not be built in simultaneously, and the hook rejects that combination.

## Validation

```bash
bash -n build.sh overwrite/build_with_diy.sh userpatches/lib.config tests/test_kernel_injection.sh
bash tests/test_kernel_injection.sh
python3 tests/test_live_log_server.py
```

Regression tests download pinned revisions and validate v1 migration, source integrity, provenance records, Kconfig/Kbuild integration, idempotency, and representative Armbian mode conflicts in a synthetic kernel tree. They also simulate Docker cleanup of the source worktree and confirm that the wrapper can validate a newly generated `linux-image` package using packaged evidence alone. Full compilation remains the responsibility of the GitHub Actions Armbian build.

## Release notes and attachments

Each successful build embeds the final configuration, Kconfig symbol inventory, source pins, and defconfig diff into the `.deb` while Armbian packages `linux-image`. After Docker removes temporary source trees, the wrapper generates release notes from that package instead of relying on a vanished worktree or static text.

Release metadata includes:

- kernel release, Armbian branch, board, architecture, userspace release, Armbian/build baseline commit, and kernel-source baseline commit;
- final build modes and source commits for TCP-Brutal v2, AmneziaWG, nf_deaf, and native WireGuard;
- final eBPF/BTF/CO-RE validation state;
- final summaries for MPLS/SRv6, tunnels, netfilter, BBR, bridge/BNEP, and USB Gadget;
- the configuration-difference count against the standard `arm64 defconfig` generated from the same Armbian-patched source tree;
- size and SHA256 for each `.deb`, plus repository commit and UTC build time;
- standalone `.ko*` assets for managed components whose final mode is `m`, including checksums, ABI restrictions, and complete `depmod` / `modprobe` commands.

The release also includes `<branch>-kernel.config` and `<branch>-config-vs-arm64-defconfig.txt`. If baseline generation fails, `arm64-defconfig-build.log` is attached for diagnostics. When modular assets exist, the release also uploads `<branch>-<kernel-release>-<arch>-<module>.ko*`, `<branch>-loadable-modules-SHA256SUMS`, and `<branch>-loadable-modules.md`.

Standalone modules must only be used with the exact kernel release and architecture recorded in the release notes; installing the complete `linux-image-*.deb` is preferred. The defconfig comparison covers kernel configuration differences only. Armbian Rockchip64, device-tree, and other source patches are additional source-level differences from upstream kernel.org.

## GitHub Actions live build log

The workflow can expose a read-only live log page through ngrok while the build is running. Configure these repository secrets:

- `NGROK_AUTHTOKEN`: a regenerated ngrok token; never commit it;
- `NGROK_LOG_AUTH`: HTTP Basic Auth credentials in `username:password` form; use a dedicated strong password;
- `NGROK_URL`: the reserved full ngrok HTTPS URL, such as a static domain assigned in the ngrok account.

Set them interactively with `gh` to keep values out of shell history:

```bash
gh secret set NGROK_AUTHTOKEN
gh secret set NGROK_LOG_AUTH
gh secret set NGROK_URL
```

All three values are read only from Repository secrets. After startup, the workflow notice and Job Summary report that the endpoint is ready without echoing the secret URL. Open the address stored in `NGROK_URL` directly.

The live page provides numbered logs, ANSI control-sequence cleanup, search with previous/next navigation, line jumping, wrapping, tail following, and complete log download. Lines that begin with `::group::<title>` and `::endgroup::` are rendered as nested collapsible log groups; searches and line jumps automatically expand collapsed ancestors when they target a line inside a group. The interface supports Japanese, English, French, and German; the Chinese locale was removed so the repository contains no Chinese UI strings. Themes can be automatic, light, or dark, with automatic mode following the browser/device color scheme. The header displays target board, architecture, distribution, kernel branch/version, runner OS/CPU/load/memory/disk, elapsed build time, and log size. To prevent long builds from exhausting browser memory, the client keeps roughly 5 MiB or 50,000 visible log lines; the complete raw log remains available at `/download`.

The Build Files tab exposes a read-only browser rooted at `build/output`: navigate directories, filter the current directory, preview text configuration/manifest/log files, download binary artifacts such as `.deb`, and calculate SHA-256 on demand. Large downloads support HTTP Range requests. The server does not create artifact directories and exposes no upload, rename, or delete operations. Hidden entries and symlinks are not listed; absolute paths, parent traversal, and targets outside the published root are rejected.

The Build Overview combines logs with persistent build evidence:

- incrementally parses `build.sh` stage markers and shows state, log line, and elapsed time; warnings/errors feed the diagnostics center and link back to log lines;
- derives a `y/m/n` feature matrix from each branch's final `*-kernel.config` for eBPF/BTF, MPLS/SRv6, tunnels, netfilter, BBR/bridge, USB Gadget, Bluetooth, MT7921E, and the three injected components;
- displays the three packaged source commits and validates final-config SHA256, source-pin format, and standalone-module `SHA256SUMS`;
- stores the most recent 360 CPU-load, memory, and disk samples and renders SVG trend charts without third-party scripts;
- reads generated defconfig diffs in the Config Diff tab with inline filtering; the DEB Inspector invokes `dpkg-deb` with fixed arguments to show control fields and a bounded file list, never user commands;
- sends browser notifications only after explicit user authorization, only while the page remains open, and only when a build transitions to success or failure. No background push is registered and credentials are not sent to third parties.

The wrapper copies validated `source-manifest.env` evidence to `<branch>-source-manifest.env` and uploads it with the release for source-version and integrity views. Older artifacts without this file are reported as insufficient evidence rather than guessed as verified.

By default, the browser receives appended logs, build state, and resource metrics over same-origin `/api/events` SSE. The server sends a heartbeat every 15 seconds and uses the log byte offset as the SSE event ID. Reconnects prefer `Last-Event-ID`, so the browser does not redownload from the beginning. After repeated SSE failures, the page falls back to incremental `/api/log?offset=...` polling and uses `/api/metrics` for device/resource information. `/download` continues to provide the current complete log.

The page, SSE, metrics, overview, DEB inspection, incremental APIs, file list/preview/checksum APIs, and all download endpoints require Basic Auth. Only `/healthz`, which contains no logs, is unauthenticated. The web service exposes no upload, file modification, shell, or release-write endpoint.

The log file is written by `tee` before GitHub masking is applied, so protect `NGROK_LOG_AUTH` and ensure build scripts never print secrets. The endpoint exists only while the job is running. The workflow does not upload complete logs to LogPasta or another paste service; GitHub Actions remains the system of record after the build ends.
