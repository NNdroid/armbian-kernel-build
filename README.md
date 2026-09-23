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
- 最终 `.config` 校验前会先扫描内核树 Kconfig 实际定义的符号：清单中随内核版本
  增删而消失的符号会被跳过（warn 日志 + Release notes 记录），而不是让构建失败；
- TCP-Brutal、AmneziaWG 和 nf_deaf 默认构建为模块，原生 WireGuard 默认内置。

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
- 原生 WireGuard、BBR 和 FQ qdisc（只保证可用，不擅自修改系统默认拥塞算法）；
- nftables 全协议族和常用 expressions、TPROXY、SYNPROXY、NPTv6 以及 xtables 兼容路径；
- Linux bridge、VLAN filtering、MRP/CFM、bridge netfilter/ebtables 和 Bluetooth BNEP；
- USB Gadget dual-role 基础设施，以及 ConfigFS/FunctionFS 的串口、网络、存储、HID、音频、MIDI、UVC、打印和 target functions。

这里的“支持”表示内核及模块配置已通过最终 `.config` 校验；具体 USB device role、原生 XDP 或硬件卸载能力仍取决于开发板控制器、设备树和网卡驱动。

可以通过环境变量调整来源或构建模式：

```bash
TCP_BRUTAL_REPOSITORY=https://github.com/HyNetworks/tcp-brutal.git
TCP_BRUTAL_REF=<commit-or-ref>
TCP_BRUTAL_COMMIT=<expected-full-sha>
TCP_BRUTAL_MODE=m

AMNEZIAWG_REPOSITORY=https://github.com/NNdroid/amneziawg-linux-kernel-module.git
AMNEZIAWG_REF=<commit-or-ref>
AMNEZIAWG_COMMIT=<expected-full-sha>
AMNEZIAWG_MODE=m

NF_DEAF_REPOSITORY=https://github.com/NNdroid/nf_deaf.git
NF_DEAF_REF=<commit-or-ref>
NF_DEAF_COMMIT=<expected-full-sha>
NF_DEAF_MODE=m

WIREGUARD_MODE=y
ENABLE_FULL_EBPF=yes
ENABLE_FULL_NETWORKING=yes
KERNEL_BTF=yes
```

更新上游版本时应同时更新 `*_REF` 和 `*_COMMIT`。不建议只使用可移动分支。AmneziaWG 与原生 WireGuard 不能同时设置为 `y`；hook 会拒绝该组合，避免静态链接符号冲突。

## 验证

```bash
bash -n build.sh overwrite/build_with_diy.sh userpatches/lib.config tests/test_kernel_injection.sh
bash tests/test_kernel_injection.sh
```

回归测试会下载固定提交，在模拟内核树中验证 v1 迁移、源码完整性、来源记录、Kconfig/Kbuild 接入和重复执行幂等性。完整编译仍由 GitHub Actions 的 Armbian 构建完成。

## Release notes 与附件

每次成功编译都会从最终内核树动态生成 Release notes，而不是使用固定文案。内容包括：

- 内核 release、Armbian 分支、板型、架构和 userspace release；
- TCP-Brutal v2、AmneziaWG、nf_deaf 与原生 WireGuard 的最终构建模式和源码提交；
- eBPF/BTF/CO-RE 最终校验状态；
- MPLS/SRv6、隧道、netfilter、BBR、bridge/BNEP 和 USB Gadget 的最终配置摘要；
- 与同一份 Armbian 补丁后源码树生成的标准 `arm64 defconfig` 之间的配置差异数量；
- 每个 `.deb` 的大小和 SHA256，以及仓库提交和 UTC 构建时间。

Release 还会附带最终 `<branch>-kernel.config` 和完整 `<branch>-config-vs-arm64-defconfig.txt`。该比较反映内核配置差异；Armbian 的 Rockchip64、设备树和其他源码补丁属于额外的源码级差异，不会被误写成原版 kernel.org 配置差异。
