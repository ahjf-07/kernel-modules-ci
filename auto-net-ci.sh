#!/bin/bash
# ==============================================================================
# Script Name: auto-net-ci.sh (V22 - Default Clang)
# Description: Automated Kernel Build & Test CI for Networking
# ==============================================================================

set -eu
set -o pipefail

# 强制 ASCII 排序，确保 diff 结果一致
export LC_ALL=C
export LANG=C

# ==============================================================================
# [Step 1] Default Configuration
# ==============================================================================
TOOL_DIR="../sj-ktools"
O_BASE="../out"

# --- 【核心改动：默认改为 Clang】 ---
COMPILER="clang"
CC_FLAG="-l"
# ----------------------------------

UPDATE=0
BUILD_MODE="m"
SPARSE=1
TEST_SCOPE=""
RESET_B=0
TOP_N=30
CPUS=$(nproc)
MEM="8G"
TO_EMAIL="${AUTO_EMAIL:-}"
ARCH=$(uname -m)

# ==============================================================================
# [Step 2] Usage Documentation
# ==============================================================================
usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Build Options:"
    echo "  -g                  Use GCC compiler"
    echo "  -l                  Use Clang/LLVM compiler (Default)"
    echo "  -U                  Update source code (perform 'git pull --rebase')"
    echo "  -u                  Offline mode (Skip git update)"
    echo "  -m                  Make mrproper (Full clean build, Recommended)"
    echo "  -c                  Make clean (Standard clean)"
    echo "  -i                  Incremental build (Faster, but risky for config changes)"
    echo "  -s                  Enable Sparse checking (Default: Enabled)"
    echo ""
    echo "Test Options:"
    echo "  --full              Run full tests (Includes stress tests)"
    echo "  --fast              Run fast tests (Skips fcnal-test)"
    echo "  --ffast             Run super fast tests (Default)"
    echo ""
    echo "General Options:"
    echo "  -e <email>          Send report to email"
    echo "  -N <num>            Show top N warnings in report (Default: 30)"
    echo "  -P <cpus>           VM CPUs (Default: $(nproc))"
    echo "  -M <mem>            VM Memory (Default: 8G)"
    echo "  -O <dir>            Output Base Directory"
    echo "  --reset-baseline    Force update baseline"
    echo "  -h                  Show this help message"
    echo ""
    exit 0
}

# 解析参数
SHORT_OPTS="hglUumcisN:O:P:M:e:"
LONG_OPTS="full,fast,ffast,reset-baseline,top:"
PARSED_ARGS=$(getopt -o "$SHORT_OPTS" -l "$LONG_OPTS" -n "$0" -- "$@")
eval set -- "$PARSED_ARGS"

while true; do
    case "$1" in
        -h) usage ;;
        -g) COMPILER="gcc" ; CC_FLAG="-g" ; shift ;;
        -l) COMPILER="clang" ; CC_FLAG="-l" ; shift ;;
        -U) UPDATE=1 ; shift ;;
        -u) UPDATE=0 ; shift ;;
        -m) BUILD_MODE="m" ; shift ;;
        -c) BUILD_MODE="c" ; shift ;;
        -i) BUILD_MODE="i" ; shift ;;
        -s) SPARSE=1 ; shift ;;
        -P) CPUS="$2" ; shift 2 ;;
        -M) MEM="$2" ; shift 2 ;;
        -N|--top) TOP_N="$2" ; shift 2 ;;
        -O) O_BASE="$2" ; shift 2 ;;
        -e) TO_EMAIL="$2" ; shift 2 ;;
        --full|--fast|--ffast) TEST_SCOPE="$1" ; shift ;;
        --reset-baseline) RESET_B=1 ; shift ;;
        --) shift ; break ;;
    esac
done

# ==============================================================================
# [Step 3] Environment & Git
# ==============================================================================
if [ "$UPDATE" -eq 1 ]; then
    echo "[git] Pulling updates..."
    git pull --rebase || echo "[WARN] Git pull failed"
fi

GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_SUBJECT=$(git log -1 --format=%s 2>/dev/null || echo "unknown")

TIMESTAMP=$(date +%Y%m%dT%H%M%SZ)
RUN_TAG="${ARCH}.${COMPILER}.net"
STATE_DIR=$(readlink -f "$O_BASE/auto-net-state/$RUN_TAG")
RUN_DIR="$STATE_DIR/runs/$TIMESTAMP"
BASELINE_DIR="$STATE_DIR/baseline"
PREV_DIR="$STATE_DIR/prev"
LATEST_LINK="$STATE_DIR/latest"

mkdir -p "$RUN_DIR" "$BASELINE_DIR" "$PREV_DIR"
O_DIR="$O_BASE/build/$RUN_TAG"

# ==============================================================================
# [Step 4] Helpers (Normalization & Diffing)
# ==============================================================================
NOISE_FILTER="bad integer|embedded NUL|unrecognized command|attribute directive|static assertion|context imbalance|incompatible types|too long token|Should it be static|was not declared|redeclared with different type|memset with byte count|shift too big|truncates bits"

normalize_log() {
    sed -E 's/^.*RSE\] //g; s/^\[SPARSE\] //g' | \
    (grep -E "warning:|error:" || true) | \
    (grep -vE "^(  CC|  LD|  AR|  AS|  CHECK|  OBJCOPY|  LDS|  GEN|  CHK|  BUILD|  MKPIGGY|  ZOFFSET|Kernel:)" || true) | \
    (grep -vE "($NOISE_FILTER)" || true) | \
    sed -E 's/[[:space:]]+(CC|LD|AR|CHECK)[[:space:]]+.*$//' | \
    sed -E 's/^[[:space:]]*//; s/:[0-9]+:[0-9]+:/: /g; s/:[0-9]+:/: /g' | \
    sort -u
}

normalize_test() {
    (grep -E "^(ok|not ok)" || true) | \
    sed -E 's/^[[:space:]]*//; s/ # [0-9]+//g' | \
    sort -u
}

generate_diff() {
    local cat=$1; local curr=$2; local ref=$3; local ref_name=$4
    [ -f "$ref" ] || return 0
    [ -f "$curr" ] || return 0
    local diff_new="$RUN_DIR/diff.${cat}.vs.${ref_name}.new"
    local diff_fixed="$RUN_DIR/diff.${cat}.vs.${ref_name}.fixed"
    comm -13 <(sort "$ref") <(sort "$curr") > "$diff_new"
    comm -23 <(sort "$ref") <(sort "$curr") > "$diff_fixed"
    if [ "$cat" = "test" ]; then
        (grep "^not ok" "$diff_new" > "${diff_new}.tmp" && mv "${diff_new}.tmp" "$diff_new") || true
        (grep "^not ok" "$diff_fixed" > "${diff_fixed}.tmp" && mv "${diff_fixed}.tmp" "$diff_fixed") || true
    fi
}

# ==============================================================================
# [Step 5] Build & Test
# ==============================================================================
echo "=== [$(date)] Build ($BUILD_MODE) ==="
"$TOOL_DIR/config-net.sh" -o "$O_DIR" -"$BUILD_MODE" "$CC_FLAG"
make O="$O_DIR" $([ "$COMPILER" = "clang" ] && echo "LLVM=1") olddefconfig

"$TOOL_DIR/build-net.sh" -o "$O_DIR" "$CC_FLAG" "$([ "$SPARSE" -eq 1 ] && echo "-s")" -j"$CPUS" 2>&1 | tee "$RUN_DIR/build.all.log"

echo "=== Test ==="
"$TOOL_DIR/run-net.sh" -o "$O_DIR" -p "$CPUS" -m "$MEM" "$CC_FLAG" $TEST_SCOPE 2>&1 | tee "$RUN_DIR/run-net.host.log" || true

# ==============================================================================
# [Step 6] Process Results
# ==============================================================================
echo "[info] Processing results..."
set +e 

if [ -f "$RUN_DIR/build.all.log" ]; then
    grep -v "\[SPARSE\]" "$RUN_DIR/build.all.log" | normalize_log > "$RUN_DIR/list.build.txt"
    grep "\[SPARSE\]" "$RUN_DIR/build.all.log" | sed -E 's/^\[SPARSE\] //g' | normalize_log > "$RUN_DIR/list.sparse.txt"
else 
    touch "$RUN_DIR/list.build.txt" "$RUN_DIR/list.sparse.txt"
fi

if [ -f "$RUN_DIR/run-net.host.log" ]; then
    normalize_test < "$RUN_DIR/run-net.host.log" > "$RUN_DIR/list.test.txt"
else 
    touch "$RUN_DIR/list.test.txt"
fi

for d in BASELINE PREV; do
    ref_dir="${d}_DIR"
    if [ -s "${!ref_dir}/list.test.txt" ]; then
        generate_diff "test"   "$RUN_DIR/list.test.txt"   "${!ref_dir}/list.test.txt"   "${d,,}"
        generate_diff "build"  "$RUN_DIR/list.build.txt"  "${!ref_dir}/list.build.txt"  "${d,,}"
        generate_diff "sparse" "$RUN_DIR/list.sparse.txt" "${!ref_dir}/list.sparse.txt" "${d,,}"
    fi
done
set -e

# ==============================================================================
# [Step 7] Report Generation
# ==============================================================================
MAIL_FILE="$RUN_DIR/mail.mbox"

print_header() { echo "##########################################################"; echo "   $1"; echo "##########################################################"; }
print_item() {
    local tag=$1; local file=$2; local is_fix=${3:-0}; local title=$4
    if [ -f "$file" ] && [ -s "$file" ]; then
        echo ">>> [$tag] $title:"
        if [ "$is_fix" -eq 1 ] && [[ "$file" == *"test"* ]]; then sed 's/^not ok/FIXED: ok/g' "$file" | head -n 20
        else head -n 20 "$file"; fi
        [ $(wc -l < "$file") -gt 20 ] && echo "... (and $(($(wc -l < "$file") - 20)) more)"
        echo ""
    fi
}

{
    STATUS="PASS"
    [ -f "$RUN_DIR/diff.test.vs.prev.new" ] && grep -q "not ok" "$RUN_DIR/diff.test.vs.prev.new" && STATUS="REGRESSION"
    
    echo "Subject: [auto-net][${RUN_TAG}] run done: offline=$((1-UPDATE)) HEAD=${GIT_COMMIT} (${STATUS})"
    echo "To: ${TO_EMAIL}"
    echo ""
    echo "Git:    $GIT_BRANCH @ $GIT_COMMIT"
    echo "Commit: $GIT_SUBJECT"
    echo ""

    if [ -s "$BASELINE_DIR/list.test.txt" ]; then
        print_header "REGRESSION REPORT vs BASELINE"
        print_item "TEST"   "$RUN_DIR/diff.test.vs.baseline.new" 0 "NEW FAILURES/CHANGES"
        print_item "BUILD"  "$RUN_DIR/diff.build.vs.baseline.new" 0 "NEW COMPILER WARNINGS"
        print_item "SPARSE" "$RUN_DIR/diff.sparse.vs.baseline.new" 0 "NEW ISSUES (Effective)"
    fi

    if [ -s "$PREV_DIR/list.test.txt" ]; then
        print_header "REGRESSION REPORT vs PREV"
        print_item "TEST"   "$RUN_DIR/diff.test.vs.prev.new" 0 "NEW FAILURES/CHANGES"
        print_item "BUILD"  "$RUN_DIR/diff.build.vs.prev.new" 0 "NEW COMPILER WARNINGS"
        print_item "SPARSE" "$RUN_DIR/diff.sparse.vs.prev.new" 0 "NEW ISSUES (Effective)"
    fi

    echo "== CURRENT SUMMARY =="
    echo "errors_effective : $(grep -c "error:" "$RUN_DIR/list.build.txt" || echo 0)"
    echo "warnings_effective : $(grep -c "warning:" "$RUN_DIR/list.build.txt" || echo 0)"
    echo "sparse_effective : $(wc -l < "$RUN_DIR/list.sparse.txt")"
    echo ""

    echo "=========================================================="
    echo "   NET SELFTESTS SUMMARY"
    echo "=========================================================="
    # 使用 xargs 去掉 wc 产生的多余空格
    TOTAL=$(wc -l < "$RUN_DIR/list.test.txt" | xargs)
    FAIL=$(grep -c "^not ok" "$RUN_DIR/list.test.txt" | xargs || echo 0)
    SKIP=$(grep -c "SKIP" "$RUN_DIR/list.test.txt" | xargs || echo 0)
    
    # 确保变量不为空，否则设为 0
    : ${TOTAL:=0}; : ${FAIL:=0}; : ${SKIP:=0}
    
    PASS=$((TOTAL - FAIL - SKIP))
    printf "Summary: %d/%d PASSED, %d SKIPPED, %d FAILED\n" $PASS $TOTAL $SKIP $FAIL

    echo ""
    echo "=========================================================="
    echo "   TOP DETAILS (Max $TOP_N per category)"
    echo "=========================================================="
    grep "^not ok" "$RUN_DIR/list.test.txt" > "$RUN_DIR/list.test.failed.txt" || true
    print_item "TEST"   "$RUN_DIR/list.test.failed.txt" 0 "TOP $TOP_N TEST FAILURES"
    print_item "SPARSE" "$RUN_DIR/list.sparse.txt"       0 "TOP $TOP_N SPARSE ISSUES"
    print_item "BUILD"  "$RUN_DIR/list.build.txt"        0 "TOP $TOP_N BUILD WARNINGS"

    echo "== ARTIFACTS =="
    printf "  Run Dir  : %s\n" "$RUN_DIR"
    printf "  Kernel   : %s\n" "$O_DIR/arch/x86/boot/bzImage"
    printf "  Config   : %s\n" "$O_DIR/.config"
    printf "  Logs     : %s\n" "$RUN_DIR/run-net.host.log, $RUN_DIR/build.all.log"
    printf "  Lists    : %s\n" "$RUN_DIR/list.{test,build,sparse}.txt"
    printf "  Diffs    : %s\n" "$RUN_DIR/diff.vs_baseline.*.txt"

} > "$MAIL_FILE"

# ==============================================================================
# [Step 8] Update State
# ==============================================================================
update_state_dir() {
    local dest="$1"
    mkdir -p "$dest"
    cp "$RUN_DIR/list.test.txt"   "$dest/"
    cp "$RUN_DIR/list.build.txt"  "$dest/"
    cp "$RUN_DIR/list.sparse.txt" "$dest/"
}

if [ ! -s "$BASELINE_DIR/list.test.txt" ] || [ "$RESET_B" -eq 1 ]; then
    update_state_dir "$BASELINE_DIR"
fi

update_state_dir "$PREV_DIR"

if [ -s "$RUN_DIR/build.all.log" ]; then
    rm -f "$LATEST_LINK"
    ln -s "$(readlink -f "$RUN_DIR")" "$LATEST_LINK"
fi

if [ -n "$TO_EMAIL" ]; then
    git send-email --to "${TO_EMAIL}" --confirm=never --quiet "$MAIL_FILE" || echo "[WARN] Send failed"
fi
