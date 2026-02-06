#!/bin/bash
# [Final v2] scan-net.sh - Enhanced Sparse Detection
set -eu

TOP_N=30
LOG=""
while getopts "t:h" opt; do
    case "$opt" in t) TOP_N="$OPTARG" ;; esac
done
shift $((OPTIND - 1))
LOG="$1"

[ -f "$LOG" ] || { echo "Error: Log $LOG not found"; exit 1; }

normalize() {
    sed -E 's/^[[:space:]]*//; s/^[0-9]+://; s/[0-9]{4}-[0-9]{2}-[0-9]{2}//g' | sort -u
}

echo " == build + sparse summary (separated) =="

# 1.【噪音黑名单】 -> 彻底剔除
# - embedded NUL byte: Clang/Sparse 对宏的误报
# - bad integer constant: Sparse 宏解析能力不足
NOISE_PAT="bad integer constant expression|static assertion failed|embedded NUL byte|__attribute__|marked inline, but without a definition"

# 2.【Sparse 特征库 (大幅扩充)】 -> 归类为 Sparse
# 这些看起来像 Error，其实是 Sparse 的静态检查
# - Share your drugs: Sparse 经典彩蛋
# - token expansion / too many errors: Sparse 预处理限制
# - address spaces / noderef: Sparse __user/__kernel 检查
# - incompatible types: Sparse 类型检查
# - cast to restricted: Sparse 端序检查 (__le32 等)
SPARSE_PAT="sparse:|Should it be static\?|was not declared|context imbalance|different address spaces|cast removes address space|cast to restricted|too long token expansion|too many errors|multiple address spaces|arithmetics on pointers|subtraction of functions|Share your drugs|incompatible types|no generic selection|redeclared with different type|symbol .* redeclared"

# --- 执行分拣 ---

# [Sparse]
list_sparse="$(dirname "$LOG")/list.sparse.txt"
(grep -E "$SPARSE_PAT" "$LOG" | grep -vE "$NOISE_PAT" || true) | normalize > "$list_sparse"

# [Build Error] (真正的编译器错误)
# 排除 Sparse 特征，排除 噪音
list_error="$(dirname "$LOG")/list.error.txt"
(grep "error:" "$LOG" | grep -vE "$SPARSE_PAT" | grep -vE "$NOISE_PAT" || true) | normalize > "$list_error"

# [Build Warning] (真正的编译器警告)
# 排除 error, 排除 Sparse, 排除 噪音
list_warning="$(dirname "$LOG")/list.warning.txt"
(grep "warning:" "$LOG" | grep -v "error:" | grep -vE "$SPARSE_PAT" | grep -vE "$NOISE_PAT" || true) | normalize > "$list_warning"

# --- 输出摘要 ---
print_summary() {
    local type="$1"
    local file="$2"
    local count=$(wc -l < "$file")
    local show=$(( count < TOP_N ? count : TOP_N ))
    
    echo -e "\n==== $type summary (Top $show of $count) ===="
    if [ "$count" -gt 0 ]; then
        head -n "$TOP_N" "$file"
    else
        echo "  (None)"
    fi
}

print_summary "error"   "$list_error"
print_summary "warning" "$list_warning"
print_summary "sparse"  "$list_sparse"
