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

# 4) 安装内核头文件（供 selftests 使用）
$MAKE_CMD headers_install

# 5) 安装 net selftests（必须包含 net/lib，否则缺 xdp_dummy.bpf.o）
mkdir -p "$O_DIR_ABS/kselftest/kselftest_install"
make -C tools/testing/selftests O="$O_DIR_ABS" TARGETS="net net/lib" $CC_FLAG install \
     KHDR_INCLUDES="-I$O_DIR_ABS/usr/include" -j"$CPUS" 2>&1 | tee -a "$O_DIR_ABS/../auto-net-selftests-install.log"

# 6) 硬验证：没装出来就直接报错退出
XDP_OBJ="$O_DIR_ABS/kselftest/kselftest_install/net/lib/xdp_dummy.bpf.o"
if [ ! -s "$XDP_OBJ" ]; then
  echo "ERROR: missing $XDP_OBJ" >&2
  echo "HINT: selftests install must include TARGETS=\"net net/lib\"" >&2
  find "$O_DIR_ABS/kselftest/kselftest_install/net" -maxdepth 3 -type f -name 'xdp_dummy*' -ls >&2 || true
  exit 2
fi

