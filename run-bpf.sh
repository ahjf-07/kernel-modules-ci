#!/bin/bash
# run-bpf.sh (V7 - Smart Loader)
# 1. Escapes guest variables to prevent host shell expansion
# 2. Excludes specific modules from auto-loading to prevent test conflicts (EEXIST)
set -eu

# 默认参数
CPUS=8
MEM=8G
FAST_COUNT=0
MODE="full"
LINUX_ROOT=$(pwd)
O=""

# 参数解析
while getopts "f:p:m:r:o:l" opt; do
  case "$opt" in
    f) MODE="fast"; FAST_COUNT="$OPTARG" ;;
    --ff) MODE="faster" ;; 
    p) CPUS="$OPTARG" ;;
    m) MEM="$OPTARG" ;;
    r) LINUX_ROOT="$OPTARG" ;;
    o) O="$OPTARG" ;;
    l) ;; # 兼容参数
  esac
done

if [ "$MODE" = "faster" ]; then
    MODE="fast"
    FAST_COUNT=10
fi

O=$(realpath -m "${O:-../out/full-clang}")

# 1. 镜像路径判定
if [ -f "$O/arch/x86/boot/bzImage" ]; then
    IMG="$O/arch/x86/boot/bzImage"
elif [ -f "$O/arch/arm64/boot/Image" ]; then
    IMG="$O/arch/arm64/boot/Image"
else
    echo "Error: Kernel image not found in $O"
    exit 1
fi

# 2. 生成 Guest 脚本
GUEST=".kselftest-out/guest-bpf.sh"
mkdir -p "$(dirname "$GUEST")"

# 注意：使用 EOF，Guest 内部变量必须转义 (如 \$mod, \$TARGET_DIR)
cat <<EOF > "$GUEST"
#!/bin/sh
set +e

echo "[guest] Preparing environment..."
mountpoint -q /proc || mount -t proc proc /proc
mountpoint -q /sys || mount -t sysfs sysfs /sys
mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug
mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf

ulimit -n 65536

# === 路径修正 ===
TARGET_DIR=".kselftest-out/selftests-bpf"
if [ -d "\$TARGET_DIR" ]; then
    cd "\$TARGET_DIR"
else
    echo "[guest] Error: Cannot find \$TARGET_DIR"
    exit 1
fi

echo "[guest] Loading helper modules..."

# 1. 核心测试模块 (必须预加载)
if [ -f "bpf_testmod.ko" ]; then
    insmod bpf_testmod.ko 2>/dev/null || echo "[guest] Warn: Failed to load bpf_testmod.ko"
else
    echo "[guest] Warn: bpf_testmod.ko not found in \$(pwd)"
fi

# 2. 其他模块 (排除掉那些测试用例需要自己加载的模块)
for mod in *.ko; do
    # 跳过 bpf_testmod (已处理)
    [ "\$mod" = "bpf_testmod.ko" ] && continue
    
    # [关键修复] 跳过这些模块，防止 EEXIST 错误 (测试程序会自己加载它们)
    [ "\$mod" = "bpf_test_modorder_x.ko" ] && continue
    [ "\$mod" = "bpf_test_modorder_y.ko" ] && continue
    [ "\$mod" = "bpf_test_no_cfi.ko" ] && continue
    
    [ -e "\$mod" ] || continue
    insmod "\$mod" 2>/dev/null && echo "[guest] Loaded \$mod"
done

if [ ! -x "./test_progs" ]; then
    echo "[guest] Error: ./test_progs not found!"
    exit 1
fi

# === 定义辅助函数 ===
pick_tests() {
  n=\$1
  if ./test_progs --list >/dev/null 2>&1; then
    ./test_progs --list 2>/dev/null | awk 'NF{print \$1}' | head -n "\$n"
    return
  fi
  echo ""
}

echo "=== Running BPF Selftests ($MODE) ==="

if [ "$MODE" = "fast" ]; then
    echo "[guest] Fast mode: running first $FAST_COUNT tests..."
    tests=\$(pick_tests "$FAST_COUNT")
    if [ -n "\$tests" ]; then
        for t in \$tests; do ./test_progs -t "\$t"; done
    else
        ./test_progs -n $FAST_COUNT 2>/dev/null || ./test_progs
    fi
else
    # Full mode
    # 跳过已知死锁/不稳定的测试
    ./test_progs -b select_reuseport,send_signal,send_signal_sched_switch
fi

echo "=== Done ==="
EOF

chmod +x "$GUEST"

# 3. 启动 VNG
echo "[run] Starting VM ($IMG)..."
vng --run "$IMG" \
    --user root \
    --cpus "$CPUS" \
    --memory "$MEM" \
    --cwd "$LINUX_ROOT" \
    --rw \
    --append "lsm=lockdown,capability,landlock,yama,apparmor,bpf" \
    --exec "sh $GUEST"
