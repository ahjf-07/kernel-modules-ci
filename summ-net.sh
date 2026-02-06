#!/bin/bash
set -eu
LOG="$1"; TOP_N="${2:-30}"

normalize_test() {
    sed -E 's/^[0-9]+://; s/\[[0-9]+\]//g; s/[0-9-]{10}//g; s/^[[:space:]]*//' | sort -u
}

# 1. 脚本统计
P=$(grep -c "\[PASS\]" "$LOG" || true)
F=$(grep -c "\[FAIL\]" "$LOG" || true)
S=$(grep -c "\[SKIP\]" "$LOG" || true)

# 2. 子测试统计 (基于 TAP)
SP=$(grep -E "^ok [0-9]+" "$LOG" | grep -v "# SKIP" | wc -l || true)
SS=$(grep -E "^ok [0-9]+ # SKIP" "$LOG" | wc -l || true)
SF=$(grep -E "^not ok [0-9]+" "$LOG" | wc -l || true)

echo "==== net kselftest summary ===="
echo "Scripts:   PASS=$P, FAIL=$F, SKIP=$S"
echo "Sub-tests: PASS=$SP, FAIL=$SF, SKIP=$SS"

echo -e "\n## Top Failures ##"
FAIL_LIST=$(grep -E "\[FAIL\]|\[EXIT\]|^not ok" "$LOG" | normalize_test)
actual=$(echo "$FAIL_LIST" | grep -v "^$" | wc -l || echo 0)
show=$(( actual < TOP_N ? actual : TOP_N ))
echo "$FAIL_LIST" | head -n "$show"

# 导出标准化列表
grep "\[" "$LOG" | normalize_test > .kselftest-out/list.test.txt
