#!/bin/bash
# build-net.sh - 最终修正版：确保 sparse-wrapper 绝对路径调用正确
set -e

O_DIR=""
CC_FLAG="" 
SPARSE=0
CPUS=$(nproc)

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) O_DIR="$2"; shift 2 ;;
        -l) CC_FLAG="LLVM=1"; shift ;;
        -g) CC_FLAG=""; shift ;;
        -s) SPARSE=1; shift ;;
        -j*) CPUS="${1#-j}"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$O_DIR" ]; then 
    echo "Usage: $0 -o <out_dir> [-l|-g] [-s] [-jN]"
    exit 1
fi

# 1. 输出目录转绝对路径
O_DIR_ABS=$(readlink -f "$O_DIR")

# 2. 【修改点】获取 sj-ktools 的绝对路径
# 不管你在哪运行，都能找到同目录下的 sparse-wrapper
TOOL_DIR=$(dirname "$(readlink -f "$0")")
WRAPPER="$TOOL_DIR/sparse-wrapper"

echo "[build] Output Dir: $O_DIR_ABS"

# 构造基础命令
MAKE_CMD="make O=$O_DIR_ABS -j$CPUS $CC_FLAG"

# 3. 启用 Sparse (使用绝对路径 wrapper)
if [ "$SPARSE" -eq 1 ]; then
    if [ -x "$WRAPPER" ]; then
        echo "[build] Sparse enabled using wrapper: $WRAPPER"
        # 核心：CHECK 必须是绝对路径
        MAKE_CMD="$MAKE_CMD C=1 CHECK=$WRAPPER"
    else
        echo "[WARN] Wrapper not found or not executable at: $WRAPPER"
        echo "[WARN] Falling back to default 'sparse' command."
        MAKE_CMD="$MAKE_CMD C=1 CHECK=sparse"
    fi
fi

echo "[build] Executing: $MAKE_CMD"
$MAKE_CMD bzImage
$MAKE_CMD modules
