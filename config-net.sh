#!/bin/sh
set -eu

usage() {
  cat <<USAGE
usage: $0 [-l] [-r linux_root] [-o outdir]
  -l            use LLVM/clang output default (../out/full-clang)
  -r linux_root kernel source tree root (default: pwd)
  -o outdir     explicit build output dir (O=)
USAGE
  exit 1
}

LLVM=0
LINUX_ROOT=""
O=""

while getopts "lr:o:h" opt; do
  case "$opt" in
    l) LLVM=1 ;;
    r) LINUX_ROOT="$OPTARG" ;;
    o) O="$OPTARG" ;;
    h|*) usage ;;
  esac
done

[ -n "$LINUX_ROOT" ] || LINUX_ROOT=$(pwd)
HOST_LINUX_ROOT=$(realpath -e "$LINUX_ROOT")

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) KARCH=x86 ;;
  aarch64|arm64) KARCH=arm64 ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

if [ -z "$O" ]; then
  if [ "$LLVM" -eq 1 ]; then
    O="$HOST_LINUX_ROOT/../out/full-clang"
  else
    O="$HOST_LINUX_ROOT/../out/full-gcc"
  fi
fi

mkdir -p "$O"
cd "$HOST_LINUX_ROOT"

# --- 1. 基础配置初始化 ---
echo "[cfg] arch=$ARCH (KARCH=$KARCH)"
echo "[cfg] LINUX_ROOT=$HOST_LINUX_ROOT"
echo "[cfg] O=$O"

# [优化] 使用 defconfig 替代宿主机 config，极大缩短编译时间
make O="$O" defconfig

# scripts/config 必须存在
[ -x ./scripts/config ] || {
  echo "ERROR: scripts/config not found or not executable" >&2
  exit 1
}

cfg() { ./scripts/config --file "$O/.config" "$@"; }

# --- 2. 自动同步内核源码中的自测依赖 ---
sync_kselftest_configs() {
  local cfg_file="$1"
  [ -f "$cfg_file" ] || return 0
  echo "[cfg] Syncing requirements from $(basename "$cfg_file")..."
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      CONFIG_*)
        item=$(echo "$line" | cut -d'=' -f1 | sed 's/^CONFIG_//')
        val=$(echo "$line" | cut -d'=' -f2)
        if [ "$val" = "y" ] || [ "$val" = "m" ]; then
          cfg -e "$item"
        fi
        ;;
    esac
  done < "$cfg_file"
}

# 自动开启 net 自测所需的所有内核选项
sync_kselftest_configs "$HOST_LINUX_ROOT/tools/testing/selftests/net/config"

# --- 3. 核心功能增强 ---
echo "[cfg] Boosting IPv6 and Network features..."
cfg -e IPV6
cfg -e IPV6_MULTIPLE_TABLES
cfg -e IPV6_SUBTREES
cfg -e IPV6_MROUTE
cfg -e IPV6_SEG6_LWTUNNEL
cfg -e NET_L3_MASTER_DEV
cfg -e IP_ADVANCED_ROUTER
cfg -e IP_MULTIPLE_TABLES

# --- 4. 确保 virtme-ng 运行环境 ---
echo "[cfg] Ensuring virtme-ng boot essentials..."
cfg -e 9P_FS
cfg -e NET_9P
cfg -e NET_9P_VIRTIO
cfg -e VIRTIO_PCI
cfg -e VIRTIO_NET
cfg -e OVERLAY_FS
cfg -e DEVTMPFS
cfg -e DEVTMPFS_MOUNT
cfg -e TTY
cfg -e UNIX98_PTYS
case "$KARCH" in
  x86) cfg -e SERIAL_8250; cfg -e SERIAL_8250_CONSOLE ;;
  arm64) cfg -e SERIAL_AMBA_PL011; cfg -e SERIAL_AMBA_PL011_CONSOLE ;;
esac

# --- 5. 工具链处理 (LLVM/Pahole) ---
if [ "$LLVM" -eq 1 ]; then
  export LLVM=1
  export CC="/usr/bin/clang-20"
  export LD="/usr/bin/ld.lld-20"
  export NM="/usr/bin/llvm-nm-20"
  export AR="/usr/bin/llvm-ar-20"
  export OBJCOPY="/usr/bin/llvm-objcopy-20"
  cfg --disable LTO_CLANG_FULL
  cfg --disable LTO_CLANG_THIN
  cfg --enable  LTO_NONE
fi

# Pahole 检查
need_pahole=131
pahole_num() { pahole --version 2>/dev/null | head -n1 | sed -n 's/^v\([0-9]\+\)\.\([0-9]\+\).*$/\1\2/p'; }
p="$(command -v pahole 2>/dev/null || true)"
if [ -n "$p" ] && [ "$(pahole_num)" -ge "$need_pahole" ]; then
  echo "[cfg] pahole check passed" >&2
else
  echo "[warn] pahole missing or too old, BTF might fail" >&2
fi

make O="$O" olddefconfig
echo "[cfg] OK: wrote $O/.config"
