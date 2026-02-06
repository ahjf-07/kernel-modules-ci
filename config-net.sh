#!/bin/bash
# [Refactored] config-net.sh
set -eu

O_DIR=""
MODE="m"
COMPILER="gcc" # 默认 GCC
LINUX_ROOT=$(pwd)

while getopts "o:mcigl" opt; do
    case "$opt" in
        o) O_DIR="$OPTARG" ;;
        m|c|i) MODE="$opt" ;;
        g) COMPILER="gcc" ;;
        l) COMPILER="clang" ;;
    esac
done

# --- 1. 环境检查 ---
if [ "$COMPILER" = "clang" ]; then
    # Clang 模式：严格检查版本
    if ! command -v clang >/dev/null 2>&1; then
        echo "ERROR: clang not found." >&2; exit 1
    fi
    C_VER=$(clang --version | grep -oP 'clang version \K[0-9]+')
    if [ "$C_VER" -lt 20 ]; then
        echo "ERROR: Clang version $C_VER < 20." >&2; exit 1
    fi
    # 检查 Pahole
    if ! command -v pahole >/dev/null 2>&1; then echo "ERROR: pahole missing"; exit 1; fi
    P_VER=$(pahole --version | head -n1 | sed -n 's/^v\([0-9]\+\)\.\([0-9]\+\).*$/\1\2/p')
    [ "${P_VER:-0}" -lt 131 ] && { echo "ERROR: pahole >= 1.31 required"; exit 1; }
fi

# --- 2. 模式处理 ---
[ "$MODE" = "i" ] && [ -f "$O_DIR/.config" ] && exit 0
[ "$MODE" = "m" ] && rm -rf "$O_DIR" && mkdir -p "$O_DIR"

# --- 3. 配置生成 ---
MAKE_OPTS="O=$O_DIR"
[ "$COMPILER" = "clang" ] && MAKE_OPTS="$MAKE_OPTS LLVM=1"

make $MAKE_OPTS defconfig

FRAG="./tools/testing/selftests/net/config"
[ -f "$FRAG" ] && KCONFIG_CONFIG="$O_DIR/.config" ./scripts/kconfig/merge_config.sh -m -r "$O_DIR/.config" "$FRAG" >/dev/null

cfg() { ./scripts/config --file "$O_DIR/.config" "$@"; }
cfg -e BPF_SYSCALL -e DEBUG_INFO_BTF -e NET_NS -e NAMESPACES -e IPV6 -e BRIDGE

cfg -e TLS -e TLS_DEVICE -e TLS_TOE
cfg -e CRYPTO_AES -e CRYPTO_AES_NI_INTEL -e CRYPTO_GCM -e CRYPTO_CCM -e CRYPTO_CHACHA20POLY1305
[ "$(uname -m)" = "aarch64" ] && cfg -e SERIAL_AMBA_PL011 -e SERIAL_AMBA_PL011_CONSOLE

make $MAKE_OPTS olddefconfig
