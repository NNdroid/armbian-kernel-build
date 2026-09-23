# armbian-kernel-build

自动跟踪 Armbian Rockchip64 内核版本，并将下列第三方网络模块以可复现方式接入内核构建：

- TCP-Brutal v2（`HyNetworks/tcp-brutal` 的 `exp/xan-fix` 提交）
- AmneziaWG
- nf_deaf

## 注入设计

注入逻辑位于 `userpatches/lib.config`，使用 Armbian 的 `custom_kernel_config` hook：

- 默认使用不可变 commit SHA，并在下载后校验实际提交；
- 验证上游文件布局后再替换内核源码目录；
- Kconfig/Makefile 使用带标记的幂等块，重复执行不会产生重复条目；
- 自动清理旧版单文件 TCP-Brutal、旧 `tcp.c` 补丁和旧 nf_deaf 布局；
- 由 Armbian 统一执行 `scripts/config` 和 `olddefconfig`，不硬编码 CPU 架构；
- 最终 `.config` 校验前会扫描内核树实际定义的 Kconfig 符号；完整功能清单中的
  任何能力若不存在或被依赖关系关闭都会让构建失败，避免发布功能缩水的内核；
- TCP-Brutal、AmneziaWG 和 nf_deaf 默认直接内建；AmneziaWG 作为 WireGuard-compatible 实现时，原生 WireGuard 默认关闭以避免静态链接冲突。

## 完整 eBPF / BTF / CO-RE

默认 `ENABLE_FULL_EBPF=yes`，并显式设置 `KERNEL_BTF=yes`。hook 会开启并在内核编译完成后检查实际 `.config`，覆盖：

- eBPF syscall、ARM64 JIT、始终 JIT，以及默认禁用非特权 eBPF；
- 内核与模块 BTF、DWARF5 和 CO-RE 所需类型信息；
- cgroup BPF、BPF LSM（同时将 `bpf` 加入 `CONFIG_LSM` 启动顺序）；
- XDP/AF_XDP、tc classifier/action、netfilter 和 lightweight tunnel BPF；
- kprobe、uprobe、ftrace 与 BPF events。

任何必需选项在 `olddefconfig` 后被依赖关系关闭，构建包装器都会返回失败，避免上传功能不完整的内核。`CONFIG_BPF_UNPRIV_DEFAULT_OFF=y` 只默认限制非特权用户；root/CAP_BPF 使用的 eBPF 功能不受影响。网卡的原生 XDP 能力仍取决于具体驱动，内核通用 XDP/AF_XDP 支持则会启用。

资源受限且明确不需要 BTF/CO-RE 时，可同时设置 `ENABLE_FULL_EBPF=no KERNEL_BTF=no`；默认发布构建不建议关闭。

## 完整网络功能集

默认 `ENABLE_FULL_NETWORKING=yes`。hook 会强制启用并在 `olddefconfig` 和编译完成后逐项检查：

- MPLS 路由、LWT/IP tunnel、GSO 和 tc MPLS action；
- SRv6 LWT、HMAC、BPF 以及 IPv4/IPv6 policy routing；
- VXLAN、Geneve、IPv4 GRE、IPv6 GRE、FOU 与 Open vSwitch tunnel ports；
- 内建 AmneziaWG（原生 WireGuard 默认关闭）、BBR 和 FQ qdisc（只保证可用，不擅自修改系统默认拥塞算法）；
- nftables 全协议族和常用 expressions、TPROXY、SYNPROXY、NPTv6 以及 xtables 兼容路径；
- Linux bridge、VLAN filtering、MRP/CFM、bridge netfilter/ebtables 和 Bluetooth BNEP；
- USB Gadget dual-role 基础设施，以及 ConfigFS/FunctionFS 的串口、网络、存储、HID、音频、MIDI、UVC、打印和 target functions。

这里的“支持”表示内核及模块配置已通过最终 `.config` 校验；具体 USB device role、原生 XDP 或硬件卸载能力仍取决于开发板控制器、设备树和网卡驱动。

`NF_CONNTRACK` 与 `VLAN_8021Q` 在配置阶段仍优先请求内建，但它们是可模块化的基础能力；若目标 Armbian 内核最终保留为 `m`，验收会接受，关闭或缺失仍会导致构建失败。

可以通过环境变量调整来源或构建模式：

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

构建模式支持 `y`（直接内建）、`m`（可加载模块）和 `n`（关闭）。默认组合不需要在系统启动后执行 `modprobe brutal`、`modprobe amneziawg` 或 `modprobe nf_deaf`；三项能力随内核启动直接就绪。

更新上游版本时只设置不可变的 `*_COMMIT` 即可，未显式设置的 `*_REF` 会自动采用同一提交；只有特殊 Git 服务需要 fetch hint 时才同时设置 `*_REF`。不建议把可移动分支当作期望提交。默认以 AmneziaWG 取代原生 WireGuard；如果重新启用原生 WireGuard，不能让二者同时为 `y`，hook 会拒绝该组合以避免静态链接符号冲突。

## 验证

```bash
bash -n build.sh overwrite/build_with_diy.sh userpatches/lib.config tests/test_kernel_injection.sh
bash tests/test_kernel_injection.sh
python3 tests/test_live_log_server.py
```

回归测试会下载固定提交，在模拟内核树中验证 v1 迁移、源码完整性、来源记录、Kconfig/Kbuild 接入和重复执行幂等性；同时模拟 Docker 构建结束后源码 worktree 已被清理的场景，确认包装器仍能只依靠新生成的 `linux-image` 包完成校验。完整编译仍由 GitHub Actions 的 Armbian 构建完成。

## Release notes 与附件

每次成功编译都会在 Armbian 封装 `linux-image` 时，把最终配置、Kconfig 符号清单、源码 pin 和 defconfig 差异作为构建证据写入 `.deb`。Docker 清理临时源码树后，包装器从该包生成 Release notes，而不是依赖已消失的 worktree 或使用固定文案。内容包括：

- 内核 release、Armbian 分支、板型、架构、userspace release、Armbian/build 与内核源码基线提交；
- TCP-Brutal v2、AmneziaWG、nf_deaf 与原生 WireGuard 的最终构建模式和源码提交；
- eBPF/BTF/CO-RE 最终校验状态；
- MPLS/SRv6、隧道、netfilter、BBR、bridge/BNEP 和 USB Gadget 的最终配置摘要；
- 与同一份 Armbian 补丁后源码树生成的标准 `arm64 defconfig` 之间的配置差异数量；
- 每个 `.deb` 的大小和 SHA256，以及仓库提交和 UTC 构建时间。

Release 还会附带最终 `<branch>-kernel.config` 和完整 `<branch>-config-vs-arm64-defconfig.txt`；如果基线生成失败，还会附带 `arm64-defconfig-build.log` 便于诊断。该比较反映内核配置差异；Armbian 的 Rockchip64、设备树和其他源码补丁属于额外的源码级差异，不会被误写成原版 kernel.org 配置差异。

## GitHub Actions 实时构建日志

工作流可以在构建期间通过 ngrok 提供一个只读实时日志页面。请在仓库设置中配置：

- Secret `NGROK_AUTHTOKEN`：重新生成的 ngrok token；不要把 token 写进仓库；
- Secret `NGROK_LOG_AUTH`：页面的 HTTP Basic Auth 凭据，格式为 `username:password`，请使用独立的强密码；
- Secret `NGROK_URL`：预留的完整 ngrok HTTPS 地址，例如你在 ngrok 账户中绑定的静态域名。

可在仓库目录中通过 `gh` 的安全输入提示逐项设置，避免把值留在 shell 历史中：

```bash
gh secret set NGROK_AUTHTOKEN
gh secret set NGROK_LOG_AUTH
gh secret set NGROK_URL
```

三个配置项都只从 Repository secrets 读取。启动成功后，workflow notice 和 Job Summary 只提示端点就绪，不回显 Secret 中的 URL；直接访问你保存为 `NGROK_URL` 的地址。

实时页面提供带行号的日志视图、ANSI 控制字符清理、搜索与上/下一个匹配、指定行跳转、自动换行、跟随末尾和完整日志下载。界面支持中文、日文、英文、法文和德文；主题可选择自动、浅色或深色，自动模式跟随浏览器/设备配色。顶部同时显示目标板、架构、发行版、内核分支和版本，以及 Runner 的系统、CPU、负载、内存、磁盘、构建耗时和日志大小。为避免长时间编译耗尽浏览器内存，前端最多保留约 5 MiB 或 50,000 行的可见日志，完整原始日志仍可通过 `/download` 获取。

浏览器默认通过同源 `/api/events` SSE 通道接收新增日志、构建状态和资源指标；服务端每 15 秒发送心跳，并用日志字节偏移作为 SSE event ID。连接恢复时优先读取 `Last-Event-ID`，因此不会从头重复下载。连续 SSE 连接失败时，页面自动回退到 `/api/log?offset=...` 增量轮询，并通过 `/api/metrics` 更新设备与资源信息；`/download` 仍可下载当前完整日志。页面、SSE、指标、增量 API 和下载入口均要求 Basic Auth，只有不包含日志的 `/healthz` 无需认证。

该日志由 `tee` 在 GitHub 掩码处理前写入，因此必须保护好 `NGROK_LOG_AUTH`，并避免让构建脚本主动打印秘密。端点只在 job 运行期间存在，工作流不会把完整日志上传到 LogPasta 或其他 paste 服务；构建结束后的记录仍以 GitHub Actions 自身日志为准。
