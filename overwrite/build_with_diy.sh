#!/bin/bash
# 作用: 自动将 tcp-brutal,amneziawg,nf_deaf 注入 Armbian 内核树并启动编译

# 确保用户补丁目录存在
mkdir -p userpatches

# 备份现有的 lib.config (如果存在)
[ -f userpatches/lib.config ] && cp userpatches/lib.config userpatches/lib.config.bak

# 注入动态 Hook 到 userpatches/lib.config
cat << 'EOF' > userpatches/lib.config
# 系统的内核配置钩子
custom_kernel_config() {
    # 向 Armbian 框架注册意图
    opts_y+=("CONFIG_TCP_CONG_BRUTAL")
    opts_y+=("CONFIG_WIREGUARD")
    opts_y+=("CONFIG_AMNEZIAWG")
    opts_y+=("CONFIG_NETFILTER_DEAF")

    # 确认安全环境
    if [[ ! -d "${PWD}/net/ipv4" ]] || [[ ! -f "${PWD}/.config" ]]; then
        return 0
    fi

    echo -e "\n\e[1;31m====================================================\e[0m"
    echo -e "\e[1;31m[HACK] 准备就绪！正在执行【内核本体强制注入】!!!\e[0m"
    echo -e "\e[1;31m====================================================\n\e[0m"

    local ipv4_dir="${PWD}/net/ipv4"
    local awg_dir="${PWD}/drivers/net/amneziawg"
    local nf_dir="${PWD}/net/netfilter"
    local proxy=""

    # ==========================================
    # 第一阶段：物理源码注入
    # ==========================================

    # --- 1. TCP Brutal ---
    if [[ ! -f "$ipv4_dir/tcp_brutal.c" ]]; then
        echo -e "\e[1;33m[1/3] 注入 TCP-Brutal...\e[0m"
        local tmp_brutal="/tmp/tcp-brutal-$$"
        GIT_TRACE=0 git clone --quiet --depth 1 "${proxy}https://github.com/apernet/tcp-brutal.git" "$tmp_brutal"
        cp "$tmp_brutal/brutal.c" "$ipv4_dir/tcp_brutal.c"
        rm -rf "$tmp_brutal"

        # Kconfig 注入 (移除 default y，我们用脚本硬改)
        echo -e "\nconfig TCP_CONG_BRUTAL\n\ttristate \"TCP Brutal\"\n" >> "$ipv4_dir/Kconfig"
        echo "obj-\$(CONFIG_TCP_CONG_BRUTAL) += tcp_brutal.o" >> "$ipv4_dir/Makefile"
    fi

    # --- 2. AmneziaWG ---
    if [[ ! -d "$awg_dir" ]]; then
        echo -e "\e[1;33m[2/3] 注入 AmneziaWG...\e[0m"
        mkdir -p "$awg_dir"
        local tmp_awg="/tmp/amneziawg-$$"
        GIT_TRACE=0 git clone --quiet --depth 1 "${proxy}https://github.com/NNdroid/amneziawg-linux-kernel-module.git" "$tmp_awg"
        cp -r "$tmp_awg/src/"* "$awg_dir/"
        rm -rf "$tmp_awg"

        echo 'source "drivers/net/amneziawg/Kconfig"' >> "${PWD}/drivers/net/Kconfig"
        echo "obj-\$(CONFIG_AMNEZIAWG) += amneziawg/" >> "${PWD}/drivers/net/Makefile"

        display_alert "AmneziaWG" "Renaming symbols to prevent collision with native WireGuard..." "info"

        find "$awg_dir" -type f -name "*.[ch]" -exec sed -i 's/\bwg_/awg_/g' {} +
        find "$awg_dir" -type f -name "*.[ch]" -exec sed -i 's/\bWG_/AWG_/g' {} +
        find "$awg_dir" -type f -name "*.[ch]" -exec sed -i 's/"wireguard"/"amneziawg"/g' {} +
    fi

    # --- 3. nf_deaf (NNdroid) ---
    if [[ ! -f "$nf_dir/nf_deaf.c" ]]; then
        echo -e "\e[1;33m[3/3] 注入 nf_deaf...\e[0m"
        curl -sL "${proxy}https://raw.githubusercontent.com/NNdroid/nf_deaf/refs/heads/main/nf_deaf.c" -o "$nf_dir/nf_deaf.c"
        
        if [ -f "$nf_dir/nf_deaf.c" ] && ! grep -q "NETFILTER_DEAF" "$nf_dir/Kconfig"; then
            echo -e "\nconfig NETFILTER_DEAF\n\ttristate \"Netfilter Deaf Module\"\n" >> "$nf_dir/Kconfig"
            echo "obj-\$(CONFIG_NETFILTER_DEAF) += nf_deaf.o" >> "$nf_dir/Makefile"
        fi
    fi
    
    bash "${USERPATCHES_PATH}/90_patch_brutal.sh" "${PWD}"
    # 捕获退出码，如果不是 0 (成功)，就直接结束整个大编译进程
    if [ $? -ne 0 ]; then
        echo "🚨 TCP Brutal 注入失败，安全阻断编译流程！"
        exit 1
    fi

    # ==========================================
    # 第二阶段：绝对强制配置 (.config 深度修补)
    # ==========================================
    echo -e "\e[1;32m[HACK] 源码就位，开始暴力修补内核配置 (.config)...\e[0m"

    local cfg_file="${PWD}/.config"
    
    # 强力设定函数：不仅将目标设为 y，还会把任何它依赖的东西设为 y
    force_y() {
        local cfg="$1"
        sed -i "s/^# ${cfg} is not set/${cfg}=y/g" "$cfg_file"
        sed -i "s/^${cfg}=m/${cfg}=y/g" "$cfg_file"
        if ! grep -q "^${cfg}=y" "$cfg_file"; then
            echo "${cfg}=y" >> "$cfg_file"
        fi
    }
    
    # 强力设定函数：强制将目标设为 m (编译为独立 .ko 模块)
    force_m() {
        local cfg="$1"
        # 1. 唤醒：把被注释掉的（未设置的）改成 =m
        sed -i "s/^# ${cfg} is not set/${cfg}=m/g" "$cfg_file"
        # 2. 降级：把被强制内置的（=y）改成 =m
        sed -i "s/^${cfg}=y/${cfg}=m/g" "$cfg_file"
        # 3. 兜底：如果文件里根本找不到这个 =m 的配置，直接追加到末尾
        if ! grep -q "^${cfg}=m" "$cfg_file"; then
            echo "${cfg}=m" >> "$cfg_file"
        fi
    }

    # 1. 强制 Brutal 内置
    force_y "CONFIG_TCP_CONG_BRUTAL"
    # Brutal 依赖项强化
    force_y "CONFIG_NET_SCHED"
    force_y "CONFIG_NET_SCH_FQ"

    # 2. 强制 WireGuard 内置
    force_y "CONFIG_WIREGUARD"
    # WG 依赖项强化
    force_y "CONFIG_NET"
    force_y "CONFIG_INET"
    force_y "CONFIG_CRYPTO"

    # 3. 强制 AmneziaWG 内置
    force_y "CONFIG_AMNEZIAWG"

    # 4. 强制 nf_deaf 内置
    force_y "CONFIG_NETFILTER_DEAF"
    force_y "CONFIG_NETFILTER"
    force_y "CONFIG_NETFILTER_ADVANCED"
    force_y "CONFIG_NF_CONNTRACK"
    force_y "CONFIG_NF_NAT"

    # ==========================================
    # 第三阶段：核对与锁定
    # ==========================================
    # 使用 oldconfig 自动处理依赖（不要用 olddefconfig，有时会丢弃我们的强制配置）
    yes "" | make ARCH=arm64 oldconfig >/dev/null 2>&1

    # 最后再做一次死磕式确认（防止 oldconfig 擅自修改）
    force_y "CONFIG_NETFILTER_DEAF"
    force_y "CONFIG_AMNEZIAWG"

    echo -e "\e[1;32m[HACK] 内置强制注入完成！\e[0m"
    echo -e "\e[1;31m====================================================\n\e[0m"
}
EOF

echo "[*] Brutal 构建 Hook 注入完成！"
echo "[*] 启动 Armbian 编译流程..."

# 4. 透传所有命令行参数给官方编译脚本
./compile.sh "$@"

#./build_with_brutal.sh build BOARD=nanopi-r5s BRANCH=current BUILD_DESKTOP=no BUILD_MINIMAL=no KERNEL_CONFIGURE=yes BUILD_ONLY=kernel RELEASE=trixie KERNEL_BTF=yes 
#./build_with_brutal.sh build BOARD=hinlink-h66k BRANCH=current BUILD_DESKTOP=no BUILD_MINIMAL=no KERNEL_CONFIGURE=no BUILD_ONLY=kernel RELEASE=trixie KERNEL_BTF=yes
