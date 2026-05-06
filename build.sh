#!/bin/bash

# ==========================================
# 日志输出系统 (带颜色高亮，方便调试)
# ==========================================
log_info()  { echo -e "\e[32m[INFO]\e[0m $1"; }
log_debug() { echo -e "\e[34m[DEBUG]\e[0m $1"; }
log_warn()  { echo -e "\e[33m[WARN]\e[0m $1"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; }

# ==========================================
# 函数: sync_tree
# 参数: $1 - 源目录
#       $2 - 目的目录
# ==========================================
function sync_tree() {
    if [ "$#" -ne 2 ]; then
        log_error "用法: ${FUNCNAME[0]} <源目录> <目标目录>"
        return 1
    fi

    local SRC_DIR="${1%/}"
    local DEST_DIR="${2%/}"

    if [ ! -d "$SRC_DIR" ]; then
        log_error "源目录 '$SRC_DIR' 不存在！"
        return 1
    fi

    local DEST_ABS
    case "$DEST_DIR" in
        /*) DEST_ABS="$DEST_DIR" ;;
        *)  DEST_ABS="$PWD/$DEST_DIR" ;;
    esac

    log_debug "开始精确映射同步: [$SRC_DIR] => [$DEST_ABS]"

    (
        cd "$SRC_DIR" || exit 1
        find . | while read -r ITEM; do
            if [ "$ITEM" == "." ]; then continue; fi

            local REL_PATH="${ITEM#./}"
            local TARGET_ITEM="$DEST_ABS/$REL_PATH"

            if [ -d "$ITEM" ]; then
                if [ ! -d "$TARGET_ITEM" ]; then
                    mkdir -p "$TARGET_ITEM"
                    log_debug "  [创建目录] $TARGET_ITEM"
                fi
            elif [ -f "$ITEM" ]; then
                local TARGET_DIR="${TARGET_ITEM%/*}"
                mkdir -p "$TARGET_DIR"
                cp -af "$ITEM" "$TARGET_ITEM"
                log_debug "  [覆盖文件] $TARGET_ITEM"
            fi
        done
    )

    if [ $? -eq 0 ]; then
        log_info "目录同步完成: $SRC_DIR"
        return 0
    else
        log_error "同步过程中发生错误！"
        return 1
    fi
}

# ==========================================
# 函数: get_kernel_version
# ==========================================
function get_kernel_version() {
    local target_branch="$1"
    local file_path="$2"

    awk -v branch="$target_branch" '
        $0 ~ "^[ \t]*" branch "\\)" { in_block = 1; next }
        in_block && /KERNEL_MAJOR_MINOR[ \t]*=/ {
            split($0, arr, "\"")
            print arr[2]
            exit
        }
        in_block && /;;/ { in_block = 0 }
    ' "$file_path"
}

# ==========================================
# 函数: get_latest_github_tag
# ==========================================
get_latest_github_tag() {
    local repo_url="$1"
    local prefix="$2"

    if [[ -z "$repo_url" || -z "$prefix" ]]; then
        return 1
    fi

    local latest_tag
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

# ==========================================
# 函数: get_kernel_org_latest
# ==========================================
get_kernel_org_latest() {
    local prefix="$1"
    local major_ver
    major_ver=$(echo "$prefix" | cut -d. -f1)
    local target_url="https://cdn.kernel.org/pub/linux/kernel/v${major_ver}.x/"

    local latest_version
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

# ==========================================
# 函数: upload_to_github_release
# 参数: $1 - Tag 名称 (例如: current-6.18.5)
#       $2 - 要上传的文件路径或通配符 (例如: output/debs/*current*.deb)
# ==========================================
function upload_to_github_release() {
    local tag_name="$1"
    local files_pattern="$2"

    if ! command -v gh &> /dev/null; then
        log_error "未安装 GitHub CLI (gh)。请检查环境依赖！"
        return 1
    fi

    log_info "检查是否有文件匹配: ${files_pattern}"
    # 检查通配符是否真的匹配到了文件 (防止报错)
    # shellcheck disable=SC2086
    ls -la ${files_pattern} >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_warn "未找到匹配的文件: ${files_pattern}，跳过上传。"
        return 1
    fi

    log_info "正在创建 GitHub Release 并上传产物: ${tag_name} ..."
    
    # 尝试创建 Release 并上传文件。如果 Tag 已存在，命令可能会失败
    # 如果你想覆盖已存在的 release，可以加上 --clobber 参数
    # shellcheck disable=SC2086
    gh release create "${tag_name}" ${files_pattern} \
        --title "Auto Build ${tag_name}" \
        --notes "Automated kernel build synced from kernel.org (Version: ${tag_name})"
        
    if [ $? -eq 0 ]; then
        log_info "✅ 成功发布并上传产物到: ${tag_name}"
    else
        log_error "❌ 上传 Release 失败！"
        log_error "排查建议: "
        log_error "1. 如果在本地运行，请确认是否执行过 'gh auth login'"
        log_error "2. 如果在 CI/CD 运行，请确保传递了 GITHUB_TOKEN 环境变量"
        log_error "3. 检查该 Tag 是否已经存在于远程仓库"
    fi
}

# ==========================================
# 主流程开始
# ==========================================
log_info "环境初始化中..."
sudo apt install git lsof curl wget jq yq -y >/dev/null 2>&1

ROCKCHIP64_CONFIG_FILE="./rockchip64_common.inc"
log_debug "正在下载 ${ROCKCHIP64_CONFIG_FILE}..."
wget -q -O ${ROCKCHIP64_CONFIG_FILE} https://raw.githubusercontent.com/armbian/build/refs/heads/main/config/sources/families/include/rockchip64_common.inc

# 1. 解析基础版本号
CONFIG_CURRENT_KERNEL_VER=$(get_kernel_version current ${ROCKCHIP64_CONFIG_FILE})
CONFIG_EDGE_KERNEL_VER=$(get_kernel_version edge ${ROCKCHIP64_CONFIG_FILE})
log_debug "提取到 current 分支基础版本: ${CONFIG_CURRENT_KERNEL_VER}"
log_debug "提取到 edge 分支基础版本: ${CONFIG_EDGE_KERNEL_VER}"

# 2. 获取当前 Git 仓库信息
CUR_GIT_REPO_URL=$(git remote get-url origin 2>/dev/null)
if [[ -z "$CUR_GIT_REPO_URL" ]]; then
    log_error "未能获取到当前 Git 的 remote url，请确保当前在 Git 目录中！"
    # 这里如果不是必须的，可给个默认值，或者 exit 1
    # exit 1
fi
log_debug "当前 Git Repo URL: ${CUR_GIT_REPO_URL}"

# 3. 获取 Github 最新发布版本
RELEASE_CURRENT_KERNEL_VER=$(get_latest_github_tag "${CUR_GIT_REPO_URL}" "current-${CONFIG_CURRENT_KERNEL_VER}")
RELEASE_CURRENT_KERNEL_VER2=$(echo "${RELEASE_CURRENT_KERNEL_VER}" | awk -F'-' '{print $2}')
log_debug "GitHub current 最新发布标签: ${RELEASE_CURRENT_KERNEL_VER} (解析出版本: ${RELEASE_CURRENT_KERNEL_VER2})"

RELEASE_EDGE_KERNEL_VER=$(get_latest_github_tag "${CUR_GIT_REPO_URL}" "edge-${CONFIG_EDGE_KERNEL_VER}")
RELEASE_EDGE_KERNEL_VER2=$(echo "${RELEASE_EDGE_KERNEL_VER}" | awk -F'-' '{print $2}')
log_debug "GitHub edge 最新发布标签: ${RELEASE_EDGE_KERNEL_VER} (解析出版本: ${RELEASE_EDGE_KERNEL_VER2})"

# 4. 获取 Kernel.org 最新官方版本 (注意：删除了多余的 ".")
KERNEL_ORG_CURRENT_VER=$(get_kernel_org_latest "${CONFIG_CURRENT_KERNEL_VER}")
KERNEL_ORG_EDGE_VER=$(get_kernel_org_latest "${CONFIG_EDGE_KERNEL_VER}")
log_debug "Kernel.org current 最新版本: ${KERNEL_ORG_CURRENT_VER}"
log_debug "Kernel.org edge 最新版本: ${KERNEL_ORG_EDGE_VER}"

# 5. 比较版本，决定是否更新 (修复了 Bash 的变量判断语法)
NEED_UPDATE_CURRENT_KERNEL=false
NEED_UPDATE_EDGE_KERNEL=false

if [[ "${RELEASE_CURRENT_KERNEL_VER2}" != "${KERNEL_ORG_CURRENT_VER}" && -n "${KERNEL_ORG_CURRENT_VER}" ]]; then
    NEED_UPDATE_CURRENT_KERNEL=true
fi

if [[ "${RELEASE_EDGE_KERNEL_VER2}" != "${KERNEL_ORG_EDGE_VER}" && -n "${KERNEL_ORG_EDGE_VER}" ]]; then
    NEED_UPDATE_EDGE_KERNEL=true
fi

log_info "状态汇总: NEED_UPDATE_CURRENT_KERNEL=${NEED_UPDATE_CURRENT_KERNEL}"
log_info "状态汇总: NEED_UPDATE_EDGE_KERNEL=${NEED_UPDATE_EDGE_KERNEL}"

# 如果两者都不需要更新，直接退出
if [[ "$NEED_UPDATE_CURRENT_KERNEL" == false && "$NEED_UPDATE_EDGE_KERNEL" == false ]]; then
    log_info "内核版本已是最新，无需触发构建更新。退出(0)。"
    exit 0
fi

# ==========================================
# 准备构建环境
# ==========================================
if [ -d "build" ]; then
    log_info "发现 'build' 目录，正在同步并更新..."
    sync_tree ./overwrite ./build
    sync_tree ./userpatches ./build/userpatches
    cd build || exit 1
    git pull
else
    log_info "未发现 'build' 目录，正在克隆并同步..."
    git clone https://github.com/armbian/build
    sync_tree ./overwrite ./build
    sync_tree ./userpatches ./build/userpatches
    cd build || exit 1
fi

chmod +x ./build_with_diy.sh

# ==========================================
# 执行构建
# ==========================================
if [[ "$NEED_UPDATE_CURRENT_KERNEL" == true ]]; then
    log_info "🚀 开始构建 current 分支内核..."
    ./build_with_diy.sh kernel BOARD=nanopi-r5s BRANCH=current RELEASE=trixie
    # ./build_with_diy.sh kernel BOARD=hinlink-h66k BRANCH=current RELEASE=trixie
fi

if [[ "$NEED_UPDATE_EDGE_KERNEL" == true ]]; then
    log_info "🚀 开始构建 edge 分支内核..."
    ./build_with_diy.sh kernel BOARD=nanopi-r5s BRANCH=edge RELEASE=trixie
    # ./build_with_diy.sh kernel BOARD=hinlink-h66k BRANCH=edge RELEASE=trixie
fi

log_info "检查产物输出目录:"
ls -la output/debs

# ==========================================
# 执行构建与上传流程
# ==========================================

# 1. 检查并安装 gh 依赖 (如果你没在前面装的话，这里补装)
if ! command -v gh &> /dev/null; then
    log_info "正在安装 GitHub CLI (gh)..."
    # 根据官方指引，较新的 Ubuntu 可以直接 apt 安装 gh
    sudo apt install gh -y >/dev/null 2>&1
fi

log_info "构建完毕，检查产物目录:"
ls -la output/debs/

# 2. 上传 current 分支产物
if [[ "$NEED_UPDATE_CURRENT_KERNEL" == true ]]; then
    # 拼接出动态 Tag，例如 current-6.18.5
    CURRENT_TAG="current-${KERNEL_ORG_CURRENT_VER}"
    log_info "🚀 准备上传 current 产物，Tag: ${CURRENT_TAG}"
    
    # 注意：这里根据 Armbian 产物的命名规律使用通配符 *current*.deb
    # 如果你的产物命名规则不同，请修改这里的通配符，例如换成 "*.deb"
    upload_to_github_release "$CURRENT_TAG" "output/debs/*current*.deb"
fi

# 3. 上传 edge 分支产物
if [[ "$NEED_UPDATE_EDGE_KERNEL" == true ]]; then
    # 拼接出动态 Tag，例如 edge-7.1.2
    EDGE_TAG="edge-${KERNEL_ORG_EDGE_VER}"
    log_info "🚀 准备上传 edge 产物，Tag: ${EDGE_TAG}"
    
    upload_to_github_release "$EDGE_TAG" "output/debs/*edge*.deb"
fi

log_info "🎉 所有自动化流程执行完毕！"