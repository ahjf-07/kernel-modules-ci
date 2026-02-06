#!/bin/bash
# [Final Fixed] auto-net-ci.sh
# Fixes: Timestamp stripping, Report Titles, Strict Normalization
set -eu
set -o pipefail

# --- 0. 安全检查 ---
if [ ! -f "MAINTAINERS" ] || [ ! -f "Makefile" ] || ! grep -q "^VERSION =" Makefile; then
    echo "Error: Current directory ($(pwd)) is NOT a Linux kernel source root."
    exit 1
fi

# --- 1. 默认值 ---
TOOL_DIR="../sj-ktools"
LINUX_ROOT=$(pwd)
O_BASE="../out"

COMPILER="gcc"
GIT_BRANCH="master"
UPDATE=1
BUILD_MODE="m"
SPARSE=1
TEST_SCOPE="full"
RESET_B=0
TOP_N=30
CPUS=8
MEM=8G
TO_EMAIL="${AUTO_EMAIL:-}"

usage() {
    echo "Usage: $0 [options]"
    echo "  -g / -l         Compiler: GCC (default) / Clang"
    echo "  -U / -u         Git: Update (default) / Offline"
    echo "  -m / -c / -i    Mode: mrproper / clean / incremental"
    echo "  -s              Enable Sparse"
    echo "  --full/--fast   Test Scope"
    echo "  --reset-baseline Update baseline"
    echo "  -P <cpus> -M <mem> VM Config"
    echo "  -e <email>      Email"
    exit 0
}

# --- 2. 参数解析 ---
SHORT_OPTS="hglUumcisN:b:O:P:M:e:t:"
LONG_OPTS="full,fast,ffast,reset-baseline,top:"
PARSED_ARGS=$(getopt -o "$SHORT_OPTS" -l "$LONG_OPTS" -n "$0" -- "$@")
if [ $? -ne 0 ]; then usage; fi
eval set -- "$PARSED_ARGS"

while true; do
    case "$1" in
        -h) usage; shift ;;
        -g) COMPILER="gcc"; shift ;;
        -l) COMPILER="clang"; shift ;;
        -b) GIT_BRANCH="$2"; shift 2 ;;
        -O) O_BASE="$2"; shift 2 ;;
        -U) UPDATE=1; shift ;;
        -u|-N) UPDATE=0; shift ;;
        -m) BUILD_MODE="m"; shift ;;
        -c) BUILD_MODE="c"; shift ;;
        -i) BUILD_MODE="i"; shift ;;
        -s) SPARSE=1; shift ;;
        --full) TEST_SCOPE="full"; shift ;;
        --fast) TEST_SCOPE="fast"; shift ;;
        --ffast) TEST_SCOPE="ffast"; shift ;;
        --reset-baseline) RESET_B=1; shift ;;
        -P) CPUS="$2"; shift 2 ;;
        -M) MEM="$2"; shift 2 ;;
        -e) TO_EMAIL="$2"; shift 2 ;;
        --top| -t) TOP_N="$2"; shift 2 ;;
        --) shift; break ;;
        *) echo "Internal error: $1"; exit 1 ;;
    esac
done

# --- 3. 环境准备 ---
ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] && KARCH="arm64" || KARCH="$ARCH"

if [ "$COMPILER" = "clang" ]; then
    O_NAME="full-clang-${KARCH}"
    STATE_NAME="${KARCH}.clang"
    export LLVM=1; export LLVM_IAS=1
else
    O_NAME="full-gcc-${KARCH}"
    STATE_NAME="${KARCH}.gcc"
    unset LLVM LLVM_IAS
fi

O="${O_BASE}/${O_NAME}"
STATE_DIR="${O_BASE}/auto-net-state/${STATE_NAME}"
mkdir -p "$O" "$STATE_DIR/baseline" "$STATE_DIR/prev"

# --- 4. Git 逻辑 ---
if [ "$UPDATE" -eq 1 ]; then
    echo "[git] Updating from upstream ($GIT_BRANCH)..."
    git fetch upstream
    git checkout "$GIT_BRANCH"
    git pull --ff-only upstream "$GIT_BRANCH"
fi
new_ref=$(git rev-parse HEAD)
NOW=$(date +%Y%m%dT%H%M%SZ); RUN_DIR="$STATE_DIR/runs/$NOW"; mkdir -p "$RUN_DIR"

# --- 5. 编译流水线 ---
echo "==== Step 1: Config ($COMPILER) ===="
[ "$COMPILER" = "clang" ] && CFG_COMP="-l" || CFG_COMP="-g"
"$TOOL_DIR/config-net.sh" -o "$O" -"$BUILD_MODE" "$CFG_COMP"

echo "==== Step 2: Build ===="
BUILD_ARGS="-o $O -j$(nproc)"
[ "$COMPILER" = "clang" ] && BUILD_ARGS="$BUILD_ARGS -l" || BUILD_ARGS="$BUILD_ARGS -g"
[ "$SPARSE" -eq 1 ] && BUILD_ARGS="$BUILD_ARGS -s"
"$TOOL_DIR/build-net.sh" $BUILD_ARGS |& tee "$RUN_DIR/build.all.log"

echo "==== Step 3: Scan ===="
"$TOOL_DIR/scan-net.sh" -t "$TOP_N" "$RUN_DIR/build.all.log" > "$RUN_DIR/build.summ.txt"

echo "==== Step 4: Test ($TEST_SCOPE) ===="
rm -f .kselftest-out/net.selftests.log
"$TOOL_DIR/run-net.sh" -o "$O" -p "$CPUS" -m "$MEM" -S "$TEST_SCOPE" |& tee "$RUN_DIR/run-net.host.log"

echo "==== Step 5: Summarize ===="
"$TOOL_DIR/summ-net.sh" ".kselftest-out/net.selftests.log" "$TOP_N" > "$RUN_DIR/test.summ.txt"

# --- 6. 标准化函数 (Normalize) ---

normalize_test() {
    # 1. 去首空格
    # 2. 去除 socat 时间戳 (YYYY/MM/DD HH:MM:SS)
    # 3. 去除 kselftest 序号 (not ok 123)
    # 4. 去除编译类行号
    sed -E '
        s/^[[:space:]]*//;
        s/^[0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} //;
	s/(nsa-|testns-|ns-)[a-zA-Z0-9]{6,}/ns-RANDOM/g;
        s/^not ok [0-9]+ /not ok /;
        s/^[0-9]+://
    ' "$1" | sort -u
}

normalize_build() {
    # 去除文件名后的行列号 (file.c:12:34: -> file.c:)
    sed -E 's/^[[:space:]]*//; s/:[0-9]+:[0-9]+:/:/g; s/:[0-9]+:/:/g' "$1" | sort -u
}

# --- 7. 回归报告生成器 ---
report_diff_item() {
    local ref="$1"
    local curr="$2"
    local title="$3"
    local func="$4"

    echo ">>> $title:"
    if [ -f "$ref" ] && [ -f "$curr" ]; then
        local diff_out
        diff_out=$(comm -13 <($func "$ref") <($func "$curr"))
        if [ -n "$diff_out" ]; then
            echo "$diff_out"
        else
            echo "  (No new items)"
        fi
    else
        echo "  (Skipped: Reference or Current file missing)"
    fi
    echo ""
}

generate_report_section() {
    local ref_dir="$1"
    local label="$2"
    local build_dir
    build_dir=$(dirname "$RUN_DIR/build.all.log")

    echo "##########################################################"
    echo "   REGRESSION REPORT vs $label"
    echo "##########################################################"
    
    # 标题不再叫 FAILURES，因为可能包含 OK
    report_diff_item "$ref_dir/list.test.txt" \
                     ".kselftest-out/list.test.txt" \
                     "[TEST] NEW RESULTS (Regressions/Changes)" "normalize_test"

    report_diff_item "$ref_dir/list.error.txt" \
                     "$build_dir/list.error.txt" \
                     "[BUILD] COMPILER ERRORS" "normalize_build"

    report_diff_item "$ref_dir/list.warning.txt" \
                     "$build_dir/list.warning.txt" \
                     "[BUILD] COMPILER WARNINGS" "normalize_build"

    report_diff_item "$ref_dir/list.sparse.txt" \
                     "$build_dir/list.sparse.txt" \
                     "[SPARSE] STATIC ANALYSIS" "normalize_build"
                     
    echo -e "\n"
}

# --- 8. 邮件组装 ---
MAIL_FILE="$RUN_DIR/mail.mbox"
{
  echo "Subject: [auto-net][${STATE_NAME}] run done: offline=$((1-UPDATE)) HEAD=${new_ref}"
  echo "To: ${TO_EMAIL}"
  echo ""
  
  if [ -d "$STATE_DIR/baseline" ]; then
      generate_report_section "$STATE_DIR/baseline" "BASELINE"
  else
      echo "(No Baseline found, skipping regression check)"
      echo ""
  fi
  
  if [ -d "$STATE_DIR/prev" ]; then
      generate_report_section "$STATE_DIR/prev" "PREV"
  fi

  echo "== CURRENT SUMMARY =="
  cat "$RUN_DIR/build.summ.txt"
  echo ""
  cat "$RUN_DIR/test.summ.txt"

  echo -e "\n== ARTIFACTS =="
  echo "  Run Dir        : $RUN_DIR"
  echo "  Raw Build Log  : $RUN_DIR/build.all.log (Mixed)"
  echo "  -------------------------------------------------"
  echo "  Build Errors   : $RUN_DIR/list.error.txt"
  echo "  Build Warnings : $RUN_DIR/list.warning.txt"
  echo "  Sparse Reports : $RUN_DIR/list.sparse.txt"
  echo "  Test Results   : .kselftest-out/list.test.txt"
  
} > "$MAIL_FILE"

# --- 9. 归档与发送 ---
safe_cp() { [ -f "$1" ] && cp "$1" "$2"; }

if [ "$RESET_B" -eq 1 ]; then
    echo "[info] Updating Baseline..."
    safe_cp ".kselftest-out/list.test.txt" "$STATE_DIR/baseline/"
    safe_cp "$(dirname "$RUN_DIR/build.all.log")/list.error.txt"   "$STATE_DIR/baseline/"
    safe_cp "$(dirname "$RUN_DIR/build.all.log")/list.warning.txt" "$STATE_DIR/baseline/"
    safe_cp "$(dirname "$RUN_DIR/build.all.log")/list.sparse.txt"  "$STATE_DIR/baseline/"
fi

# 总是更新 Prev
safe_cp ".kselftest-out/list.test.txt" "$STATE_DIR/prev/"
safe_cp "$(dirname "$RUN_DIR/build.all.log")/list.error.txt"   "$STATE_DIR/prev/"
safe_cp "$(dirname "$RUN_DIR/build.all.log")/list.warning.txt" "$STATE_DIR/prev/"
safe_cp "$(dirname "$RUN_DIR/build.all.log")/list.sparse.txt"  "$STATE_DIR/prev/"

if [ -n "$TO_EMAIL" ]; then
    git send-email --to "${TO_EMAIL}" --confirm=never --8bit-encoding=UTF-8 "$MAIL_FILE"
else
    echo "[info] Report saved to $MAIL_FILE"
fi
