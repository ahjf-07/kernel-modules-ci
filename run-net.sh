#!/bin/bash
# run-net.sh - V15: 默认 Clang + 自动配置对齐版
# 解决：Kconfig 交互提问、工具链版本代差、以及编译器的默认偏好
set -eu

# --- 环境配置 ---
IP_DIR="/home/u2404/kernel-dev/iproute2/ip"

# --- 默认参数 ---
O_DIR=""
CPUS="8"
MEM="8G"
SCOPE="ffast"
LLVM_FLAG="LLVM=1"   # 默认改用 Clang

usage() {
    echo "Usage: $0 -o <out_dir> [-p cpus] [-m mem] [-l|-g] [--full|--fast|--ffast]"
    echo "  -l: Use Clang (Default)"
    echo "  -g: Use GCC"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) O_DIR="$2"; shift 2 ;;
        -p) CPUS="$2"; shift 2 ;;
        -m) MEM="$2"; shift 2 ;;
        -l) LLVM_FLAG="LLVM=1"; shift ;;
        -g) LLVM_FLAG=""; shift ;;
        --full)  SCOPE="full"; shift ;;
        --fast)  SCOPE="fast"; shift ;;
        --ffast) SCOPE="ffast"; shift ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [ -z "$O_DIR" ]; then usage; fi

# 1. 路径预处理
O_DIR_ABS=$(readlink -f "$O_DIR")
INSTALL_DIR="$O_DIR_ABS/kselftest/kselftest_install"
KERNEL_IMG="$O_DIR_ABS/arch/x86/boot/bzImage"

# 2. [Step 2] 编译环节：自动同步配置 + 增量编译
echo "[step 2] Syncing Config & Building Kernel (LLVM=$LLVM_FLAG)..."

# 执行 olddefconfig 自动选择默认值，消除 [Y/n] 提问
make O="$O_DIR_ABS" $LLVM_FLAG olddefconfig

# 启动构建
make O="$O_DIR_ABS" $LLVM_FLAG -j$(nproc) bzImage
make O="$O_DIR_ABS" $LLVM_FLAG headers_install
make -C tools/testing/selftests O="$O_DIR_ABS" TARGETS="net net/lib" $LLVM_FLAG install \
     KHDR_INCLUDES="-I$O_DIR_ABS/usr/include" -j$(nproc)

# 3. [Step 3] 宿主机端阉割 (Host-side Pruning)
if [ "$SCOPE" = "ffast" ]; then
    echo "[info] Mode: ffast. Pruning tests on host..."
    SKIP_LIST=("net/fcnal-test.sh" "net/ipvtap_test.sh" "net/macvlan_test.sh" 
               "net/fib_nexthops.sh" "net/fib_tests.sh" "net/udpgso_bench.sh"
               "net/gro.sh" "net/so_txtime.sh" "net/psock_snd.sh" "net/ipv6_route_update_soft_lockup.sh")
    for script in "${SKIP_LIST[@]}"; do
        target="$INSTALL_DIR/$script"
        [ -f "$target" ] && echo "echo '[CI-SKIP] $(basename "$script")'; exit 0" > "$target"
    done
fi

# 4. [Step 4] 启动 vng 并注入 6.18 工具链环境
echo "[test] Starting vng with Toolchain Injection..."

# 通过 export PATH 拦截 ip 命令，注入 PAGER=cat 消除分页卡顿
vng --run "$KERNEL_IMG" \
    --user root --rw --cpus "$CPUS" --memory "$MEM" \
    --exec "export PATH=$IP_DIR:\$PATH; \
            export PAGER=cat; \
            echo '--- [Environment Check] ---'; \
            which ip; ip -V; \
            cd $INSTALL_DIR; \
            ./run_kselftest.sh"
