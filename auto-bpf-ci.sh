#!/bin/bash
# auto-bpf-ci.sh (V14 - Strict Regex Mode)
# 1. FIX: Enforces strict regex format "^/.*:[0-9]+:[0-9]+:" for Sparse logs
#    This eliminates ALL truncated lines, interleaved garbage, and build noise.
# 2. Features: Artifacts persistence, Email reporting, Robust log splitting
set -eu
set -o pipefail

TOOL_DIR=$(cd "$(dirname "$0")" && pwd)

# --- 1. 安全检查 ---
if [ ! -f "MAINTAINERS" ] || [ ! -f "Makefile" ] || ! grep -q "^VERSION =" Makefile; then
    echo "Error: Current directory ($(pwd)) is NOT a Linux kernel source root."
    exit 1
fi

# --- 2. 默认配置 ---
LINUX_ROOT=$(pwd)
O_BASE="../out"
COMPILER="clang"
BUILD_MODE="m"
UPDATE=0
SPARSE=1
TEST_SCOPE="full"
TEST_COUNT=30
CPUS=8
MEM=8G
RESET_B=0
GIT_BRANCH="master"
TARGET_REF="upstream/master"
TO_EMAIL="${AUTO_EMAIL:-}"
SPARSE_SUBTREES=""

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Build Options:"
    echo "  -l           Use Clang compiler (Default)"
    echo "  -g           Use GCC compiler"
    echo "  -s           Enable Sparse checking (Default)"
    echo "  --no-sparse  Disable Sparse checking"
    echo "  -S <dirs>    Sparse check specific subtrees (e.g. 'kernel/bpf')"
    echo "  -U           Update source code (git pull)"
    echo "  -u           Offline mode (Skip update, Default)"
    echo "  -m           Make mrproper (Full build, Default)"
    echo "  -c           Make clean (Clean build)"
    echo "  -i           Incremental build"
    echo ""
    echo "Test Options:"
    echo "  --full       Run full tests (Default)"
    echo "  --ff         Run faster tests (skip heavy tests)"
    echo "  -f <num>     Run fast tests with <num> count"
    echo ""
    echo "General Options:"
    echo "  -e <email>   Send report to email"
    echo "  -t <ref>     Target git reference (Default: upstream/master)"
    echo "  -o <dir>     Output Base Directory (Default: ../out)"
    echo "  -P <cpus>    VM CPUs (Default: 8)"
    echo "  -M <mem>     VM Memory (Default: 8G)"
    echo "  --reset-baseline  Force update baseline"
    echo "  -h           Show this help"
    exit 0
}

# --- 3. 参数解析 ---
SHORT_OPTS="hlgsUumcif:P:M:e:t:o:S:"
LONG_OPTS="full,ff,reset-baseline,no-sparse"
PARSED_ARGS=$(getopt -o "$SHORT_OPTS" -l "$LONG_OPTS" -n "$0" -- "$@")
if [ $? -ne 0 ]; then exit 1; fi
eval set -- "$PARSED_ARGS"

while true; do
    case "$1" in
        -h) usage; shift ;;
        -l) COMPILER="clang"; shift ;;
        -g) COMPILER="gcc"; shift ;;
        -s) SPARSE=1; shift ;;
        --no-sparse) SPARSE=0; shift ;;
        -U) UPDATE=1; shift ;;
        -u) UPDATE=0; shift ;;
        -m) BUILD_MODE="m"; shift ;;
        -c) BUILD_MODE="c"; shift ;;
        -i) BUILD_MODE="i"; shift ;;
        --full) TEST_SCOPE="full"; shift ;;
        --ff) TEST_SCOPE="faster"; shift ;;
        -f) TEST_SCOPE="fast"; TEST_COUNT="$2"; shift 2 ;;
        -P) CPUS="$2"; shift 2 ;;
        -M) MEM="$2"; shift 2 ;;
        --reset-baseline) RESET_B=1; shift ;;
        -e) TO_EMAIL="$2"; shift 2 ;;
        -t) TARGET_REF="$2"; shift 2 ;;
        -o) O_BASE="$2"; shift 2 ;;
        -S) SPARSE_SUBTREES="$2"; shift 2 ;;
        --) shift; break ;;
        *) echo "Internal error: $1"; exit 1 ;;
    esac
done

# --- 4. 环境准备 ---
ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] && KARCH="arm64" || KARCH="$ARCH"

if [ "$COMPILER" = "clang" ]; then
    O_NAME="full-clang-${KARCH}"
    STATE_NAME="${KARCH}.clang.bpf"
    export LLVM=1; export LLVM_IAS=1
else
    O_NAME="full-gcc-${KARCH}"
    STATE_NAME="${KARCH}.gcc.bpf"
    unset LLVM LLVM_IAS
fi

O="$(realpath -m "${O_BASE:-../out}/${O_NAME}")"
STATE_DIR="../out/auto-bpf-state/${STATE_NAME}"
mkdir -p "$O" "$STATE_DIR/baseline" "$STATE_DIR/prev"

# --- 5. Git ---
if [ "$UPDATE" -eq 1 ]; then
    REMOTE="${TARGET_REF%%/*}"
    BRANCH="${TARGET_REF#*/}"
    echo "[git] Updating from $REMOTE/$BRANCH..."
    git fetch "$REMOTE"
    git checkout "$GIT_BRANCH" || git checkout -b "$GIT_BRANCH"
    git pull --ff-only "$REMOTE" "$BRANCH"
fi
new_ref=$(git rev-parse HEAD)
NOW=$(date +%Y%m%dT%H%M%SZ); RUN_DIR="$STATE_DIR/runs/$NOW"; mkdir -p "$RUN_DIR"

# --- 6. 编译流水线 ---
echo "==== Step 1: Config ($COMPILER) ===="
CONFIG_ARGS="-r $LINUX_ROOT -o $O"
[ "$BUILD_MODE" = "c" ] && CONFIG_ARGS="$CONFIG_ARGS -c"
[ "$BUILD_MODE" = "m" ] && CONFIG_ARGS="$CONFIG_ARGS -m"
[ "$COMPILER" = "clang" ] && CONFIG_ARGS="$CONFIG_ARGS -l" || CONFIG_ARGS="$CONFIG_ARGS -g"
"$TOOL_DIR/config-bpf.sh" $CONFIG_ARGS

echo "==== Step 2: Build ===="
BUILD_ARGS="-r $LINUX_ROOT -o $O -j$(nproc)"
[ "$COMPILER" = "clang" ] && BUILD_ARGS="$BUILD_ARGS -l"
[ "$SPARSE" -eq 1 ] && BUILD_ARGS="$BUILD_ARGS -s"
[ -n "${SPARSE_SUBTREES:-}" ] && BUILD_ARGS="$BUILD_ARGS -S \"$SPARSE_SUBTREES\""
if [ "$BUILD_MODE" = "i" ]; then BUILD_ARGS="$BUILD_ARGS -i"; fi

"$TOOL_DIR/build-bpf.sh" $BUILD_ARGS |& tee "$RUN_DIR/build.all.log"

echo "==== Step 3: Scan (Strict Regex Mode) ===="

# 噪音过滤器
NOISE_FILTER="bad integer constant expression|embedded NUL byte|unrecognized command line option|attribute directive ignored|static assertion failed: \"MODULE_INFO|context imbalance|incompatible types in comparison expression|too long token expansion|Should it be static\?|was not declared|symbol '.*' redeclared with different type"

# 1. 提取 Build Logs (排除包含 [SPARSE] 的行)
grep -v "\[SPARSE\]" "$RUN_DIR/build.all.log" > "$RUN_DIR/build.raw.log" || true

# 2. 提取 & 清洗 Sparse Logs (核心修改)
# - sed 1: 去掉 [SPARSE] 前缀
# - sed 2: 去掉行尾的构建命令 (CC/LD等)
# - grep : [关键] 只保留符合 "绝对路径:行号:列号:" 格式的完美行
grep "\[SPARSE\]" "$RUN_DIR/build.all.log" \
    | sed 's/.*\[SPARSE\] //' \
    | sed -E 's/[[:space:]]+(CC|LD|LDS|AR|AS|GEN|CHK)[[:space:]]+.*$//' \
    | grep -E "^/.*:[0-9]+:[0-9]+:" \
    > "$RUN_DIR/sparse.cleaned.log"

# 3. 生成最终列表
grep -E '(^|: )error:' "$RUN_DIR/build.raw.log" | grep -vE "($NOISE_FILTER)" > "$RUN_DIR/list.build.error.txt" || true
grep -E '(^|: )warning:' "$RUN_DIR/build.raw.log" | grep -vE "($NOISE_FILTER)" > "$RUN_DIR/list.build.warning.txt" || true
grep -vE "($NOISE_FILTER)" "$RUN_DIR/sparse.cleaned.log" > "$RUN_DIR/list.sparse.txt" || true

echo "errors_effective : $(wc -l < "$RUN_DIR/list.build.error.txt")" > "$RUN_DIR/scan.txt"
echo "warnings_effective : $(wc -l < "$RUN_DIR/list.build.warning.txt")" >> "$RUN_DIR/scan.txt"
echo "sparse_effective : $(wc -l < "$RUN_DIR/list.sparse.txt")" >> "$RUN_DIR/scan.txt"

echo "==== Step 4: Test ($TEST_SCOPE) ===="
rm -f ".kselftest-out/bpf.selftests.log"
RUN_ARGS="-r $LINUX_ROOT -o $O -p $CPUS -m $MEM"
[ "$COMPILER" = "clang" ] && RUN_ARGS="$RUN_ARGS -l"
if [ "$TEST_SCOPE" = "faster" ]; then RUN_ARGS="$RUN_ARGS --ff"; elif [ "$TEST_SCOPE" = "fast" ]; then RUN_ARGS="$RUN_ARGS -f $TEST_COUNT"; fi

"$TOOL_DIR/run-bpf.sh" $RUN_ARGS |& tee "$RUN_DIR/run-bpf.host.log"

echo "==== Step 5: Summarize ===="
TEST_LOG="$RUN_DIR/run-bpf.host.log"
"$TOOL_DIR/summ-bpf.sh" "$TEST_LOG" > "$RUN_DIR/test.summ.txt" 2>&1 || echo "Summary failed" > "$RUN_DIR/test.summ.txt"

grep "^#" "$TEST_LOG" > "$RUN_DIR/list.test.txt" || true
grep -E ":(FAIL|ERROR)" "$TEST_LOG" | grep -v "Summary:" > "$RUN_DIR/list.test.failed.txt" || true
grep -E ":SKIP" "$TEST_LOG" > "$RUN_DIR/list.test.skipped.txt" || true

# --- 7. 标准化函数 ---
normalize_test() {
    sed 's/^\[guest\] //g' "$1" | grep -E "^#[0-9]+" | sed -E '
        s/^[[:space:]]*//; s/^#[0-9]+(\/[0-9]+)? //; s/ \([0-9]+ms\)//g;
        s/pid [0-9]+/pid PID/g; s/veth[a-zA-Z0-9]+/veth-RANDOM/g; s/0x[0-9a-fA-F]{8,}/PTR/g;
        s/:[0-9]+:/:/g; s/\x1b\[[0-9;]*m//g; s/[[:space:]]*$//;
    ' | sort -u
}
normalize_build() {
    sed -E 's/^[[:space:]]*//; s/:[0-9]+:[0-9]+:/:/g; s/:[0-9]+:/:/g; s/[[:space:]]+(CC|LD|AR|AS|CHECK)[[:space:]]+.*$//' "$1" | sort -u
}

# --- 8. 回归报告生成器 ---
report_diff_item() {
    local ref="$1" curr="$2" title="$3" func="$4" label="$5" type="$6"
    local diff_file="$RUN_DIR/diff.vs_${label}.${type}.txt"
    echo ">>> $title:"
    if [ -f "$ref" ] && [ -f "$curr" ]; then
        comm -13 <($func "$ref") <($func "$curr") > "$diff_file"
        if [ -s "$diff_file" ]; then
            local count=$(wc -l < "$diff_file")
            head -n 20 "$diff_file"
            [ "$count" -gt 20 ] && echo "... (Truncated: See artifacts for full $count items)"
        else
            echo "  (No new items)"
        fi
    else echo "  (Skipped: Reference or Current file missing)"; fi
    echo ""
}

generate_report_section() {
    local ref_dir="$1"
    local label_name="$2"
    local label_slug=$(echo "$label_name" | tr '[:upper:]' '[:lower:]')
    echo "##########################################################"
    echo "   REGRESSION REPORT vs $label_name"
    echo "##########################################################"
    report_diff_item "$ref_dir/list.test.txt"           "$RUN_DIR/list.test.txt"           "[TEST] NEW FAILURES/CHANGES"       "normalize_test"  "$label_slug" "test"
    report_diff_item "$ref_dir/list.build.error.txt"    "$RUN_DIR/list.build.error.txt"    "[BUILD] NEW COMPILER ERRORS"       "normalize_build" "$label_slug" "build_error"
    report_diff_item "$ref_dir/list.build.warning.txt"  "$RUN_DIR/list.build.warning.txt"  "[BUILD] NEW COMPILER WARNINGS"     "normalize_build" "$label_slug" "build_warning"
    report_diff_item "$ref_dir/list.sparse.txt"         "$RUN_DIR/list.sparse.txt"         "[SPARSE] NEW ISSUES (Effective)"   "normalize_build" "$label_slug" "sparse"
    echo -e "\n"
}

# --- 9. 邮件组装 ---
MAIL_FILE="$RUN_DIR/mail.mbox"
{
  echo "Subject: [auto-bpf][${STATE_NAME}] run done: offline=$((1-UPDATE)) HEAD=${new_ref}"
  echo "To: ${TO_EMAIL}"
  echo ""
  if [ -d "$STATE_DIR/baseline" ]; then generate_report_section "$STATE_DIR/baseline" "BASELINE"; else echo "(No Baseline)"; fi
  if [ -d "$STATE_DIR/prev" ]; then generate_report_section "$STATE_DIR/prev" "PREV"; fi

  echo "== CURRENT SUMMARY =="
  grep "_effective" "$RUN_DIR/scan.txt" || true
  echo ""
  cat "$RUN_DIR/test.summ.txt"
  
  echo -e "\n=========================================================="
  echo "                TOP DETAILS (Max 20 per category)"
  echo "=========================================================="
  [ -s "$RUN_DIR/list.build.error.txt" ] && echo -e "\n>>> TOP 20 COMPILER ERRORS:\n$(head -n 20 "$RUN_DIR/list.build.error.txt")"
  [ -s "$RUN_DIR/list.build.warning.txt" ] && echo -e "\n>>> TOP 20 COMPILER WARNINGS:\n$(head -n 20 "$RUN_DIR/list.build.warning.txt")"
  [ -s "$RUN_DIR/list.sparse.txt" ] && echo -e "\n>>> TOP 20 SPARSE ISSUES:\n$(head -n 20 "$RUN_DIR/list.sparse.txt")"
  grep -q ":FAIL" "$TEST_LOG" && echo -e "\n>>> TOP 20 TEST FAILURES:\n$(grep ":FAIL" "$TEST_LOG" | grep -v "Summary:" | head -n 20)"
  
  echo -e "\n== ARTIFACTS =="
  echo "  Run Dir : $RUN_DIR"
  echo "  Logs    : $RUN_DIR/run-bpf.host.log, $RUN_DIR/build.all.log"
  echo "  Lists   : $RUN_DIR/list.{test.failed,test.skipped,build.error,build.warning,sparse}.txt"
  echo "  Diffs   : $RUN_DIR/diff.vs_baseline.*.txt"
} > "$MAIL_FILE"

# --- 10. 归档 ---
safe_cp() { [ -f "$1" ] && cp "$1" "$2"; }
update_state() {
    local dest="$1"; mkdir -p "$dest"
    safe_cp "$RUN_DIR/list.test.txt"           "$dest/"
    safe_cp "$RUN_DIR/list.build.error.txt"    "$dest/"
    safe_cp "$RUN_DIR/list.build.warning.txt"  "$dest/"
    safe_cp "$RUN_DIR/list.sparse.txt"         "$dest/"
}
[ "$RESET_B" -eq 1 ] || [ ! -d "$STATE_DIR/baseline" ] && update_state "$STATE_DIR/baseline"
update_state "$STATE_DIR/prev"
if [ -n "$TO_EMAIL" ]; then git send-email --to "${TO_EMAIL}" --confirm=never --8bit-encoding=UTF-8 "$MAIL_FILE"; else echo "[info] Report saved to $MAIL_FILE"; fi
