#!/bin/bash
# [Fixed] run-net.sh - Version 2.7 (Bash Shebang + UI Progress)
set -eu

usage() {
  cat <<USAGE
usage: $0 [-f|-ff] [-l] [-r linux_root] [-o outdir] [-p cpus] [-m mem] [-j jobs]
USAGE
  exit 1
}

# --- 1. 默认值与参数处理 ---
FAST_LEVEL=0
LLVM=0
LINUX_ROOT=""
O=""
CPUS=4           # 默认 4 核
MEM=4G           # 默认 4G
JOBS=$(nproc)

while getopts "flr:o:p:m:j:h" opt; do
  case "$opt" in
    f) FAST_LEVEL=$((FAST_LEVEL + 1)) ;;
    l) LLVM=1 ;;
    r) LINUX_ROOT="$OPTARG" ;;
    o) O="$OPTARG" ;;
    p) CPUS="$OPTARG" ;;
    m) MEM="$OPTARG" ;;
    j) JOBS="$OPTARG" ;;
    h|*) usage ;;
  esac
done
[ "$FAST_LEVEL" -gt 2 ] && FAST_LEVEL=2

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

KERNEL_IMAGE="$O/arch/$([ "$KARCH" = x86 ] && echo x86/boot/bzImage || echo arm64/boot/Image)"
OUT="$HOST_LINUX_ROOT/.kselftest-out"
LOG="$OUT/net.selftests.log"
GUEST="$OUT/guest-net.sh"

mkdir -p "$OUT"
: >"$LOG"

# --- 2. 生成 Guest 执行脚本 ---
cat <<'GEOF' >"$GUEST"
#!/bin/sh
set +e

# 系统资源限额加固 (防止 Error 24)
echo 2097152 > /proc/sys/fs/nr_open
echo 2097152 > /proc/sys/fs/file-max
ulimit -n 1048576

MODE=${MODE:-full}
ROOT=$(pwd)
LOG="$ROOT/.kselftest-out/net.selftests.log"
cd "$ROOT/tools/testing/selftests/net" || exit 1

CUR=0
TOTAL=0

# UI 打印函数：直接输出到屏幕 (stdout)
print_ui() {
  printf "\r\033[K[ %d / %d ] %s" "$CUR" "$TOTAL" "$1"
}

run_bash() {
  CUR=$((CUR + 1))
  f="$1"
  base=$(basename "$f")
  print_ui "Running script: $base"
  echo "=== RUN bash $f ===" >>"$LOG"
  timeout 120s bash "$f" >>"$LOG" 2>&1
}

run_exec() {
  CUR=$((CUR + 1))
  f="$1"
  base=$(basename "$f")
  
  # 方案 A 过滤名单 (防止阻塞和重启)
  case "$base" in
    "fin_ack_lat"|"tcp_mmap"|"tcp_inq"|"udpgso_bench_rx"|"udpgso_bench_tx"|"so_rcv_listener"|"tcp_filtering"|"nettest"|"skf_net_off"|"psock_fanout"|"psock_tpacket"|"reuseport_bpf")
      echo "=== SKIP $base ===" >>"$LOG"
      return 0 ;;
  esac

  print_ui "Running binary: $base"
  echo "=== RUN $f ===" >>"$LOG"
  timeout 60s "$f" >>"$LOG" 2>&1
}

case "$MODE" in
  faster) TOTAL=1; run_exec ./run_netsocktests ;;
  fast)
    TOTAL=2
    run_exec ./run_netsocktests
    run_bash ./fcnal-test.sh
    ;;
  full)
    scripts=$(ls *.sh | grep -vE "config|settings")
    bins=$(find . -maxdepth 1 -type f -executable ! -name "*.*")
    TOTAL=$(( $(echo "$scripts" | wc -w) + $(echo "$bins" | wc -w) ))
    
    for s in $scripts; do run_bash "./$s"; done
    for b in $bins; do run_exec "$b"; done
    ;;
esac
echo -e "\n=== All tests finished ==="
GEOF

chmod +x "$GUEST"

case "$FAST_LEVEL" in
  2) EXEC="sh -c 'MODE=faster exec sh .kselftest-out/guest-net.sh'" ;;
  1) EXEC="sh -c 'MODE=fast   exec sh .kselftest-out/guest-net.sh'" ;;
  0) EXEC="sh -c 'exec sh .kselftest-out/guest-net.sh'" ;;
esac

echo "[host] launching vng with ${CPUS} CPUs and ${MEM} RAM..."

# --- 3. 执行 vng 并过滤 Slirp 噪音 ---
# 必须使用 bash 运行以支持此重定向语法
vng --run "$KERNEL_IMAGE" \
  --user root --cpus "$CPUS" --memory "$MEM" --network user \
  --rw --cwd "$HOST_LINUX_ROOT" --exec "$EXEC" 2> >(grep -v "Slirp: external icmpv6 not supported yet" >&2)

echo "[host] done: $LOG"
