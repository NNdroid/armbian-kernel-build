#!/bin/bash

# ==============================================================================
# 脚本名称: kernel_sync_build.sh
# 脚本描述: 自动化 Armbian 内核构建与发布工具。
#           支持从 kernel.org 获取最新版本，对比 GitHub 已发布版本，
#           自动触发构建并上传至 GitHub Release。
# ==============================================================================

# ==========================================
# 日志输出系统 (带颜色高亮，方便调试)
# ==========================================
log_info()  { echo -e "\e[32m[INFO]\e[0m $1"; }
log_debug() { echo -e "\e[34m[DEBUG]\e[0m $1"; }
log_warn()  { echo -e "\e[33m[WARN]\e[0m $1"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; }

# ==============================================================================
# 函数: sync_tree
# 描述: 递归同步两个目录的内容。
# 参数:
#   $1 - SRC_DIR:  源目录路径
#   $2 - DEST_DIR: 目标目录路径
# 返回: 0 - 成功; 1 - 失败
# ==============================================================================
function sync_tree() {
    if [ "$#" -ne 2 ]; then
        log_error "用法: ${FUNCNAME[0]} <源目录> <目标目录>"
        return 1
    fi

    local SRC_DIR="${1%/}"
    local DEST_DIR="${2%/}"

    # 校验源目录是否存在
    if [ ! -d "$SRC_DIR" ]; then
        log_error "源目录 '$SRC_DIR' 不存在！"
        return 1
    fi

    # 处理相对路径转换为绝对路径，确保子进程中路径依然有效
    local DEST_ABS
    case "$DEST_DIR" in
        /*) DEST_ABS="$DEST_DIR" ;;
        *)  DEST_ABS="$PWD/$DEST_DIR" ;;
    esac

    log_debug "开始精确映射同步: [$SRC_DIR] => [$DEST_ABS]"

    # 在子 Shell 中执行，避免 cd 影响主进程
    (
        cd "$SRC_DIR" || exit 1
        # 使用 find 遍历，并利用 while read 确保文件名中含有空格也能处理
        find . | while read -r ITEM; do
            if [ "$ITEM" == "." ]; then continue; fi

            local REL_PATH="${ITEM#./}"
            local TARGET_ITEM="$DEST_ABS/$REL_PATH"

            if [ -d "$ITEM" ]; then
                # 如果是目录且目标位置不存在，则创建
                if [ ! -d "$TARGET_ITEM" ]; then
                    mkdir -p "$TARGET_ITEM"
                    log_debug "  [创建目录] $TARGET_ITEM"
                fi
            elif [ -f "$ITEM" ]; then
                # 如果是文件，确保父目录存在后执行强制拷贝
                local TARGET_DIR="${TARGET_ITEM%/*}"
                mkdir -p "$TARGET_DIR"
                cp -af "$ITEM" "$TARGET_ITEM"
                log_debug "  [覆盖文件] $TARGET_ITEM"
            fi
        done
    )

    # 检查子 Shell 退出状态
    if [ $? -eq 0 ]; then
        log_info "目录同步完成: $SRC_DIR"
        return 0
    else
        log_error "同步过程中发生错误！"
        return 1
    fi
}

# ==============================================================================
# 函数: get_kernel_version
# 描述: 从 Armbian 的配置文件中解析指定分支对应的内核大版本号。
# 参数:
#   $1 - target_branch: 分支名称 (如 'current' 或 'edge')
#   $2 - file_path:     配置文件路径 (如 'rockchip64_common.inc')
# 示例: get_kernel_version "current" "config.inc" -> 返回 "6.1"
# ==============================================================================
function get_kernel_version() {
    local target_branch="$1"
    local file_path="$2"

    # 使用 awk 状态机解析 shell case 语法块
    awk -v branch="$target_branch" '
        # 寻找匹配分支的行，例如 current)
        $0 ~ "^[ \t]*" branch "\\)" { in_block = 1; next }
        # 在匹配的分支块内寻找 KERNEL_MAJOR_MINOR 变量
        in_block && /KERNEL_MAJOR_MINOR[ \t]*=/ {
            split($0, arr, "\"")
            print arr[2]
            exit
        }
        # 遇到双分号意味着该分支块结束
        in_block && /;;/ { in_block = 0 }
    ' "$file_path"
}

# ==============================================================================
# 函数: get_latest_github_tag
# 描述: 通过 git ls-remote 获取指定仓库中符合特定前缀的最新 Git Tag。
# 参数:
#   $1 - repo_url: GitHub 仓库地址
#   $2 - prefix:   Tag 前缀 (如 'current-6.1')
# 返回: 最新的 Tag 字符串 (如 'current-6.1.50')
# ==============================================================================
get_latest_github_tag() {
    local repo_url="$1"
    local prefix="$2"

    if [[ -z "$repo_url" || -z "$prefix" ]]; then
        return 1
    fi

    local latest_tag
    # 流程: 获取所有 tags -> 过滤掉 ^/ref/tags/ -> 移除 ^^{} 标记 -> 
    #       匹配前缀 -> 版本排序 -> 取最后一个
    latest_tag=$(git ls-remote --tags "$repo_url" 2>/dev/null | \
        awk -F/ '{print $3}' | \
        sed 's/\^{}//' | \
        grep -E "^v?${prefix}" | \
        sort -Vu | \
        tail -n 1)

    if [[ -z "$latest_tag" ]]; then
        return 1
    fi
    echo "$latest_tag"
}

# ==============================================================================
# 函数: get_kernel_org_latest
# 描述: 从 kernel.org 的 CDN 目录解析指定大版本下的最新小版本。
# 参数:
#   $1 - prefix: 大版本前缀 (如 '6.1')
# 示例: get_kernel_org_latest "6.1" -> 返回 "6.1.102"
# ==============================================================================
get_kernel_org_latest() {
    local prefix="$1"
    local major_ver
    major_ver=$(echo "$prefix" | cut -d. -f1)
    local target_url="https://cdn.kernel.org/pub/linux/kernel/v${major_ver}.x/"

    local latest_version
    # 使用 curl 获取网页 -> 正则匹配文件名 -> 提取版本号 -> 排序取最新
    latest_version=$(curl -s "$target_url" | \
        grep -oE "linux-${prefix}\.[0-9]+\.tar\.xz" | \
        sed 's/linux-//;s/\.tar\.xz//' | \
        sort -Vu | \
        tail -n 1)

    if [[ -z "$latest_version" ]]; then
        return 1
    fi
    echo "$latest_version"
}

# ==============================================================================
# 函数: upload_to_github_release
# 描述: 使用 GitHub CLI (gh) 创建 Release 并上传构建生成的 .deb 文件。
# 参数:
#   $1 - tag_name:      发布使用的 Tag 名称 (如: current-6.12.1)
#   $2 - files_pattern: 文件通配符路径 (如: output/*.deb)
# 返回: 0 - 成功; 1 - 失败
# ==============================================================================
function upload_to_github_release() {
    local tag_name="$1"
    local files_pattern="$2"

    # 环境校验: 是否安装了 gh 客户端
    if ! command -v gh &> /dev/null; then
        log_error "未安装 GitHub CLI (gh)。请检查环境依赖！"
        return 1
    fi

    log_info "检查是否有文件匹配: ${files_pattern}"
    
    # 扩展通配符并检查文件是否存在
    # shellcheck disable=SC2086
    ls -la ${files_pattern} >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_warn "未找到匹配的文件: ${files_pattern}，跳过上传。"
        return 1
    fi

    log_info "正在创建 GitHub Release 并上传产物: ${tag_name} ..."
    
    # 调用 gh 创建发布
    # --title: 标题, --notes: 详细描述
    # shellcheck disable=SC2086
    gh release create "${tag_name}" ${files_pattern} \
        --title "Auto Build ${tag_name}" \
        --notes "Automated kernel build synced from kernel.org (Version: ${tag_name})"
        
    if [ $? -eq 0 ]; then
        log_info "✅ 成功发布并上传产物到: ${tag_name}"
    else
        log_error "❌ 上传 Release 失败！请检查网络、权限及 Tag 是否冲突。"
    fi
}

# ==============================================================================
# 主逻辑流程开始
# ==============================================================================

log_info "1. 环境初始化中..."
# 默认安装必要的工具包
sudo apt update && sudo apt install git lsof curl wget jq yq -y >/dev/null 2>&1

# 下载 Armbian 的配置包含文件以解析内核版本
ROCKCHIP64_CONFIG_FILE="./rockchip64_common.inc"
log_debug "正在下载 ${ROCKCHIP64_CONFIG_FILE}..."
wget -q -O ${ROCKCHIP64_CONFIG_FILE} https://raw.githubusercontent.com/armbian/build/refs/heads/main/config/sources/families/include/rockchip64_common.inc

# ------------------------------------------------------------------------------
# 2. 版本比对逻辑
# ------------------------------------------------------------------------------
# 获取配置文件中定义的分支大版本 (如 6.6)
CONFIG_CURRENT_KERNEL_VER=$(get_kernel_version current ${ROCKCHIP64_CONFIG_FILE})
CONFIG_EDGE_KERNEL_VER=$(get_kernel_version edge ${ROCKCHIP64_CONFIG_FILE})

# 获取当前本地仓库的 Git URL
CUR_GIT_REPO_URL=$(git remote get-url origin 2>/dev/null)
if [[ -z "$CUR_GIT_REPO_URL" ]]; then
    log_error "未能获取到当前 Git 的 remote url，请在 Git 仓库内执行！"
    exit 1
fi

# 获取 GitHub 上已经发布的最新的 Tag 和 版本
RELEASE_CURRENT_KERNEL_VER=$(get_latest_github_tag "${CUR_GIT_REPO_URL}" "current-${CONFIG_CURRENT_KERNEL_VER}")
RELEASE_CURRENT_KERNEL_VER2=$(echo "${RELEASE_CURRENT_KERNEL_VER}" | awk -F'-' '{print $2}')

RELEASE_EDGE_KERNEL_VER=$(get_latest_github_tag "${CUR_GIT_REPO_URL}" "edge-${CONFIG_EDGE_KERNEL_VER}")
RELEASE_EDGE_KERNEL_VER2=$(echo "${RELEASE_EDGE_KERNEL_VER}" | awk -F'-' '{print $2}')

# 获取 Kernel.org 官方目前的最新小版本 (如 6.6.15)
KERNEL_ORG_CURRENT_VER=$(get_kernel_org_latest "${CONFIG_CURRENT_KERNEL_VER}")
KERNEL_ORG_EDGE_VER=$(get_kernel_org_latest "${CONFIG_EDGE_KERNEL_VER}")

# 决定是否需要触发更新
NEED_UPDATE_CURRENT_KERNEL=false
NEED_UPDATE_EDGE_KERNEL=false

if [[ "${RELEASE_CURRENT_KERNEL_VER2}" != "${KERNEL_ORG_CURRENT_VER}" && -n "${KERNEL_ORG_CURRENT_VER}" ]]; then
    NEED_UPDATE_CURRENT_KERNEL=true
fi
if [[ "${RELEASE_EDGE_KERNEL_VER2}" != "${KERNEL_ORG_EDGE_VER}" && -n "${KERNEL_ORG_EDGE_VER}" ]]; then
    NEED_UPDATE_EDGE_KERNEL=true
fi

# ------------------------------------------------------------------------------
# 3. 执行构建与同步
# ------------------------------------------------------------------------------
if [[ "$NEED_UPDATE_CURRENT_KERNEL" == false && "$NEED_UPDATE_EDGE_KERNEL" == false ]]; then
    log_info "内核版本已是最新，无需触发构建。退出。"
    exit 0
fi

# 准备 Armbian 构建环境
if [ -d "build" ]; then
    log_info "更新现有 build 目录..."
    sync_tree ./overwrite ./build
    sync_tree ./userpatches ./build/userpatches
    cd build && git pull && cd ..
else
    log_info "初始化克隆 build 目录..."
    git clone https://github.com/armbian/build
    sync_tree ./overwrite ./build
    sync_tree ./userpatches ./build/userpatches
fi

# 执行构建脚本
cd build || exit 1
chmod +x ./build_with_diy.sh

if [[ "$NEED_UPDATE_CURRENT_KERNEL" == true ]]; then
    log_info "🚀 开始构建 current 分支内核: ${KERNEL_ORG_CURRENT_VER}"
    ./build_with_diy.sh kernel BOARD=nanopi-r5s BRANCH=current RELEASE=trixie
fi

if [[ "$NEED_UPDATE_EDGE_KERNEL" == true ]]; then
    log_info "🚀 开始构建 edge 分支内核: ${KERNEL_ORG_EDGE_VER}"
    ./build_with_diy.sh kernel BOARD=nanopi-r5s BRANCH=edge RELEASE=trixie
fi

# ------------------------------------------------------------------------------
# 4. 发布产物
# ------------------------------------------------------------------------------
cd ..

if [[ "$NEED_UPDATE_CURRENT_KERNEL" == true ]]; then
    upload_to_github_release "current-${KERNEL_ORG_CURRENT_VER}" "./build/output/debs/*current*.deb"
fi

if [[ "$NEED_UPDATE_EDGE_KERNEL" == true ]]; then
    upload_to_github_release "edge-${KERNEL_ORG_EDGE_VER}" "./build/output/debs/*edge*.deb"
fi

log_info "🎉 所有自动化流程已成功结束。"
