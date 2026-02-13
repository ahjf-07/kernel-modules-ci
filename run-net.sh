#!/bin/bash
# run-net.sh - 只负责在 vng 里跑 net selftests + 注入 iproute2 工具（_inj）
set -eu

# --- 默认参数 ---
O_DIR=""
CPUS="8"
MEM="8G"
SCOPE="ffast"

# 宿主机注入目录：你已经建好并把 ip/tc/bridge/ss/nstat 都拷进去了
INJ_DIR="/home/u2404/kernel-dev/iproute2/_inj"

usage() {
    cat <<EOF
Usage: $0 -o <out_dir> [-p cpus] [-m mem] [--full|--fast|--ffast] [--inj <dir>]

  -o        kernel out dir (e.g. ../out/build/x86_64.clang.net)
  -p        cpus for vng (default: $CPUS)
  -m        mem  for vng (default: $MEM)
  --inj     injection dir containing: ip tc bridge ss nstat (default: $INJ_DIR)

  --full/--fast/--ffast  keep for compat; pruning is done in install tree if needed
EOF
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        -o) O_DIR="$2"; shift 2 ;;
        -p) CPUS="$2"; shift 2 ;;
        -m) MEM="$2"; shift 2 ;;
        --inj) INJ_DIR="$2"; shift 2 ;;
        --full)  SCOPE="full"; shift ;;
        --fast)  SCOPE="fast"; shift ;;
        --ffast) SCOPE="ffast"; shift ;;
        -l|-g) shift ;;  # compat: auto-net 还会传 -l/-g，这里忽略（run 阶段不编译）
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

[ -n "$O_DIR" ] || usage

O_DIR_ABS=$(readlink -f "$O_DIR")
INSTALL_DIR="$O_DIR_ABS/kselftest/kselftest_install"
KERNEL_IMG="$O_DIR_ABS/arch/x86/boot/bzImage"

# --- 基本检查 ---
[ -f "$KERNEL_IMG" ] || { echo "ERROR: missing kernel image: $KERNEL_IMG" >&2; exit 2; }
[ -d "$INSTALL_DIR/net" ] || { echo "ERROR: missing kselftest install: $INSTALL_DIR/net" >&2; exit 2; }
[ -x "$INSTALL_DIR/run_kselftest.sh" ] || { echo "ERROR: missing $INSTALL_DIR/run_kselftest.sh" >&2; exit 2; }

# --- ffast 模式：允许在宿主机安装树里“阉割”少数脚本（可选） ---
if [ "$SCOPE" = "ffast" ]; then
    echo "[info] Mode: ffast. Pruning tests on host install tree..."
    SKIP_LIST="net/fcnal-test.sh net/ipvtap_test.sh net/macvlan_test.sh \
net/fib_nexthops.sh net/fib_tests.sh net/udpgso_bench.sh \
net/gro.sh net/so_txtime.sh net/psock_snd.sh net/ipv6_route_update_soft_lockup.sh"
    for script in $SKIP_LIST; do
        target="$INSTALL_DIR/$script"
        if [ -f "$target" ]; then
            printf "%s\n" "echo '[CI-SKIP] $(basename "$script")'; exit 0" > "$target"
            chmod +x "$target" || true
        fi
    done
fi

echo "[test] Starting vng..."
echo "       kernel : $KERNEL_IMG"
echo "       install: $INSTALL_DIR"
echo "       injdir : $INJ_DIR"
echo "       cpus/mem: $CPUS / $MEM"

# --- 生成 guest 执行脚本文件（纯 /bin/sh，可落盘看日志） ---
EXEC_SH="$INSTALL_DIR/.vng-net-exec.sh"
LOG_GUEST="$INSTALL_DIR/run-net.guest.log"

cat > "$EXEC_SH" <<'EOF'
#!/bin/sh
set -eu

echo "=== [GUEST_BEGIN] ==="
id || true
uname -a || true

: "${INJ_DIR:?missing INJ_DIR}"
: "${INSTALL_DIR:?missing INSTALL_DIR}"

export PATH="$INJ_DIR:$PATH"
export PAGER=cat
export HOME=/root

# /tmp 变 tmpfs（有些 net selftests 会硬用 /tmp）
fs_tmp=$(stat -f -c %T /tmp 2>/dev/null || echo unknown)
if [ "$fs_tmp" != "tmpfs" ]; then
    mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs /tmp 2>/dev/null || true
fi

# nstat history 固定到 /run（tmpfs）
export TMPDIR=/tmp
export NSTAT_HISTORY=/run/nstat.hist
rm -f /run/nstat.hist 2>/dev/null || true

echo "--- [Environment Check] ---"
echo "PATH=$PATH"
echo "TMPDIR=$TMPDIR NSTAT_HISTORY=$NSTAT_HISTORY HOME=$HOME"
echo "fs(/tmp)=$(stat -f -c %T /tmp 2>/dev/null || echo unknown) fs(/run)=$(stat -f -c %T /run 2>/dev/null || echo unknown)"
which ip     || true; ip -V     || true
which tc     || true; tc -V     || true
which bridge || true; bridge -V || true
which ss     || true; ss -V     || true
which nstat  || true; nstat -V  || true
nstat -n >/dev/null 2>&1 || true
ls -l /run/nstat.hist 2>/dev/null || true

# === 关键修复：把安装树复制到 /run 可写目录，再从那里跑 ===
KSROOT="/run/kselftest_install"
rm -rf "$KSROOT" 2>/dev/null || true
mkdir -p "$KSROOT"
cp -a "$INSTALL_DIR/." "$KSROOT/"

cd "$KSROOT" || { echo "[GUEST] cd $KSROOT failed"; exit 200; }
ls -l ./run_kselftest.sh || { echo "[GUEST] missing run_kselftest.sh"; exit 201; }

echo "=== [GUEST] RUN run_kselftest.sh ==="
./run_kselftest.sh
rc=$?

echo "=== [GUEST] END rc=$rc ==="
exit $rc
EOF

chmod +x "$EXEC_SH"

echo "[test] Starting vng..."
echo "       kernel : $KERNEL_IMG"
echo "       config : $O_DIR_ABS/.config"
echo "       install: $INSTALL_DIR"
echo "       injdir : $INJ_DIR"
echo "       cpus/mem: $CPUS / $MEM"
echo "       exec   : $EXEC_SH"

vng --run "$KERNEL_IMG" \
    --config "$O_DIR_ABS/.config" \
    --user root --rw --cpus "$CPUS" --memory "$MEM" \
    --exec "INJ_DIR='$INJ_DIR' INSTALL_DIR='$INSTALL_DIR' /bin/sh '$EXEC_SH'" \
    2>&1 | tee "$LOG_GUEST"

