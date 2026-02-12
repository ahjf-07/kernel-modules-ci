#!/bin/bash
# config-net.sh - V19 (BTF & IKCONFIG 强力锁定版)
set -eu

O_DIR=""
LLVM_FLAG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) O_DIR="$2"; shift 2 ;;
        -l) LLVM_FLAG="LLVM=1"; shift ;;
        *) shift ;;
    esac
done

[ -z "$O_DIR" ] && exit 1
mkdir -p "$O_DIR"

# 1. 基础配置
make O="$O_DIR" $LLVM_FLAG x86_64_defconfig

# 2. 物理追加所有核心依赖 (不留死角)
cat <<EOF >> "$O_DIR/.config"
# --- 调试与自检 ---
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y

# --- BPF & VRF ---
CONFIG_CGROUP_BPF=y
CONFIG_SOCK_CGROUP_DATA=y
CONFIG_NET_VRF=y
CONFIG_NET_L3_MASTER_DEV=y

# --- 网络监控 ---
CONFIG_NETFILTER=y
CONFIG_NETFILTER_XT_MATCH_BPF=y
EOF

# 3. 运行官方 merge
if [ -f "tools/testing/selftests/net/config" ]; then
    ./scripts/kconfig/merge_config.sh -m -O "$O_DIR" "$O_DIR/.config" "tools/testing/selftests/net/config"
fi

# 4. 【关键步骤】在 merge 之后强力回补，防止被冲掉
scripts/config --file "$O_DIR/.config" \
    -e CONFIG_IKCONFIG \
    -e CONFIG_IKCONFIG_PROC \
    -e CONFIG_DEBUG_INFO \
    -e CONFIG_DEBUG_INFO_BTF \
    -e CONFIG_CGROUP_BPF

# 5. 刷新配置
make O="$O_DIR" $LLVM_FLAG olddefconfig
