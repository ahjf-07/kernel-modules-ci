#!/bin/bash

# =================================================================
# 脚本名称: reset-ci.sh
# 运行环境: 建议在 crontab 中使用绝对路径调用
# =================================================================
export PATH="/home/u2404/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME="/home/u2404"

# 1. 自动获取脚本所在目录 (sj-ktools)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# 2. 设置内核源码工作目录 (请根据实际路径调整)
WORKDIR="/home/u2404/kernel-dev/linux"

# 检查工作目录是否存在
if [ ! -d "$WORKDIR" ]; then
    echo "错误: 工作目录 $WORKDIR 不存在。"
    exit 1
fi

# 切换到内核目录，因为 CI 脚本通常需要在源码根目录下运行
cd "$WORKDIR" || exit 1

check_status() {
    if [ $? -ne 0 ]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] 错误: $1 执行失败。"
        exit 1
    fi
}

echo "==========================================="
echo "任务开始时间: $(date +'%Y-%m-%d %H:%M:%S')"
echo "当前工作目录: $(pwd)"
echo "==========================================="

# 顺序执行任务
script -q -c "$SCRIPT_DIR/auto-bpf-ci.sh -U --reset-baseline" /dev/null
check_status "auto-bpf-ci.sh --reset-baseline"

script -q -c "$SCRIPT_DIR/auto-bpf-ci.sh" /dev/null
check_status "auto-bpf-ci.sh"

script -q -c "$SCRIPT_DIR/auto-net-ci.sh --reset-baseline" /dev/null
check_status "auto-net-ci.sh --reset-baseline"

script -q -c "$SCRIPT_DIR/auto-net-ci.sh" /dev/null
check_status "auto-net-ci.sh"

echo "==========================================="
echo "任务完成时间: $(date +'%Y-%m-%d %H:%M:%S')"
echo "所有 CI 任务已成功顺序完成。"
