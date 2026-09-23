#!/bin/bash
# shellcheck disable=SC2016

# ==============================================================================
# 脚本名称: build.sh
# 脚本描述: 自动化 Armbian 内核构建与发布工具。
#           支持从 kernel.org 获取最新版本，对比 GitHub 已发布版本，
#           自动触发构建并上传至 GitHub Release。
# ==============================================================================

# ==========================================
# 开启严格错误处理模式 (Bash Strict Mode)
# ==========================================
set -Eeuo pipefail # 任一命令、未定义变量或管道失败时立即中止

# ==========================================
# 日志输出系统 (带 UTC 时间戳与颜色高亮)
# info 走 stdout（进度信息）；debug/warn/error 一律走 stderr，避免被 $( )
# 捕获、污染函数返回值。
# ==========================================
log_now() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

log_info()  { printf '\e[32m[INFO]\e[0m \e[2m%s\e[0m %s\n' "$(log_now)" "$1"; }
log_debug() { printf '\e[34m[DEBUG]\e[0m \e[2m%s\e[0m %s\n' "$(log_now)" "$1" >&2; }
log_warn()  { printf '\e[33m[WARN]\e[0m \e[2m%s\e[0m %s\n' "$(log_now)" "$1" >&2; }
log_error() { printf '\e[31m[ERROR]\e[0m \e[2m%s\e[0m %s\n' "$(log_now)" "$1" >&2; }

# 阶段计时: begin_step / end_step 成对使用，结束时输出耗时。
STEP_START=0
begin_step() {
	STEP_START=$SECONDS
	log_info "──── $1 ────"
}
end_step() {
	log_info "──── $1 完成 (耗时 $((SECONDS - STEP_START))s) ────"
}

report_unhandled_error() {
	local exit_code="$1"
	local line_number="$2"
	local failed_command="$3"

	trap - ERR
	log_error "命令失败：exit=${exit_code}, line=${line_number}, command=${failed_command}"
	log_error "失败时的工作目录：${PWD}"
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
# 函数: ensure_host_dependencies
# 描述: 检查必需的宿主工具，缺失时尝试通过 apt 安装；安装失败仅告警不终止，
#       让后续步骤以明确的报错暴露真正缺什么。不再安装未使用的 lsof/yq。
# ==============================================================================
ensure_host_dependencies() {
	local required=(git curl wget jq)
	local -a missing=()
	local tool

	for tool in "${required[@]}"; do
		if ! command -v "${tool}" > /dev/null 2>&1; then
			missing+=("${tool}")
		fi
	done

	if ((${#missing[@]} == 0)); then
		log_debug "宿主依赖齐全: ${required[*]}"
		return 0
	fi

	log_info "安装缺失的宿主依赖: ${missing[*]}"
	if sudo apt-get update -qq && sudo apt-get install -y -qq "${missing[@]}"; then
		log_info "宿主依赖安装完成"
	else
		log_warn "apt 安装失败 (${missing[*]})；继续执行，后续步骤若失败请手动安装"
	fi
}

# ==============================================================================
# 函数: sync_tree
# 描述: 递归同步两个目录的内容 (只增改不删——目标端多出来的文件保持原样，
#       因为 ./overwrite 会被同步进 Armbian 仓库根目录，删除会破坏上游文件)。
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

    local copied_count=0
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
        copied_count="$(find "$SRC_DIR" -type f | wc -l | tr -d ' ')"
        log_info "目录同步完成: $SRC_DIR (${copied_count} 个文件)"
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

    # 前缀中的点必须转义；后随 \. 或行尾锚定，避免 current-6.1 误吞 current-6.12.x。
    local escaped_prefix="${prefix//./\\.}"
    local latest_tag
    # 流程: 获取所有 tags -> 过滤掉 ^/ref/tags/ -> 移除 ^^{} 标记 ->
    #       匹配前缀 -> 版本排序 -> 取最后一个
	latest_tag=$(git ls-remote --tags "$repo_url" 2>/dev/null | \
        sed 's|.*refs/tags/||' | \
        sed 's/\^{}//' | \
        grep -E "^${escaped_prefix}(\.|$)" | \
        sort -Vu | \
		tail -n 1) || return 1

    if [[ -z "$latest_tag" ]]; then
        return 1
    fi
    echo "$latest_tag"
}

# ==============================================================================
# 函数: needs_update
# 描述: 判断某个分支是否需要重新构建。使用 sort -V 做版本序比较而非字符串
#       相等比较：已发布版本比上游新时不再触发重建，避免无限循环。
# 参数:
#   $1 - released: 仓库中已发布的最新版本号 (可为空，表示从未发布)
#   $2 - upstream: kernel.org 当前最新版本号 (为空表示分支尚未发布，不构建)
# 返回: 0 - 需要构建; 1 - 不需要
# ==============================================================================
needs_update() {
	local released="$1"
	local upstream="$2"

	if [[ -z "${upstream}" ]]; then
		return 1
	fi
	if [[ -z "${released}" ]]; then
		return 0
	fi
	if [[ "${released}" == "${upstream}" ]]; then
		return 1
	fi
	[[ "$(printf '%s\n%s\n' "${released}" "${upstream}" | sort -V | tail -n 1)" == "${upstream}" ]]
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
    local index_html
    local latest_version

	[[ "${prefix}" =~ ^[0-9]+\.[0-9]+$ ]] || return 2
    major_ver="${prefix%%.*}"
    local target_url="https://cdn.kernel.org/pub/linux/kernel/v${major_ver}.x/"

	# 网络错误与“该版本尚未发布”必须区分：前者应终止流水线，
	# 后者是 bleedingedge 提前指向下一开发版本时的正常状态。
	index_html="$(curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 \
		"${target_url}")" || return 1
	latest_version="$(printf '%s\n' "${index_html}" | parse_kernel_org_index "${prefix}" || true)"

	[[ -n "${latest_version}" ]] || return 2
    echo "$latest_version"
}

parse_kernel_org_index() {
	local prefix="$1"
	local escaped_prefix="${prefix//./\\.}"

	grep -oE "linux-${escaped_prefix}(\.[0-9]+)?\.tar\.xz" | \
		sed 's/linux-//;s/\.tar\.xz//' | \
		sort -Vu | \
		tail -n 1
}

load_kernel_org_version() {
	local branch="$1"
	local configured_version="$2"
	local latest_version
	local status

	if latest_version="$(get_kernel_org_latest "${configured_version}")"; then
		printf '%s\n' "${latest_version}"
		return 0
	else
		status=$?
	fi

	if ((status == 2)); then
		log_warn "kernel.org 尚未发布 ${configured_version}.x；跳过 ${branch} 分支。"
		return 0
	fi

	log_error "查询 kernel.org 的 ${configured_version}.x 版本失败；这不是未发布状态。"
	return 1
}

# ==============================================================================
# 函数: resolve_built_version
# 描述: 构建结束后，从 output/debs 中最新的 linux-image deb 文件名反解出实际
#       构建的内核版本。构建耗时数小时，期间 kernel.org 可能已升版，因此
#       不能用构建前抓取的版本号去匹配产物。
# 参数:
#   $1 - branch: Armbian 分支名 (如 'current')
# 返回: 通过 stdout 输出版本号 (如 '6.18.8')
# ==============================================================================
resolve_built_version() {
	local branch="$1"
	local debs_dir="./build/output/debs"
	local newest_deb
	local built_version

	newest_deb="$(find "${debs_dir}" -name "linux-image-${branch}-rockchip64_*.deb" \
		-printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)"
	if [[ -z "${newest_deb}" ]]; then
		log_error "未找到 linux-image-${branch}-rockchip64_*.deb 构建产物。"
		return 1
	fi
	log_debug "${branch}: 最新产物 $(basename "${newest_deb}")"

	built_version="$(basename "${newest_deb}" | \
		sed -n 's/^.*__\([0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)\?\)-.*$/\1/p')"
	if [[ -z "${built_version}" ]]; then
		log_error "无法从 $(basename "${newest_deb}") 反解内核版本 (缺少 __<版本>- 段)。"
		return 1
	fi
	printf '%s\n' "${built_version}"
}

# ==============================================================================
# 函数: upload_to_github_release
# 描述: 使用 GitHub CLI (gh) 创建 Release 并上传构建生成的 .deb 文件。
# 参数:
#   $1 - tag_name:         发布使用的 Tag 名称 (如: current-6.12.1)
#   $2 - branch:           Armbian 分支名 (用于定位构建元数据)
#   $3 - kernel_version:   实际构建出的内核版本 (从产物反解)
#   $4 - upstream_version: kernel.org 构建前的上游版本 (记录用)
#   $5 - files_pattern:    文件通配符路径 (如: output/*.deb)
# 返回: 0 - 成功; 1 - 失败
# ==============================================================================
function upload_to_github_release() {
    local tag_name="$1"
	local branch="$2"
	local kernel_version="$3"
	local upstream_version="$4"
	local files_pattern="$5"
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
        log_error "未找到匹配的构建产物: ${files_pattern}，拒绝发布空 Release。"
        return 1
    fi
	if [[ ! -s "${summary_file}" || ${#metadata_files[@]} -eq 0 ]]; then
		log_error "缺少 ${branch} 的构建元数据，拒绝发布信息不完整的 Release。"
		return 1
	fi

	log_info "待上传产物 ${#upload_files[@]} 个，元数据文件 ${#metadata_files[@]} 个："
	for file in "${upload_files[@]}"; do
		log_debug "  产物: $(basename "${file}") ($(du -h "${file}" | awk '{print $1}'))"
	done
	for file in "${metadata_files[@]}"; do
		log_debug "  元数据: $(basename "${file}")"
	done

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
		printf -- '- 内核版本（构建产物）：`%s`\n' "${kernel_version}"
		printf -- '- kernel.org 上游版本：`%s`\n' "${upstream_version}"
		printf -- '- 仓库提交：`%s`\n' \
			"${GITHUB_SHA:-$(git -c safe.directory="${PWD}" rev-parse HEAD)}"
		printf -- '- 构建时间：`%s`\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
	} >> "${notes_file}"

    log_info "正在创建 GitHub Release 并上传产物: ${tag_name} ..."

    # 使用 "${upload_files[@]}" 安全地将文件作为多个参数传递，不再有 SC2086 警告
	if gh release create "${tag_name}" "${upload_files[@]}" "${metadata_files[@]}" \
        --title "Auto Build ${tag_name}" \
        --notes-file "${notes_file}"; then
        log_info "成功发布并上传产物到: ${tag_name}"
	else
		if gh release view "${tag_name}" &> /dev/null; then
			log_error "Release ${tag_name} 已存在；请检查是否重复构建或手动清理该标签。"
		else
			log_error "上传 Release 失败！请检查网络、权限及 Tag 是否冲突。"
		fi
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

begin_step "1. 环境初始化"
ensure_host_dependencies

# 下载 Armbian 的配置包含文件以解析内核版本
ROCKCHIP64_CONFIG_FILE="./rockchip64_common.inc"
log_debug "正在下载 ${ROCKCHIP64_CONFIG_FILE}..."
wget -q -O "${ROCKCHIP64_CONFIG_FILE}" https://raw.githubusercontent.com/armbian/build/refs/heads/main/config/sources/families/include/rockchip64_common.inc
if [[ ! -s "${ROCKCHIP64_CONFIG_FILE}" ]]; then
    log_error "下载 rockchip64_common.inc 失败或文件为空，请检查网络！"
    exit 1
fi
log_info "rockchip64_common.inc 下载完成 ($(wc -l < "${ROCKCHIP64_CONFIG_FILE}" | tr -d ' ') 行)"
end_step "1. 环境初始化"

# GitHub Actions 通过 sudo 运行时，checkout 目录属于 runner 用户，root
# 直接调用 git 会触发 dubious ownership。优先使用 Actions 自带变量；
# 本地运行则只为当前仓库调用显式声明 safe.directory。
if ! CUR_GIT_REPO_URL="$(resolve_repository_url "${PWD}")"; then
	log_error "未能确定当前 GitHub 仓库地址。请检查 GITHUB_REPOSITORY 或 origin remote。"
	exit 1
fi
log_info "发布仓库：${CUR_GIT_REPO_URL}"

# ------------------------------------------------------------------------------
# 2. 版本比对逻辑：逐分支解析上游版本、查询已发布 Tag、决定是否构建
# ------------------------------------------------------------------------------
begin_step "2. 版本比对"
branch_list=(current edge bleedingedge)
declare -A BRANCH_UPSTREAM_VER=()
declare -A NEED_BUILD=()

for branch in "${branch_list[@]}"; do
	CONFIG_KERNEL_VER="$(get_kernel_version "${branch}" "${ROCKCHIP64_CONFIG_FILE}" || true)"
	if [[ -z "${CONFIG_KERNEL_VER}" ]]; then
		# 上游移除某个分支时降级为跳过，而不是让整条流水线失败。
		log_warn "${branch}: Armbian 配置中没有该分支的 KERNEL_MAJOR_MINOR，跳过此分支"
		continue
	fi
	log_info "${branch}: Armbian 配置大版本 = ${CONFIG_KERNEL_VER}"

	KERNEL_ORG_VER="$(load_kernel_org_version "${branch}" "${CONFIG_KERNEL_VER}")" || exit 1
	if [[ -z "${KERNEL_ORG_VER}" ]]; then
		continue
	fi

	RELEASED_TAG="$(get_latest_github_tag "${CUR_GIT_REPO_URL}" "${branch}-${CONFIG_KERNEL_VER}" || true)"
	RELEASED_VER="${RELEASED_TAG#"${branch}-"}"

	if needs_update "${RELEASED_VER}" "${KERNEL_ORG_VER}"; then
		NEED_BUILD["${branch}"]=yes
		BRANCH_UPSTREAM_VER["${branch}"]="${KERNEL_ORG_VER}"
		if [[ -z "${RELEASED_TAG}" ]]; then
			log_info "${branch}: 尚无已发布版本，上游最新 ${KERNEL_ORG_VER} → 计划构建"
		else
			log_info "${branch}: 已发布 ${RELEASED_TAG} < 上游 ${KERNEL_ORG_VER} → 计划构建"
		fi
	else
		log_info "${branch}: 已发布 ${RELEASED_TAG} >= 上游 ${KERNEL_ORG_VER} → 无需构建"
	fi
done
end_step "2. 版本比对"

# ------------------------------------------------------------------------------
# 执行构建与发布：逐分支"构建 → 反解实际版本 → 上传"，某个分支失败时
# 已完成的分支产物不会丢失。
# ------------------------------------------------------------------------------
planned_branches=()
for branch in "${branch_list[@]}"; do
	if [[ "${NEED_BUILD[${branch}]:-}" == yes ]]; then
		planned_branches+=("${branch}")
	fi
done

if ((${#planned_branches[@]} == 0)); then
    log_info "所有分支内核版本已是最新，无需触发构建。退出。"
    exit 0
fi
log_info "计划构建分支: ${planned_branches[*]}"

# 准备 Armbian 构建环境
begin_step "3. 准备 Armbian 构建环境"
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
end_step "3. 准备 Armbian 构建环境"

for branch in "${planned_branches[@]}"; do
	begin_step "4. 构建 ${branch} 分支内核 (目标 ${BRANCH_UPSTREAM_VER[${branch}]})"
	./build_with_diy.sh kernel BOARD=nanopi-r5s BRANCH="${branch}" RELEASE=trixie

	BUILT_KERNEL_VER="$(resolve_built_version "${branch}")" || exit 1
	log_info "${branch}: 从构建产物反解实际内核版本 = ${BUILT_KERNEL_VER}"
	end_step "4. 构建 ${branch} 分支内核"

	begin_step "5. 发布 ${branch}-${BUILT_KERNEL_VER}"
	upload_to_github_release "${branch}-${BUILT_KERNEL_VER}" "${branch}" \
		"${BUILT_KERNEL_VER}" "${BRANCH_UPSTREAM_VER[${branch}]}" \
		"./build/output/debs/*-${branch}-rockchip64_*__${BUILT_KERNEL_VER}-*.deb"
	end_step "5. 发布 ${branch}-${BUILT_KERNEL_VER}"
done

log_info "所有自动化流程已成功结束。"
