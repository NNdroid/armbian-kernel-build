# Build script architecture and extension guide

Every board goes through the same Armbian compilation entry point; the build scripts are
not duplicated per CPU architecture. The default target is still Rockchip64; HK1 Box stays
on edge / 7.2 with its existing TAR installation format.

```text
build.sh                         Public entry point, read-only target queries
├── userpatches/config/build-targets/*.conf
│                                Target data: board, family, architecture, branches, runner
└── scripts/lib/
    ├── targets.sh               Discover targets, validate config, load adapters
    ├── pipeline.sh              Version compare → build → validate → package → publish
    ├── logging.sh / host.sh     Logging, host dependencies, file sync
    ├── versions.sh              Armbian / kernel.org / release version parsing
    ├── artifacts.sh             Locate the artifacts of the current build
    ├── release.sh               Publishing and attachment inventory
    ├── armbian.sh               Invoke the build wrapper in the correct directory
    ├── board-contract.sh        Run board-level checks against DEB-embedded evidence
    └── adapters/*.sh            Pluggable installation format conversion

overwrite/build_with_diy.sh      Armbian build and artifact validation flow
└── overwrite/lib/kernel-build/
    ├── common.sh                Arguments, config, evidence reads, temp file cleanup
    ├── module-assets.sh         Export module attachments from the built DEB
    └── release-metadata.sh      Final config, diffs, module guide, release metadata

userpatches/config/boards/              Armbian board and driver config hooks
userpatches/kernel/archive/             Board-level source patches
userpatches/extensions/                 Persist source and config evidence at package time
```

## Read-only queries

The query commands install no software, clone no source, compile nothing, and publish
nothing:

```bash
bash build.sh --list-targets
bash build.sh --describe-target hk1box
BUILD_BRANCH=edge bash build.sh --describe-target rockchip64
```

`--describe-target` prints stable `key=value` information. The GitHub Actions prepare job
uses it directly to select the runner and the page device metadata, so the target input is
a plain string and no target enumeration has to be maintained.
`scripts/build_targets.sh` is kept as a compatibility entry point for older callers; tests
can still load the functions without running a build by using
`BUILD_SCRIPT_LIB_ONLY=yes source build.sh`.

## Adding a target

Adding a target is a configuration change. Nothing outside `userpatches/config/` needs to
be edited — not the pipeline, not the packaging scripts, not the workflow.

```bash
bash build.sh --new-target my-board        # scaffold profile + Armbian board shim
bash build.sh --describe-target my-board   # inspect the fully resolved profile
bash build.sh --check-targets             # validate every profile in the repo
```

The scaffold writes two files:

| File | Role |
|---|---|
| `userpatches/config/build-targets/my-board.conf` | The single source of truth: build identity, series lock, DTB, required built-in drivers, Armbian board variables, and the `custom_kernel_config` / `post_family_config` hooks |
| `userpatches/config/boards/my-board.conf` | A shim that sources the profile. Armbian resolves a board at this path, so the file must exist, but it must never carry configuration of its own |

The board shim is named after the **Armbian board id** (`TARGET_BOARD`), which is not
always the same as the target id — the `rockchip64` target builds `nanopi-r5s`. Loading a
profile fails immediately when the matching shim is missing, rather than after Docker has
already started.

Then, if the board needs kernel patches, add them under
`userpatches/kernel/archive/<family>-<series>/` and declare the boot-critical driver
requirements. Finally add a regression test and run the read-only queries, the build, and
real-device verification.

Target names may only contain lowercase letters, digits, and hyphens; paths, newlines, and
shell expressions are not allowed. The template below is not an adapted or verified RISC-V
board:

```bash
TARGET_BOARD=my-riscv-board
TARGET_FAMILY=my-riscv-family
TARGET_ARCH=riscv64
TARGET_KBUILD_ARCH=riscv
TARGET_RUNNER=ubuntu-24.04
TARGET_VERSION_CONFIG=include/my-riscv-family_common.inc
TARGET_RELEASE_PREFIX=my-riscv-
TARGET_ADAPTER=deb
TARGET_BRANCHES=(current edge)
```

Only the required fields need to be set; everything else falls back to the schema
default. `TARGET_SERIES=()` and `TARGET_REQUIRED_Y=()` do not need to be written at all,
and when a series lock *is* needed it must be assigned into a declared map —
a bare `TARGET_SERIES=([edge]=7.2)` literal makes bash parse `[edge]` as an arithmetic
subscript and fail under `set -u`:

```bash
declare -gA TARGET_SERIES=()
TARGET_SERIES["edge"]=7.2
```

### The target schema

`TARGET_SCHEMA` in `scripts/lib/targets.sh` is the authoritative field list. Each entry is
`field|kind|required|validator|default`, and the loader derives the reset list, the
required-field check and the format check from it. Adding a profile field is therefore a
one-line change that cannot be half-implemented.

| Setting | Purpose |
|---|---|
| `TARGET_BOARD` / `TARGET_FAMILY` | Armbian board and DEB family; the two must not be mixed up |
| `TARGET_ARCH` / `TARGET_KBUILD_ARCH` | Debian package architecture and Kbuild architecture; artifact evidence must agree |
| `TARGET_RUNNER` | Actions runner label; cross-architecture build capability is decided by Armbian and the toolchain |
| `TARGET_VERSION_CONFIG` | Relative path to the version config under Armbian `config/sources/families/` |
| `TARGET_BRANCHES` | Supported branches; requesting an undeclared branch fails before the build |
| `TARGET_SERIES` | Optional per-branch series lock; prevents patches from being misapplied to a new series. Locking a branch the target does not build is rejected |
| `TARGET_RELEASE_PREFIX` | Platform-independent release prefix; preserves compatibility with the original Rockchip tags |
| `TARGET_ADAPTER` | Adapter name under `scripts/lib/adapters/` |
| `TARGET_BOARD_DTB` | Optional relative DTB path; once declared, the source hash and the compiled DTB must both be found in the package |
| `TARGET_BOOT_TEXT_OFFSET` | Optional required `text_offset` in the ARM64 Image header. Written the way it appears in prose (`01080000`); the packaging script normalizes and byte-swaps it for comparison |
| `TARGET_DTB_MMC_ALIASES` | Optional ordered controller addresses that `mmc0..N` must resolve to |
| `TARGET_DTB_MEMORY_REG` | Optional expected `/memory@0 reg` value as space-separated hex cells |
| `TARGET_REQUIRED_Y` | Optional list of boot-critical symbols; all of them must be `y` in the final configuration |
| `BOARD_NAME`, `BOARDFAMILY`, `KERNEL_TARGET`, `BOOT_FDT_FILE`, `SERIALCON`, `BOOTCONFIG`, `BOARD_VENDOR` | Armbian's own board variables, kept under their upstream names because Armbian reads them by exactly those names. `BOARDFAMILY` (the board DTS family) is deliberately distinct from `TARGET_FAMILY` (the kernel linuxfamily) |

These boot-contract fields are **data, not code**, which is what lets a second board reuse
the HK1 Box packaging unchanged.

The current architecture mapping interface supports `arm64→arm64`, `armhf→arm`,
`amd64→x86`, and `riscv64→riscv`, but **the only targets actually enabled and provided with
configuration are Rockchip64 and HK1 Box**. A configuration that loads successfully does
not mean that architecture has passed a build; the toolchain, drivers, BTF/JIT, and boot
verification still have to be completed.

Profiles are trusted Bash files inside the repository and loading one executes its content;
this is not an interface that is safe for arbitrary user-supplied configuration.
`BUILD_TARGETS_DIR` exists only for trusted developer configuration and tests, and never
accepts web uploads or remotely downloaded profiles. Loading multiple times clears the
previous target's data and adapter so branches, architecture, and packaging mode cannot
leak across targets. When `BUILD_TARGETS_DIR` is redirected, the board-shim requirement is
not enforced, because such a caller is exercising profiles in isolation rather than
performing a full build.

## Adding an installation format adapter

Regular Armbian DEBs use `deb`. The `ophub-tar` adapter produces the `armbian-update`
installation TAR: it calls an isolated packaging container to build the initramfs and the
bundle and does not recompile the kernel. It is **not tied to any single board** — the
series lock, DTB path and boot checks all come from the target profile, so a new board that
needs the same treatment selects this adapter without any code change. Its implementation
lives in `scripts/package_ophub_tar.sh`.

To add a new adapter, create `scripts/lib/adapters/<name>.sh` and define three functions:

```bash
target_adapter_validate() { :; } # validate supported boards/architectures, no external work
target_package_artifacts() {
    # Arguments are, in order: branch, build start marker, actual kernel version.
    # Only handle artifacts from this build that were already validated;
    # failure must return non-zero.
    :
}
target_extra_release_assets() {
    # The argument is the actual kernel version. Print exactly one attachment
    # path per line on stdout. Log to stderr; return non-zero when a
    # mandatory installation bundle is missing.
    :
}
```

An adapter should only declare functions when sourced. Compilation, validation, and
publishing belong to the shared pipeline; never maintain a second copy of the source
download or module injection flow inside an adapter.

## Boundaries that must be preserved

- CPU architecture, Armbian family, board, and installation format are different concepts
  and are configured independently.
- Each job builds exactly one target and may build the branches it declares sequentially;
  parallel targets should use separate jobs and directories.
- Validation relies on the DEBs and embedded evidence of the current build, never on a
  temporary kernel worktree that Docker may have removed.
- Generic module modes, source pins, eBPF/network capabilities, and `.ko` documentation
  stay in the shared code.
- Publishing disabled still runs the compilation, evidence validation, and required
  installation bundle conversion; incomplete artifacts are never published.
- Full-system images and U-Boot flashing are not generated; local testing, CI builds, and
  real-device boots are reported separately.

```bash
python3 tests/test_hk1box.py
bash tests/test_kernel_injection.sh
python3 tests/test_live_log_server.py
python3 tests/test_redact_log_stream.py
```
