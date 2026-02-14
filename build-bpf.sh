#!/bin/bash
# build-bpf.sh (V4 - With Sparse Wrapper)
# 1. Detects and uses sparse-wrapper if available
# 2. Builds vmlinux, modules, bzImage, and selftests
set -eu
set -o pipefail

LLVM=1
SPARSE=0
SPARSE_SUBTREES=""
CLEAN=0
MRPROPER=0
INCREMENTAL=0
JOBS=$(nproc)
LINUX_ROOT=$(pwd)
O=""

while getopts "lsS:cmij:r:o:h" opt; do
  case "$opt" in
    l) LLVM=1 ;;
    s) SPARSE=1 ;;
    S) SPARSE_SUBTREES="$OPTARG" ;;
    c) CLEAN=1 ;;
    m) MRPROPER=1 ;;
    i) INCREMENTAL=1 ;;
    j) JOBS="$OPTARG" ;;
    r) LINUX_ROOT="$OPTARG" ;;
    o) O="$OPTARG" ;;
    h|*) echo "Usage: ..."; exit 1 ;;
  esac
done

O=$(realpath -m "${O:-../out/full-clang}")
mkdir -p "$O"

# --- 1. 环境配置 (集成 Wrapper) ---
MAKE_ARGS=""
if [ "$LLVM" -eq 1 ]; then
    export LLVM=1
    export CC="clang"
    export LD="ld.lld"
    export HOSTCC="clang"
    export HOSTCXX="clang++"
    MAKE_ARGS="LLVM=1 LLVM_IAS=1 CC=clang LD=ld.lld HOSTCC=clang HOSTCXX=clang++"
fi

# [关键修改] 挂载 sparse-wrapper
if [ "$SPARSE" -eq 1 ]; then
    # 自动查找同目录下的 sparse-wrapper
    WRAPPER="$(dirname "$(realpath "$0")")/sparse-wrapper"
    if [ -x "$WRAPPER" ]; then
        echo "[build] Using sparse wrapper: $WRAPPER"
        # 使用 wrapper 替代原生 sparse
        MAKE_ARGS="$MAKE_ARGS C=1 CHECK=$WRAPPER"
    else
        echo "[warn] sparse-wrapper not found, using raw sparse"
        MAKE_ARGS="$MAKE_ARGS C=1 CHECK=sparse"
    fi
fi

echo "[build] O=$O JOBS=$JOBS ARGS=$MAKE_ARGS"

# --- 2. 清理逻辑 ---
if [ "$MRPROPER" -eq 1 ]; then
    echo "[build] mrproper..."
    make -C "$LINUX_ROOT" O="$O" mrproper
elif [ "$CLEAN" -eq 1 ]; then
    echo "[build] clean..."
    make -C "$LINUX_ROOT" O="$O" clean
fi

if [ ! -f "$O/.config" ]; then
    echo "ERROR: $O/.config missing. Please run config-bpf.sh first." >&2
    exit 1
fi

# --- 3. 内核基础构建 ---
if [ "$INCREMENTAL" -eq 1 ]; then
    echo "[build] incremental: skipping olddefconfig"
else
    make -C "$LINUX_ROOT" O="$O" $MAKE_ARGS olddefconfig
fi

ARCH_TYPE=$(uname -m)
BOOT_TARGET=""
if [ "$ARCH_TYPE" = "x86_64" ]; then
    BOOT_TARGET="bzImage"
elif [ "$ARCH_TYPE" = "aarch64" ] || [ "$ARCH_TYPE" = "arm64" ]; then
    BOOT_TARGET="Image"
fi

echo "[build] kernel (vmlinux + $BOOT_TARGET) + modules..."
make -C "$LINUX_ROOT" O="$O" $MAKE_ARGS -j"$JOBS" vmlinux modules $BOOT_TARGET

echo "[build] headers_install..."
make -C "$LINUX_ROOT" O="$O" headers_install INSTALL_HDR_PATH="$O/usr"

# --- 4. BPF 工具链预构建 ---
OUT_BPF="$LINUX_ROOT/.kselftest-out/selftests-bpf"
mkdir -p "$OUT_BPF"
KHDR="-isystem $O/usr/include"

echo "[build] tools: libbpf headers..."
mkdir -p "$OUT_BPF/tools/build/libbpf"
make -C "$LINUX_ROOT/tools/lib/bpf" OUTPUT="$OUT_BPF/tools/build/libbpf/" DESTDIR="$OUT_BPF" prefix="/usr" $MAKE_ARGS -j"$JOBS" install_headers

echo "[build] tools: resolve_btfids..."
mkdir -p "$OUT_BPF/tools/build/resolve_btfids"
make -C "$LINUX_ROOT/tools/bpf/resolve_btfids" OUTPUT="$OUT_BPF/tools/build/resolve_btfids/" DESTDIR="$OUT_BPF" prefix="/usr" $MAKE_ARGS -j"$JOBS"

# --- 5. 编译 Selftests ---
echo "[build] selftests/bpf..."
RESOLVE_BTFIDS_BIN="$OUT_BPF/tools/build/resolve_btfids/resolve_btfids"
make -C "$LINUX_ROOT/tools/testing/selftests/bpf" O="$O" OUTPUT="$OUT_BPF" KHDR_INCLUDES="$KHDR" VMLINUX_BTF="$O/vmlinux" RESOLVE_BTFIDS="$RESOLVE_BTFIDS_BIN" $MAKE_ARGS -j"$JOBS"

# --- 6. Sparse Subtrees ---
if [ "$SPARSE" -eq 1 ] && [ -n "$SPARSE_SUBTREES" ]; then
    echo "[sparse] Checking subtrees: $SPARSE_SUBTREES"
    for d in $SPARSE_SUBTREES; do
        make -C "$LINUX_ROOT" O="$O" $MAKE_ARGS M="$d" modules
    done
fi
echo "[build] Done."
