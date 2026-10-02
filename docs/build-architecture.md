# 构建脚本架构与扩展指南

所有板型都走同一个 Armbian 编译入口，不为每个 CPU 架构复制一套构建脚本。
默认目标仍是 Rockchip64；HK1 Box 保持 edge / 7.2 和现有 TAR 安装格式。

```text
build.sh                         公共入口、只读目标查询
├── userpatches/config/build-targets/*.conf
│                                目标数据：板型、family、架构、分支、runner
└── scripts/lib/
    ├── targets.sh               发现目标、校验配置、加载适配器
    ├── pipeline.sh              版本比较 → 编译 → 校验 → 打包 → 发布
    ├── logging.sh / host.sh     日志、主机依赖、文件同步
    ├── versions.sh              Armbian / kernel.org / Release 版本解析
    ├── artifacts.sh             本次构建产物定位
    ├── release.sh               发布与附件清单
    ├── armbian.sh               在正确目录调用构建包装器
    ├── board-contract.sh        对 DEB 内证据执行板级检查
    └── adapters/*.sh            可插拔安装格式转换

overwrite/build_with_diy.sh      Armbian 构建与产物验证流程
└── overwrite/lib/kernel-build/
    ├── common.sh               参数、配置、证据读取与临时文件清理
    ├── module-assets.sh        从已构建 DEB 导出模块附件
    └── release-metadata.sh     最终配置、差异、模块说明和发布元数据

userpatches/boards/              Armbian 板型与驱动配置钩子
userpatches/kernel/archive/      板级源码补丁
userpatches/extensions/          在打包阶段保存源代码与配置证据
```

## 只读查询

查询命令不会安装软件、克隆源码、编译或发布：

```bash
bash build.sh --list-targets
bash build.sh --describe-target hk1box
BUILD_BRANCH=edge bash build.sh --describe-target rockchip64
```

`--describe-target` 输出稳定的 `key=value` 信息。GitHub Actions 的 prepare 作业
直接用它选择 runner 和页面设备信息，目标输入是字符串，无需再维护目标枚举。
`scripts/build_targets.sh` 保留为旧调用者的兼容入口；测试仍可使用
`BUILD_SCRIPT_LIB_ONLY=yes source build.sh` 加载函数而不执行构建。

## 新增一个标准 DEB 目标

1. 添加 `userpatches/config/build-targets/<目标名>.conf`。
2. 确认 Armbian 已有对应 BOARD；否则添加自己的 `userpatches/boards` 配置。
3. 有板级差异时，添加对应内核系列的补丁，并声明启动关键驱动要求。
4. 添加回归测试，运行只读查询、构建和实际设备验证。

目标名只能包含小写字母、数字和连字符，不允许路径、换行或 shell 表达式。
以下是模板，不是已经适配或验证过的 RISC-V 板型：

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
TARGET_SERIES=()
TARGET_BOARD_DTB=''
TARGET_REQUIRED_Y=()
```

| 配置 | 作用 |
|---|---|
| `TARGET_BOARD` / `TARGET_FAMILY` | Armbian 板型与 DEB family；二者不可混用 |
| `TARGET_ARCH` / `TARGET_KBUILD_ARCH` | Debian 包架构与 Kbuild 架构；产物证据必须一致 |
| `TARGET_RUNNER` | Actions runner 标签；跨架构编译能力由 Armbian/工具链决定 |
| `TARGET_VERSION_CONFIG` | Armbian `config/sources/families/` 下的版本配置相对路径 |
| `TARGET_BRANCHES` | 支持的分支；请求未声明的分支会在构建前失败 |
| `TARGET_SERIES` | 可选的分支系列锁，如 `([edge]=7.2)`；防止补丁误用于新系列 |
| `TARGET_RELEASE_PREFIX` | 平台独立的 Release 前缀；保留原 Rockchip 标签兼容性 |
| `TARGET_ADAPTER` | `scripts/lib/adapters/` 下的适配器名称 |
| `TARGET_BOARD_DTB` | 可选 DTB 相对路径；声明后必须在包内找到源码哈希和已编译 DTB |
| `TARGET_REQUIRED_Y` | 可选启动关键符号列表；在最终配置里必须全部为 `y` |

当前架构映射接口支持 `arm64→arm64`、`armhf→arm`、`amd64→x86`、
`riscv64→riscv`，但**实际启用并提供配置的目标只有 Rockchip64 与 HK1 Box**。
新增配置能加载不等于该架构已通过编译；工具链、驱动、BTF/JIT 和启动验证仍需完成。

配置是仓库内可信的 Bash 文件，加载会执行其中内容；不是可安全上传任意用户配置的接口。
`BUILD_TARGETS_DIR` 仅用于可信开发配置和测试，不接受网页上传或远程下载的配置。
多次加载会清空前一个目标的数据和适配器，避免分支、架构或打包模式泄漏。

## 新增安装格式适配器

普通 Armbian DEB 使用 `deb`。当前 `ophub-tar` 专用于 HK1 Box ARM64，调用隔离的
打包容器生成 initramfs 和安装 TAR，不重新编译内核。其实现保留在
`scripts/package_hk1box.sh`，板型专用细节不会进入公共构建流程。

新增 `scripts/lib/adapters/<名称>.sh`，定义三个函数：

```bash
target_adapter_validate() { :; } # 验证支持的板型/架构，不进行外部操作
target_package_artifacts() {
    # 参数依次为 branch、构建开始时间 marker、实际内核版本。
    # 仅处理本次构建且已校验的产物；失败必须返回非零。
    :
}
target_extra_release_assets() {
    # 参数为实际内核版本。stdout 每行只输出一个附件路径。
    # 日志写 stderr；必须存在的安装包缺失时返回非零。
    :
}
```

适配器被 source 时只应声明函数。编译、校验和发布由公共流程负责；
不得在适配器里再维护一套源码下载或模块注入过程。

## 必须保持的边界

- CPU 架构、Armbian family、板型、安装格式是不同概念，各自独立配置。
- 每个作业只构建一个目标，可以顺序构建它声明的多个分支；并行目标应使用独立作业/目录。
- 验证依据是本次构建的 DEB 和内嵌证据，不依赖 Docker 清理后的临时内核 worktree。
- 通用模块模式、源码 pin、eBPF/网络能力和 `.ko` 说明继续由共享代码处理。
- 发布关闭仍执行编译、证据验证和必要安装包转换，不发布不完整的产物。
- 当前不生成整机镜像或刷写 U-Boot；本地测试、CI 编译、真机启动分别报告。

```bash
python3 tests/test_hk1box.py
bash tests/test_kernel_injection.sh
python3 tests/test_live_log_server.py
python3 tests/test_redact_log_stream.py
```
