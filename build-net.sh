#!/bin/bash
# [Refactored] build-net.sh
# Supports: -o <out_dir>, -l (Clang), -g (GCC), -s (Sparse)
set -eu

O_DIR=""
COMPILER="gcc"  # 默认 GCC
SPARSE=0
J_VAL=$(nproc)

while getopts "o:lgsj:h" opt; do
    case "$opt" in
        o) O_DIR="$OPTARG" ;;
        l) COMPILER="clang" ;;
        g) COMPILER="gcc" ;;
        s) SPARSE=1 ;;
        j) J_VAL="$OPTARG" ;;
        h) echo "Usage: $0 -o <dir> [-l|-g] [-s] [-j <nproc>]"; exit 0 ;;
        *) echo "Unknown option: $opt"; exit 1 ;;
    esac
done

[ -z "$O_DIR" ] && { echo "ERROR: -o <output_dir> is required"; exit 1; }

# --- 构建 Make 命令 ---
# 基础命令
CMD="make O=$O_DIR -j$J_VAL"

# 编译器适配
if [ "$COMPILER" = "clang" ]; then
    CMD="$CMD LLVM=1"
    # 如果环境里没有导出 LLVM_IAS，这里也可以保险起见加一个
    # CMD="$CMD LLVM_IAS=1"
fi

# Sparse 适配
if [ "$SPARSE" -eq 1 ]; then
    CMD="$CMD C=1"
fi

echo "[build] Executing: $CMD"
# 执行编译 (eval 用于解析变量中的空格)
eval "$CMD"
