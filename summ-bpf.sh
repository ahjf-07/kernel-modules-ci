#!/bin/bash
# summ-bpf.sh (Final)
LOG="$1"

if [ ! -f "$LOG" ] || [ ! -s "$LOG" ]; then
    echo "Summary failed: Log missing or empty"
    exit 0
fi

echo "=========================================================="
echo "   BPF SELFTESTS SUMMARY"
echo "=========================================================="

# 1. 尝试提取 Summary 行
SUMM_LINE=$(grep "Summary: " "$LOG" | tail -n 1)

if [ -n "$SUMM_LINE" ]; then
    echo "$SUMM_LINE"
else
    PASS=$(grep -cE ":(OK|PASS)" "$LOG" || true)
    FAIL=$(grep -cE ":(FAIL|ERROR)" "$LOG" || true)
    echo "Summary (Manual): ${PASS} PASSED, ${FAIL} FAILED"
fi
echo "=========================================================="

# 2. 列出失败项 (Top 20)
FAIL_COUNT=$(grep -E ":(FAIL|ERROR)" "$LOG" | grep -v "Summary:" | wc -l)

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo ""
    echo ">>> FAILED TESTS ($FAIL_COUNT):"
    grep -E ":(FAIL|ERROR)" "$LOG" \
        | grep -v "Summary:" \
        | head -n 20 \
        | sed 's/\x1b\[[0-9;]*m//g'
    
    if [ "$FAIL_COUNT" -gt 20 ]; then
        echo "... (and $((FAIL_COUNT-20)) more)"
    fi
else
    echo ""
    echo ">>> NO FAILURES DETECTED."
fi
