#!/bin/bash
# shellcheck disable=SC2016

# ==============================================================================
# 脚本名称: kernel_sync_build.sh
# 脚本描述: 自动化 Armbian 内核构建与发布工具。
#           支持从 kernel.org 获取最新版本，对比 GitHub 已发布版本，
#           自动触发构建并上传至 GitHub Release。
# ==============================================================================

# ==========================================
# 开启严格错误处理模式 (Bash Strict Mode)
# ==========================================
set -Eeuo pipefail # 任一命令、未定义变量或管道失败时立即中止

# ==========================================
# 日志输出系统 (带颜色高亮，方便调试)
# ==========================================
log_info()  { echo -e "\e[32m[INFO]\e[0m $1"; }
log_debug() { echo -e "\e[34m[DEBUG]\e[0m $1"; }
log_warn()  { echo -e "\e[33m[WARN]\e[0m $1"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $1" >&2; }

report_unhandled_error() {
	local exit_code="$1"
	local line_number="$2"
	local failed_command="$3"

	trap - ERR
	log_error "命令失败：exit=${exit_code}, line=${line_number}, command=${failed_command}"
	exit "${exit_code}"
}

resolve_repository_url() {
	local repository_root="${1:-${PWD}}"
	local repository_url

	if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
		printf '%s/%s.git\n' "${GITHUB_SERVER_URL%/}" "${GITHUB_REPOSITORY}"
		return 0
	fi

	repository_url="$(git -c safe.directory="${repository_root}" -C "${repository_root}" \
		remote get-url origin 2>/dev/null || true)"
	[[ -n "${repository_url}" ]] || return 1
	printf '%s\n' "${repository_url}"
}

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
    if (
        cd "$SRC_DIR" || exit 1
		# NUL 分隔，兼容空格、反斜杠和换行符文件名；避免管道子 Shell 吞错。
		while IFS= read -r -d '' ITEM; do

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
		done < <(find . -mindepth 1 -print0)
    ); then
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
        sed 's|.*refs/tags/||' | \
        sed 's/\^{}//' | \
        grep -E "^v?${prefix}" | \
        sort -Vu | \
		tail -n 1) || return 1

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
	latest_version=$(curl -fsSL "$target_url" | \
        grep -oE "linux-${prefix}(\.[0-9]+)?\.tar\.xz" | \
        sed 's/linux-//;s/\.tar\.xz//' | \
        sort -Vu | \
		tail -n 1) || return 1

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
	local branch="$2"
	local kernel_version="$3"
	local files_pattern="$4"
	local metadata_dir="./build/output/release-metadata/${branch}"
	local notes_file="${metadata_dir}/release-notes.md"
	local summary_file="${metadata_dir}/build-summary.md"
	local file
	local file_name
	local file_size
	local file_sha256

    # 环境校验: 是否安装了 gh 客户端
    if ! command -v gh &> /dev/null; then
        log_error "未安装 GitHub CLI (gh)。请检查环境依赖！"
        return 1
    fi

    log_info "检查是否有文件匹配: ${files_pattern}"
    
    # 使用 compgen 展开调用方传入的通配符；无匹配时保留空数组。
    local -a upload_files=()
    mapfile -t upload_files < <(compgen -G "${files_pattern}" || true)
	local -a metadata_files=()
	mapfile -d '' -t metadata_files < <(find "${metadata_dir}" -maxdepth 1 -type f \
		\( -name '*.config' -o -name '*config-vs-arm64-defconfig.txt' \) -print0 2>/dev/null)

    # 检查数组长度是否为 0
    if [ ${#upload_files[@]} -eq 0 ]; then
        log_warn "未找到匹配的文件: ${files_pattern}，跳过上传。"
        return 1
    fi
	if [[ ! -s "${summary_file}" || ${#metadata_files[@]} -eq 0 ]]; then
		log_error "缺少 ${branch} 的构建元数据，拒绝发布信息不完整的 Release。"
		return 1
	fi

	cp -- "${summary_file}" "${notes_file}"
	{
		printf '\n## 构建产物\n\n'
		printf '| 文件 | 大小 | SHA256 |\n|---|---:|---|\n'
		for file in "${upload_files[@]}"; do
			file_name="$(basename "${file}")"
			file_size="$(du -h "${file}" | awk '{print $1}')"
			file_sha256="$(sha256sum "${file}" | awk '{print $1}')"
			printf '| `%s` | %s | `%s` |\n' "${file_name}" "${file_size}" "${file_sha256}"
		done
		printf '\n## 构建来源\n\n'
		printf -- '- 发布标签：`%s`\n' "${tag_name}"
		printf -- '- Kernel.org 版本：`%s`\n' "${kernel_version}"
		printf -- '- 仓库提交：`%s`\n' \
			"${GITHUB_SHA:-$(git -c safe.directory="${PWD}" rev-parse HEAD)}"
		printf -- '- 构建时间：`%s`\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
	} >> "${notes_file}"

    log_info "正在创建 GitHub Release 并上传产物: ${tag_name} ..."
    
    # 使用 "${upload_files[@]}" 安全地将文件作为多个参数传递，不再有 SC2086 警告
	if gh release create "${tag_name}" "${upload_files[@]}" "${metadata_files[@]}" \
        --title "Auto Build ${tag_name}" \
        --notes-file "${notes_file}"; then
        log_info "✅ 成功发布并上传产物到: ${tag_name}"
	else
		log_error "❌ 上传 Release 失败！请检查网络、权限及 Tag 是否冲突。"
		return 1
	fi
	return 0
}

# Allow regression tests to load the functions without installing packages,
# cloning Armbian or contacting GitHub.
if [[ "${BUILD_SCRIPT_LIB_ONLY:-no}" == yes ]]; then
	# exit is the direct-execution fallback.
	# shellcheck disable=SC2317
	return 0 2>/dev/null || exit 0
fi

trap 'report_unhandled_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

# ==============================================================================
# 主逻辑流程开始
# ==============================================================================

log_info "1. 环境初始化中..."
# 默认安装必要的工具包
sudo apt-get update && sudo apt-get install -y git lsof curl wget jq yq >/dev/null 2>&1

# 下载 Armbian 的配置包含文件以解析内核版本
ROCKCHIP64_CONFIG_FILE="./rockchip64_common.inc"
log_debug "正在下载 ${ROCKCHIP64_CONFIG_FILE}..."
wget -q -O "${ROCKCHIP64_CONFIG_FILE}" https://raw.githubusercontent.com/armbian/build/refs/heads/main/config/sources/families/include/rockchip64_common.inc
if [[ ! -s "${ROCKCHIP64_CONFIG_FILE}" ]]; then
    log_error "下载 rockchip64_common.inc 失败或文件为空，请检查网络！"
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. 版本比对逻辑
# ------------------------------------------------------------------------------
# 获取配置文件中定义的分支大版本 (如 6.6)
CONFIG_CURRENT_KERNEL_VER=$(get_kernel_version current ${ROCKCHIP64_CONFIG_FILE})
CONFIG_EDGE_KERNEL_VER=$(get_kernel_version edge ${ROCKCHIP64_CONFIG_FILE})
CONFIG_BLEEDINGEDGE_KERNEL_VER=$(get_kernel_version bleedingedge ${ROCKCHIP64_CONFIG_FILE})
if [[ -z "${CONFIG_CURRENT_KERNEL_VER}" || -z "${CONFIG_EDGE_KERNEL_VER}" || -z "${CONFIG_BLEEDINGEDGE_KERNEL_VER}" ]]; then
	log_error "未能从 ${ROCKCHIP64_CONFIG_FILE} 解析全部内核分支版本"
	exit 1
fi
log_info "CONFIG_CURRENT_KERNEL_VER=${CONFIG_CURRENT_KERNEL_VER}"
log_info "CONFIG_EDGE_KERNEL_VER=${CONFIG_EDGE_KERNEL_VER}"
log_info "CONFIG_BLEEDINGEDGE_KERNEL_VER=${CONFIG_BLEEDINGEDGE_KERNEL_VER}"

# GitHub Actions 通过 sudo 运行时，checkout 目录属于 runner 用户，root
# 直接调用 git 会触发 dubious ownership。优先使用 Actions 自带变量；
# 本地运行则只为当前仓库调用显式声明 safe.directory。
if ! CUR_GIT_REPO_URL="$(resolve_repository_url "${PWD}")"; then
	log_error "未能确定当前 GitHub 仓库地址。请检查 GITHUB_REPOSITORY 或 origin remote。"
	exit 1
fi
log_debug "发布仓库：${CUR_GIT_REPO_URL}"

# 获取 GitHub 上已经发布的最新的 Tag 和 版本
# current
RELEASE_CURRENT_KERNEL_VER=$(get_latest_github_tag "${CUR_GIT_REPO_URL}" "current-${CONFIG_CURRENT_KERNEL_VER}" || true)
RELEASE_CURRENT_KERNEL_VER2=$(echo "${RELEASE_CURRENT_KERNEL_VER}" | awk -F'-' '{print $2}')
# edge
RELEASE_EDGE_KERNEL_VER=$(get_latest_github_tag "${CUR_GIT_REPO_URL}" "edge-${CONFIG_EDGE_KERNEL_VER}" || true)
RELEASE_EDGE_KERNEL_VER2=$(echo "${RELEASE_EDGE_KERNEL_VER}" | awk -F'-' '{print $2}')
# bleedingedge
RELEASE_BLEEDINGEDGE_KERNEL_VER=$(get_latest_github_tag "${CUR_GIT_REPO_URL}" "bleedingedge-${CONFIG_BLEEDINGEDGE_KERNEL_VER}" || true)
RELEASE_BLEEDINGEDGE_KERNEL_VER2=$(echo "${RELEASE_BLEEDINGEDGE_KERNEL_VER}" | awk -F'-' '{print $2}')


# 获取 Kernel.org 官方目前的最新小版本 (如 6.6.15)
KERNEL_ORG_CURRENT_VER=$(get_kernel_org_latest "${CONFIG_CURRENT_KERNEL_VER}")
KERNEL_ORG_EDGE_VER=$(get_kernel_org_latest "${CONFIG_EDGE_KERNEL_VER}")
KERNEL_ORG_BLEEDINGEDGE_VER=$(get_kernel_org_latest "${CONFIG_BLEEDINGEDGE_KERNEL_VER}")
log_info "KERNEL_ORG_CURRENT_VER=${KERNEL_ORG_CURRENT_VER}"
log_info "KERNEL_ORG_EDGE_VER=${KERNEL_ORG_EDGE_VER}"
log_info "KERNEL_ORG_BLEEDINGEDGE_VER=${KERNEL_ORG_BLEEDINGEDGE_VER}"

# 决定是否需要触发更新
NEED_UPDATE_CURRENT_KERNEL=false
NEED_UPDATE_EDGE_KERNEL=false
NEED_UPDATE_BLEEDINGEDGE_KERNEL=false

if [[ "${RELEASE_CURRENT_KERNEL_VER2}" != "${KERNEL_ORG_CURRENT_VER}" && -n "${KERNEL_ORG_CURRENT_VER}" ]]; then
    NEED_UPDATE_CURRENT_KERNEL=true
fi
if [[ "${RELEASE_EDGE_KERNEL_VER2}" != "${KERNEL_ORG_EDGE_VER}" && -n "${KERNEL_ORG_EDGE_VER}" ]]; then
    NEED_UPDATE_EDGE_KERNEL=true
fi
if [[ "${RELEASE_BLEEDINGEDGE_KERNEL_VER2}" != "${KERNEL_ORG_BLEEDINGEDGE_VER}" && -n "${KERNEL_ORG_BLEEDINGEDGE_VER}" ]]; then
    NEED_UPDATE_BLEEDINGEDGE_KERNEL=true
fi

# ------------------------------------------------------------------------------
# 执行构建与同步
# ------------------------------------------------------------------------------
if [[ "$NEED_UPDATE_CURRENT_KERNEL" == false && "$NEED_UPDATE_EDGE_KERNEL" == false && "$NEED_UPDATE_BLEEDINGEDGE_KERNEL" == false ]]; then
    log_info "内核版本已是最新，无需触发构建。退出。"
    exit 0
fi

# 准备 Armbian 构建环境
if [ -d "build" ]; then
    log_info "更新现有 build 目录..."
	git -C build checkout .
	git -C build clean -fd
	git -C build pull --ff-only
    sync_tree ./overwrite ./build
    sync_tree ./userpatches ./build/userpatches
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

if [[ "$NEED_UPDATE_BLEEDINGEDGE_KERNEL" == true ]]; then
    log_info "🚀 开始构建 bleedingedge 分支内核: ${KERNEL_ORG_BLEEDINGEDGE_VER}"
    ./build_with_diy.sh kernel BOARD=nanopi-r5s BRANCH=bleedingedge RELEASE=trixie
fi

# ------------------------------------------------------------------------------
# 发布产物
# ------------------------------------------------------------------------------
cd ..

if [[ "$NEED_UPDATE_CURRENT_KERNEL" == true ]]; then
    upload_to_github_release "current-${KERNEL_ORG_CURRENT_VER}" current \
		"${KERNEL_ORG_CURRENT_VER}" \
		"./build/output/debs/*-current-rockchip64_*__${KERNEL_ORG_CURRENT_VER}-*.deb"
fi

if [[ "$NEED_UPDATE_EDGE_KERNEL" == true ]]; then
    upload_to_github_release "edge-${KERNEL_ORG_EDGE_VER}" edge \
		"${KERNEL_ORG_EDGE_VER}" \
		"./build/output/debs/*-edge-rockchip64_*__${KERNEL_ORG_EDGE_VER}-*.deb"
fi

if [[ "$NEED_UPDATE_BLEEDINGEDGE_KERNEL" == true ]]; then
    upload_to_github_release "bleedingedge-${KERNEL_ORG_BLEEDINGEDGE_VER}" bleedingedge \
		"${KERNEL_ORG_BLEEDINGEDGE_VER}" \
		"./build/output/debs/*-bleedingedge-rockchip64_*__${KERNEL_ORG_BLEEDINGEDGE_VER}-*.deb"
fi

log_info "🎉 所有自动化流程已成功结束。"
