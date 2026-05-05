#!/bin/bash

function sync_tree() {
    # 1. 检查参数数量
    if [ "$#" -ne 2 ]; then
        # ${FUNCNAME[0]} 会自动获取当前函数名
        echo "用法: ${FUNCNAME[0]} <源目录> <目标目录>"
        return 1
    fi

    # 2. 定义局部变量，去除路径末尾多余的斜杠
    local SRC_DIR="${1%/}"
    local DEST_DIR="${2%/}"

    if [ ! -d "$SRC_DIR" ]; then
        echo "错误: 源目录 '$SRC_DIR' 不存在！"
        return 1
    fi

    # 3. 核心修复：将目标目录转换为绝对路径
    # 防止 cd 进入源目录后，目标目录的相对路径失效
    local DEST_ABS
    case "$DEST_DIR" in
        /*) DEST_ABS="$DEST_DIR" ;;             # 如果已经是绝对路径，保持不变
        *)  DEST_ABS="$PWD/$DEST_DIR" ;;        # 如果是相对路径，拼接当前工作目录
    esac

    echo "开始精确映射同步..."
    echo "源: $SRC_DIR"
    echo "目标: $DEST_ABS"
    echo "-----------------------------------"

    # 4. 使用子 Shell ( ... ) 运行，避免 cd 改变外部终端的当前目录
    (
        cd "$SRC_DIR" || exit 1

        # 遍历源目录下的所有文件和文件夹
        find . | while read -r ITEM; do
            # 跳过当前目录本身 (.)
            if [ "$ITEM" == "." ]; then
                continue
            fi

            # 提取相对路径
            local REL_PATH="${ITEM#./}"
            # 拼接出绝对目标路径
            local TARGET_ITEM="$DEST_ABS/$REL_PATH"

            if [ -d "$ITEM" ]; then
                if [ ! -d "$TARGET_ITEM" ]; then
                    mkdir -p "$TARGET_ITEM"
                    echo "[创建目录] $ITEM => $TARGET_ITEM"
                fi
            elif [ -f "$ITEM" ]; then
                # 获取文件的父目录路径 (${VAR%/*} 相当于 dirname)
                local TARGET_DIR="${TARGET_ITEM%/*}"
                
                mkdir -p "$TARGET_DIR"
                cp -af "$ITEM" "$TARGET_ITEM"
                echo "[覆盖文件] $ITEM => $TARGET_ITEM"
            fi
        done
    )

    # 5. 检查子 Shell 的执行结果
    if [ $? -eq 0 ]; then
        echo "-----------------------------------"
        echo "✅ 全部层级映射覆盖完成！"
        return 0
    else
        echo "❌ 同步过程中发生错误！"
        return 1
    fi
}

sudo apt install git lsof curl wget jq yq -y

if [ -d "build" ]; then
    echo "Directory 'build' exists. Updating..."
    sync_tree ./overwrite ./build
    sync_tree ./userpatches ./build/userpatches
    cd build
	git pull
else
    echo "Directory 'build' not found. Cloning..."
    git clone https://github.com/armbian/build
    sync_tree ./overwrite ./build
    sync_tree ./userpatches ./build/userpatches
    cd build
fi

chmod +x ./build_with_diy.sh

# rockchip64
./build_with_diy.sh kernel BOARD=nanopi-r5s BRANCH=current RELEASE=trixie
#./build_with_diy.sh kernel BOARD=hinlink-h66k BRANCH=current RELEASE=trixie

ls -la output/debs